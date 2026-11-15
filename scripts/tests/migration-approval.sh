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

# the config is the HEAD's committed one, never the work tree's, and never the base's
r = repo({"standingYes": False}); approve(r, [], None); write(r, MIG, "x"); commit(r, "work")
write(r, ".claude/ds-config.json", json.dumps({"release": {}}))  # uncommitted: must not be read
rc, out, p = check(r)
say(rc == 2, "the head's committed config decides, not the base's and not the work tree's", p.stdout + p.stderr)

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
say(rc == 0 and out == {"entry": {"blob": blob(r, MIG), "path": MIG, "item": "I20130", "approved": TODAY},
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
                              ("a file that is not there", ["--path", "db/migrations/sql/none.sql"], "not a plain file"),
                              ("a head that is not a commit", ["--head", "nowhere"], "not a commit")):
    args = list(BASE)
    args[args.index(change[0]) + 1] = change[1]
    rc, out, p = entry_run(*args)
    say(rc == 2 and p.stdout == "" and p.stderr.startswith("migration-approval: ") and needle in p.stderr, "entry refuses: " + label, p.stderr)
print("ran to the end")
PY
RC=$?
OUT="$(cat "$WORK/out")"
echo "$OUT"
[ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q '^ran to the end$' || { echo "migration-approval: the runner itself failed (exit $RC)"; exit 1; }
FAILS=$(printf '%s\n' "$OUT" | grep -c '^FAIL')
[ "$FAILS" -eq 0 ] || { echo "migration-approval: $FAILS failed"; exit 1; }
