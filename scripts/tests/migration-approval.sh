#!/bin/bash
# Tests for skills/release/scripts/migration-approval.py: real temporary repositories, the helper's
# own command line. No network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/skills/release/scripts/migration-approval.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
# The runner prints to a file: bash 3.2 cannot parse a here-document holding apostrophes inside $( ).
python3 - "$HELPER" "$WORK" > "$WORK/out" <<'PY'
import json, os, subprocess, sys
helper, work = sys.argv[1], sys.argv[2]
MIG = "db/migrations/sql/0352_add_x.sql"
GLOBS = ["db/migrations/sql/*.sql", "db/campaigns/**"]
TODAY = __import__("datetime").date.today().isoformat()
count = [0]

def say(good, label, extra=""):
    print(("ok   " if good else "FAIL ") + label + ("" if good else " -> " + extra))

def repo(full, files=None):
    """A repository whose base branch `develop` holds the config; returns its path."""
    count[0] += 1
    path = os.path.join(work, "r%d" % count[0])
    os.makedirs(os.path.join(path, ".claude"))
    git(path, "init", "-q", "-b", "develop")
    write(path, ".claude/ds-config.json", full if isinstance(full, str) else json.dumps({"release": {"fullRelease": full}}))
    for name, text in (files or {}).items():
        write(path, name, text)
    commit(path, "base")
    git(path, "checkout", "-q", "-b", "work")
    return path

def git(path, *args, **kw):
    return subprocess.run(["git", "-C", path, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "commit.gpgsign=false"] + list(args),
                          check=kw.get("check", True), capture_output=True, text=True)

def write(path, name, text):
    full = os.path.join(path, name)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w") as handle:
        handle.write(text)

def commit(path, message):
    git(path, "add", "-A"); git(path, "commit", "-q", "-m", message)

def blob(path, name, ref="HEAD"):
    return git(path, "rev-parse", "%s:%s" % (ref, name)).stdout.strip()

def approve(path, entries, extra=None):
    full = dict({"standingYes": True, "migrationGlobs": GLOBS, "approvedMigrations": entries}, **(extra or {}))
    write(path, ".claude/ds-config.json", json.dumps({"release": {"fullRelease": full}}))
    commit(path, "approve")

def entry(b, name=MIG):
    return {"blob": b, "path": name, "item": "I20130", "approved": TODAY}

def check(path, base="develop", head="work", cwd=None, already=()):
    p = subprocess.run([sys.executable, helper, "check", "--base", base, "--head", head] + [x for ref in already for x in ("--already", ref)],
                       capture_output=True, text=True, cwd=cwd or path)
    try:
        return p.returncode, json.loads(p.stdout), p
    except ValueError:
        return p.returncode, {}, p

ON = {"standingYes": True, "migrationGlobs": GLOBS, "approvedMigrations": []}

# no migration in the diff
r = repo(ON); write(r, "src/a.ts", "x"); commit(r, "work")
rc, out, p = check(r)
say(rc == 0 and out == {"applies": True, "approved": True, "reason": "this branch adds or changes no migration", "unapproved": []}, "no migration in the diff: approved", p.stdout + p.stderr)

# a new migration, unapproved; then approved by blob; then edited afterwards
r = repo(ON); write(r, MIG, "create table x();"); commit(r, "work")
rc, out, p = check(r)
say(rc == 2 and out.get("approved") is False and out.get("unapproved") == [{"path": MIG, "blob": blob(r, MIG), "status": "new"}]
    and MIG in out.get("reason", ""), "a new migration, unapproved: exit 2, named with its blob", p.stdout + p.stderr)
approve(r, [entry(blob(r, MIG))])
rc, out, p = check(r)
say(rc == 0 and out.get("approved") is True and out.get("unapproved") == [], "a new migration approved by blob: approved", p.stdout + p.stderr)
write(r, MIG, "create table x(id int);"); commit(r, "edit")
rc, out, p = check(r)
say(rc == 2 and out["unapproved"][0]["status"] == "new" and out["unapproved"][0]["blob"] == blob(r, MIG), "an approved migration edited afterwards: unapproved again", p.stdout + p.stderr)

# a migration already on the base is not in the diff; changing it is "changed"; deleting it is "deleted"
r = repo(ON, {MIG: "create table x();"}); write(r, "src/a.ts", "x"); commit(r, "work")
rc, out, p = check(r)
say(rc == 0 and out["reason"] == "this branch adds or changes no migration", "a migration already on the base: not asked about", p.stdout + p.stderr)
write(r, MIG, "create table x(id int);"); commit(r, "change")
rc, out, p = check(r)
say(rc == 2 and out["unapproved"] == [{"path": MIG, "blob": blob(r, MIG), "status": "changed"}], "a migration on the base, changed: status changed", p.stdout + p.stderr)
git(r, "rm", "-q", MIG); commit(r, "delete")
rc, out, p = check(r)
say(rc == 2 and out["unapproved"] == [{"path": MIG, "blob": "", "status": "deleted"}], "a migration deleted: unapproved, status deleted", p.stdout + p.stderr)

# renamed with the same content: the approval is by content
r = repo(ON); write(r, MIG, "create table x();"); commit(r, "work"); approve(r, [entry(blob(r, MIG))])
git(r, "mv", MIG, "db/migrations/sql/0353_add_x.sql"); commit(r, "renumber")
rc, out, p = check(r)
say(rc == 0 and out["approved"] is True, "a migration renamed with the same content: still approved", p.stdout + p.stderr)

# a path that only contains a glob's text is not a migration
r = repo(ON); write(r, "docs/db/migrations/sql/0352_add_x.sql", "x"); write(r, "db/migrations/sql/old/0001.sql", "x"); write(r, "db/migrations/sql/0352_add_x.sql.bak", "x"); commit(r, "work")
rc, out, p = check(r)
say(rc == 0 and out["reason"] == "this branch adds or changes no migration", "a path that only contains a glob's text: not a migration", p.stdout + p.stderr)

# ** crosses folders; two unapproved are both listed
r = repo(ON); write(r, "db/campaigns/a/b/run.ts", "x"); write(r, MIG, "y"); commit(r, "work")
rc, out, p = check(r)
say(rc == 2 and sorted(u["path"] for u in out["unapproved"]) == ["db/campaigns/a/b/run.ts", MIG] and out["reason"].startswith("2 migrations without"), "two unapproved migrations: both listed", p.stdout + p.stderr)

# not applicable: no migrationGlobs, no standing yes, the key set to false
for label, full in (("config with no migrationGlobs", {"standingYes": True}),
                    ("no written standing yes", {"standingYes": False, "migrationGlobs": GLOBS}),
                    ("a non-boolean standing yes is off", {"standingYes": "true", "migrationGlobs": GLOBS}),
                    ("the key set to false", dict(ON, approveBeforeJoining=False)),
                    ("no fullRelease block at all", None)):
    r = repo(full if full is not None else json.dumps({"release": {}})); write(r, MIG, "x"); commit(r, "work")
    rc, out, p = check(r)
    say(rc == 0 and out.get("applies") is False and out.get("approved") is True and out.get("unapproved") == [], "%s: not applicable, exit 0" % label, p.stdout + p.stderr)
r = repo(dict(ON, approveBeforeJoining=True)); write(r, MIG, "x"); commit(r, "work")
say(check(r)[0] == 2, "the key set to true: asked")

# the RULE is the base's committed one: a branch never switches the question off for itself
for label, change in (("switches the standing yes off", {"standingYes": False, "migrationGlobs": GLOBS}),
                      ("narrows the globs to nothing", {"standingYes": True, "migrationGlobs": ["nothing/*.none"]}),
                      ("sets approveBeforeJoining false", dict(ON, approveBeforeJoining=False))):
    r = repo(ON); write(r, MIG, "x"); write(r, ".claude/ds-config.json", json.dumps({"release": {"fullRelease": change}})); commit(r, "work")
    rc, out, p = check(r)
    say(rc == 2 and out["unapproved"][0]["path"] == MIG, "a branch that %s is still asked" % label, p.stdout + p.stderr)
r = repo(ON); write(r, MIG, "x"); git(r, "rm", "-q", ".claude/ds-config.json"); commit(r, "work")
rc, out, p = check(r)
say(rc == 2, "a branch that deletes the config is still asked", p.stdout + p.stderr)
r = repo({"standingYes": False}); approve(r, []); write(r, MIG, "x"); commit(r, "work")
rc, out, p = check(r)
say(rc == 0 and out["applies"] is False, "a rule only the branch itself turns on is not the base's: not applicable", p.stdout + p.stderr)
r = repo(ON); write(r, MIG, "x"); commit(r, "work")
write(r, ".claude/ds-config.json", json.dumps({"release": {}}))  # uncommitted: must not be read
say(check(r)[0] == 2, "nothing is read from the work tree")
r = repo(ON); write(r, MIG, "x"); write(r, ".claude/ds-config.json", "{not json"); commit(r, "work")
rc, out, p = check(r)
say(rc == 1 and "cannot be read as JSON" in out.get("reason", ""), "approvals that cannot be read at the head: exit 1, never approved", p.stdout + p.stderr)
r = repo("[1, 2]"); write(r, MIG, "x"); commit(r, "work")
rc, out, p = check(r)
say(rc == 1 and "not a JSON object" in out.get("reason", ""), "a base config that is not an object: exit 1, never not-applicable", p.stdout + p.stderr)
r = repo(ON); git(r, "checkout", "-q", "--orphan", "bare"); git(r, "rm", "-rqf", "."); write(r, "readme", "x"); commit(r, "no config"); git(r, "checkout", "-q", "-b", "work2"); write(r, MIG, "x"); commit(r, "work")
rc, out, p = check(r, base="bare", head="work2")
say(rc == 0 and out["applies"] is False, "a base with no config at all: not applicable", p.stdout + p.stderr)

# unanswerable: exit 1
r = repo("{not json"); write(r, MIG, "x"); commit(r, "work")
rc, out, p = check(r)
say(rc == 1 and out.get("approved") is False and "cannot be read as JSON" in out.get("reason", ""), "unreadable config: exit 1, never approved", p.stdout + p.stderr)
r = repo(ON); write(r, MIG, "x"); commit(r, "work")
rc, out, p = check(r, head="0" * 40)
say(rc == 1 and "fetch it first" in out.get("reason", ""), "a head that is not a commit here: exit 1", p.stdout + p.stderr)
rc, out, p = check(r, base="origin/nowhere")
say(rc == 1 and out.get("approved") is False, "a base that is not a commit here: exit 1", p.stdout + p.stderr)
approve(r, [{"blob": "abc", "path": MIG}])
rc, out, p = check(r)
say(rc == 1 and "approvedMigrations[0]" in out.get("reason", ""), "a malformed approval: exit 1", p.stdout + p.stderr)
r = repo(ON); write(r, "db/migrations/sql/bad\nname.sql", "x"); commit(r, "work")
rc, out, p = check(r)
say(rc == 1 and "control character" in out.get("reason", ""), "a file name with a line break: exit 1", p.stdout + p.stderr)
r = repo(ON); os.symlink("/etc/hosts", os.path.join(r, MIG.replace("0352_add_x", "0354_link"))) if os.makedirs(os.path.join(r, "db/migrations/sql"), exist_ok=True) is None else None; commit(r, "work")
rc, out, p = check(r)
say(rc == 2 and out["unapproved"][0]["status"] == "not-a-file", "a link in place of a migration: unapproved, never a blob to approve", p.stdout + p.stderr)

# git settings and replaced objects do not change the answer; a sub-folder works
r = repo(ON); write(r, MIG, "x"); commit(r, "work")
git(r, "config", "diff.relative", "true")
rc, out, p = check(r, cwd=os.path.join(r, "db"))
say(rc == 2 and out["unapproved"][0]["path"] == MIG, "diff.relative set, run from a sub-folder: still found, full path", p.stdout + p.stderr)
git(r, "replace", git(r, "rev-parse", "work").stdout.strip(), git(r, "rev-parse", "develop").stdout.strip())
say(check(r)[0] == 2, "a replaced head object is not believed")

# content already on the train or in production is not joining anything
r = repo(ON); write(r, MIG, "create table x();"); commit(r, "work")
git(r, "branch", "train", "work"); git(r, "branch", "prod", "develop")
rc, out, p = check(r, already=["prod"])
say(rc == 2, "content that is not at the --already ref is still asked about", p.stdout + p.stderr)
rc, out, p = check(r, already=["prod", "train"])
say(rc == 0 and out["approved"] is True and out["unapproved"] == [], "content already on the train: not asked about", p.stdout + p.stderr)
write(r, MIG, "create table x(id int);"); commit(r, "edit")
rc, out, p = check(r, already=["train"])
say(rc == 2 and out["unapproved"][0]["status"] == "new", "the same path with other content than the train holds: asked about", p.stdout + p.stderr)
r = repo(ON, {MIG: "x"}); git(r, "rm", "-q", MIG); commit(r, "delete"); git(r, "branch", "train", "work")
say(check(r, already=["train"])[0] == 0 and check(r)[0] == 2, "a deletion the train already made: not asked about")
rc, out, p = check(r, already=["nowhere"])
say(rc == 1 and "fetch it first" in out.get("reason", ""), "an --already ref that is not a commit here: exit 1", p.stdout + p.stderr)

# the shortcut for content already there is never a way round the checks
r = repo(ON, {MIG: "target"}); git(r, "branch", "prod", "develop")
os.remove(os.path.join(r, MIG)); os.symlink("target", os.path.join(r, MIG)); commit(r, "link with the same blob")
rc, out, p = check(r, already=["prod"])
say(rc == 2 and out["unapproved"][0]["status"] == "not-a-file", "a link whose text is the file production holds: never excused", p.stdout + p.stderr)
r = repo(ON); git(r, "branch", "oldtrain", "develop"); git(r, "checkout", "-q", "develop"); write(r, MIG, "x"); commit(r, "base gains it")
git(r, "branch", "prod", "develop"); git(r, "checkout", "-q", "-B", "work", "develop"); git(r, "rm", "-q", MIG); commit(r, "delete")
rc, out, p = check(r, already=["oldtrain", "prod"])
say(rc == 2 and out["unapproved"][0]["status"] == "deleted", "a deletion is not excused by a branch that never held the file", p.stdout + p.stderr)
r = repo(ON); write(r, MIG, "create table x();"); commit(r, "work"); approve(r, [entry(blob(r, MIG))])
rc, out, p = check(r, cwd=os.path.join(r, "db"))
say(rc == 0 and out["approved"] is True, "run from a sub-folder: an approved file is still a plain file", p.stdout + p.stderr)

# a policy handed in by the caller decides instead of the base's commit
r = repo({"standingYes": False}); write(r, MIG, "x"); commit(r, "work")
rule_file = os.path.join(work, "rule.json"); json.dump({"release": {"fullRelease": ON}}, open(rule_file, "w"))
p = subprocess.run([sys.executable, helper, "check", "--base", "develop", "--head", "work", "--rule", rule_file], capture_output=True, text=True, cwd=r)
say(p.returncode == 2 and json.loads(p.stdout)["unapproved"][0]["path"] == MIG, "--rule: the caller's reading of the base policy is the rule", p.stdout + p.stderr)
open(rule_file, "w").write("{bad")
p = subprocess.run([sys.executable, helper, "check", "--base", "develop", "--head", "work", "--rule", rule_file], capture_output=True, text=True, cwd=r)
say(p.returncode == 1 and json.loads(p.stdout)["approved"] is False, "--rule: a policy file that cannot be read is exit 1", p.stdout + p.stderr)

# both sides changed the same migration: the merge would be content neither approved
r = repo(ON, {MIG: "one\ntwo\nthree\nfour\nfive\n"})
write(r, MIG, "one\ntwo\nthree\nfour\nFIVE\n"); commit(r, "head edits the end"); approve(r, [entry(blob(r, MIG))])
git(r, "checkout", "-q", "develop"); write(r, MIG, "ONE\ntwo\nthree\nfour\nfive\n"); commit(r, "base edits the start"); git(r, "checkout", "-q", "work")
rc, out, p = check(r)
say(rc == 2 and len(out["unapproved"]) == 1 and out["unapproved"][0]["status"] == "changed-on-both" and out["unapproved"][0]["blob"] not in (blob(r, MIG), blob(r, MIG, "develop")),
    "both sides changed the same migration: what would land is neither, refused until refreshed", p.stdout + p.stderr)
git(r, "merge", "-q", "develop", "-m", "refresh")
rc, out, p = check(r)
say(rc == 2 and out["unapproved"][0]["status"] == "changed" and out["unapproved"][0]["blob"] == blob(r, MIG), "after the refresh the merged content is what is asked about", p.stdout + p.stderr)
approve(r, [entry(blob(r, MIG))])
say(check(r)[0] == 0, "and once that content is approved it joins")
r = repo(ON, {MIG: "x\n"}); write(r, "src/a.ts", "x"); commit(r, "work")
git(r, "checkout", "-q", "develop"); write(r, MIG, "y\n"); commit(r, "only the base changes it"); git(r, "checkout", "-q", "work")
say(check(r)[0] == 0, "a migration only the base changed is not this branch's to answer for")
# a rename on one side meeting an edit on the other: the content exists only in the merge
BODY = "".join("line %d\n" % n for n in range(1, 21))
r = repo(ON, {"src/template.sql": BODY})
write(r, "src/template.sql", BODY.replace("line 20\n", "LINE 20\n")); commit(r, "head edits the original")
git(r, "checkout", "-q", "develop"); os.remove(os.path.join(r, "src/template.sql")); write(r, MIG, BODY.replace("line 1\n", "LINE 1\n")); commit(r, "base moves it into the migrations")
approve(r, [entry(blob(r, MIG))]); git(r, "checkout", "-q", "work")
rc, out, p = check(r)
say(rc == 2 and out["unapproved"] == [{"path": MIG, "blob": out["unapproved"][0]["blob"], "status": "changed-on-both"}],
    "the base moved a file into the migrations and the branch edits the original: the merged content is asked about", p.stdout + p.stderr)
r = repo(ON, {"src/template.sql": BODY})
os.remove(os.path.join(r, "src/template.sql")); write(r, MIG, BODY.replace("line 1\n", "LINE 1\n")); commit(r, "head moves it into the migrations"); approve(r, [entry(blob(r, MIG))])
git(r, "checkout", "-q", "develop"); write(r, "src/template.sql", BODY.replace("line 20\n", "LINE 20\n")); commit(r, "base edits the original"); git(r, "checkout", "-q", "work")
rc, out, p = check(r)
say(rc == 2 and out["unapproved"][0]["path"] == MIG and out["unapproved"][0]["status"] == "changed-on-both",
    "the branch moved a file into the migrations and the base edits the original: asked about too", p.stdout + p.stderr)
r = repo(ON, {MIG: "x\n"}); write(r, MIG, "head\n"); commit(r, "head")
git(r, "checkout", "-q", "develop"); write(r, MIG, "base\n"); commit(r, "base"); git(r, "checkout", "-q", "work")
rc, out, p = check(r)
say(rc == 1 and "does not merge cleanly" in out.get("reason", ""), "a branch that does not merge cleanly: exit 1, refresh first", p.stdout + p.stderr)

# usage
p = subprocess.run([sys.executable, helper, "check", "--base", "develop"], capture_output=True, text=True, cwd=r)
say(p.returncode == 2 and p.stdout == "" and p.stderr.startswith("migration-approval: "), "a missing argument: exit 2, one line", p.stderr)
p = subprocess.run([sys.executable, helper], capture_output=True, text=True, cwd=r)
say(p.returncode == 2 and p.stderr.startswith("migration-approval: "), "no subcommand: exit 2", p.stderr)

# entry: what an approval records
r = repo(ON); write(r, MIG, "create table x();"); commit(r, "work")
def entry_run(*args):
    p = subprocess.run([sys.executable, helper, "entry"] + list(args), capture_output=True, text=True, cwd=r)
    try:
        return p.returncode, json.loads(p.stdout), p
    except ValueError:
        return p.returncode, {}, p
BASE = ["--head", "work", "--path", MIG, "--item", "I20130", "--unit", "I20104", "--asked", "2026-03-14T09:00:00-06:00", "--approved", "2026-03-14T15:20:00Z"]
rc, out, p = entry_run(*BASE)
DAY = __import__("datetime").datetime(2026, 3, 14, 15, 20, tzinfo=__import__("datetime").timezone.utc).astimezone().date().isoformat()
say(rc == 0 and out == {"entry": {"blob": blob(r, MIG), "path": MIG, "item": "I20130", "approved": DAY},
                        "subject": "chore(release): approve migration %s [I20130]" % MIG,
                        "trailers": ["Migration-Approval-Unit: I20104", "Migration-Approval-Asked: 2026-03-14T15:00:00Z", "Migration-Approval-Approved: 2026-03-14T15:20:00Z"]},
    "entry: the approval, the commit subject and the hold record", p.stdout + p.stderr)
# the built entry, committed with its trailers, is approved and readable from history alone
approve(r, [out["entry"]])
git(r, "commit", "-q", "--amend", "-m", out["subject"], "-m", "\n".join(out["trailers"]))
say(check(r)[0] == 0, "entry: the entry it builds is the one check accepts")
log = git(r, "log", "-1", "--format=%(trailers:key=Migration-Approval-Unit,valueonly)|%(trailers:key=Migration-Approval-Asked,valueonly)|%(trailers:key=Migration-Approval-Approved,valueonly)").stdout
say([part.strip() for part in log.split("|")] == ["I20104", "2026-03-14T15:00:00Z", "2026-03-14T15:20:00Z"], "entry: the hold record reads back from git history", log)
for label, change, needle in (("an item that is not one", ["--item", "20130"], "--item"),
                              ("a time with no offset", ["--asked", "2026-03-14T09:00:00"], "ISO times"),
                              ("asked after approved", ["--asked", "2026-03-15T09:00:00Z"], "after --approved"),
                              ("a unit with a space", ["--unit", "I20104 x"], "--unit"),
                              ("a unit ending in a line break", ["--unit", "I20104\n"], "--unit"),
                              ("an item ending in a line break", ["--item", "I20130\n"], "--item"),
                              ("an approval in the future", ["--approved", "2099-01-01T00:00:00Z"], "in the future"),
                              ("an approval half a minute ahead", ["--approved", (__import__("datetime").datetime.now(__import__("datetime").timezone.utc) + __import__("datetime").timedelta(seconds=30)).isoformat()], "in the future"),
                              ("a folder in place of a file", ["--path", "db/migrations/sql/"], "not a plain file"),
                              ("a folder with one file in it", ["--path", "db/migrations/sql"], "not a plain file"),
                              ("a file that is not there", ["--path", "db/migrations/sql/none.sql"], "not a plain file"),
                              ("a head that is not a commit", ["--head", "nowhere"], "not a commit")):
    args = list(BASE)
    args[args.index(change[0]) + 1] = change[1]
    rc, out, p = entry_run(*args)
    say(rc == 2 and p.stdout == "" and p.stderr.startswith("migration-approval: ") and needle in p.stderr, "entry refuses: " + label, p.stderr)
p = subprocess.run([sys.executable, helper, "entry"] + BASE, capture_output=True, text=True, cwd=os.path.join(r, "db"))
say(p.returncode == 0 and json.loads(p.stdout)["entry"]["blob"] == blob(r, MIG, "work"), "entry: run from a sub-folder, the path is still from the repository root", p.stdout + p.stderr)
print("ran to the end")
PY
RC=$?
OUT="$(cat "$WORK/out")"
echo "$OUT"
[ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q '^ran to the end$' || { echo "migration-approval: the runner itself failed (exit $RC)"; exit 1; }
FAILS=$(printf '%s\n' "$OUT" | grep -c '^FAIL')
[ "$FAILS" -eq 0 ] || { echo "migration-approval: $FAILS failed"; exit 1; }
