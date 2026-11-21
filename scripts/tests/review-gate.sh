#!/bin/bash
# Tests for skills/build-item/scripts/review-gate.py: every case in review-gate-fixtures.json
# (check, record, round and engine) through the helper's own command line (git-free), then a real repository: record a review, check
# it, prove a merged-in train or a change only to generated files carries it forward under an unchanged
# patch (a `gen/**` pattern too), and that a commit changing the patch voids it: a re-indent included, and
# the same patch on a branch that does not hold the reviewed head. No network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/skills/build-item/scripts/review-gate.py"; FIX="$ROOT/skills/build-item/scripts/review-gate-fixtures.json"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
OUT="$(python3 - "$HELPER" "$FIX" "$WORK" <<'PY'
import json, os, subprocess, sys, tempfile
helper, fx, work = sys.argv[1], json.load(open(sys.argv[2])), sys.argv[3]

def run(cmd, req, cwd=None):
    return subprocess.run([sys.executable, helper, cmd], input=json.dumps(req), capture_output=True, text=True, cwd=cwd)

def receipts(entries, head):
    d = tempfile.mkdtemp(dir=work)
    for r in entries:
        r = dict(r); name = r.pop("_filedAs", head)
        json.dump(r, open(os.path.join(d, name + ".json"), "w"))
    return d

def say(good, label, extra=""):
    print(("ok   " if good else "FAIL ") + label + ("" if good else " -> " + extra))

for c in fx["cases"]:
    req = dict(c["request"], receiptsDir=receipts(c["receipts"], c["request"]["head"]))
    p = run("check", req)
    out = json.loads(p.stdout) if p.returncode == 0 else None
    good = isinstance(out, dict) and isinstance(out.pop("reason", None), str) and out == c["expect"]
    say(good, c["name"], "rc=%d %s %s" % (p.returncode, p.stdout.strip(), p.stderr.strip()))
for c in fx["errors"]:
    req = dict(c["request"], receiptsDir=receipts(c["receipts"], c["request"].get("head", "x")))
    p = run("check", req)
    lines = p.stderr.strip().split("\n")
    good = p.returncode == 2 and p.stdout == "" and len(lines) == 1 and lines[0].startswith("review-gate: ") and c["contains"] in lines[0]
    say(good, "refuses: " + c["name"], "rc=%d %r" % (p.returncode, p.stderr))
for c in fx["record"]:
    d = tempfile.mkdtemp(dir=work)
    p = run("record", dict(c["request"], receiptsDir=d))
    if c["refuses"] is None:
        chk = run("check", dict(fx["cases"][1]["request"], head=c["request"]["head"], receiptsDir=d))
        out = json.loads(chk.stdout) if chk.returncode == 0 else {}
        good = p.returncode == 0 and out.get("verdict") == "reviewed" and out.get("mergeBody") == fx["cases"][1]["expect"]["mergeBody"]
        say(good, c["name"], "%s %s %s" % (p.stderr, chk.stdout, chk.stderr))
    else:
        good = p.returncode == 2 and c["refuses"] in p.stderr and not os.listdir(d)
        say(good, "refuses: " + c["name"], "rc=%d %r" % (p.returncode, p.stderr))
for c in fx["round"]:
    p = run("round", {"engines": c["engines"]})
    if "refuses" in c:
        lines = p.stderr.strip().split("\n")
        good = p.returncode == 2 and p.stdout == "" and len(lines) == 1 and c["refuses"] in lines[0]
    else:
        good = p.returncode == 0 and json.loads(p.stdout) == c["expect"]
    say(good, "round: " + c["name"], "rc=%d %s %s" % (p.returncode, p.stdout.strip(), p.stderr.strip()))
for c in fx["engine"]:
    path = os.path.join(tempfile.mkdtemp(dir=work), "engine.out")
    if c["output"] is not None:
        open(path, "w").write(c["output"])
    p = run("engine", dict(c["request"], outputFile=path))
    good = p.returncode == 0 and json.loads(p.stdout) == c["expect"]
    say(good, "engine: " + c["name"], "rc=%d %s %s" % (p.returncode, p.stdout.strip(), p.stderr.strip()))
for label, args, body in (("not JSON", ["check"], "{"), ("no subcommand", [], "{}"), ("unknown subcommand", ["merge"], "{}"), ("a JSON array", ["check"], "[]")):
    p = subprocess.run([sys.executable, helper] + args, input=body, capture_output=True, text=True)
    say(p.returncode == 2 and p.stderr.startswith("review-gate: ") and "Traceback" not in p.stderr, "refuses: " + label, repr(p.stderr))

d = tempfile.mkdtemp(dir=work); rec = fx["record"][0]["request"]
p = run("record", dict(rec, receiptsDir=d, patchId="2" * 40))
say(p.returncode == 0 and json.load(open(json.loads(p.stdout)["receipt"])).get("patchId") == "2" * 40,
    "record (git-free) keeps the patch id it is given", p.stdout + p.stderr)

# A real repository: the defaults (config file, git diff, receipts under the git common dir).
g = lambda *a, **k: subprocess.run(["git", "-C", repo] + list(a), check=True, capture_output=True, text=True, **k).stdout.strip()
repo = os.path.join(work, "repo"); os.makedirs(os.path.join(repo, ".claude"))
g("init", "-q", "-b", "train/release"); g("config", "user.email", "t@example.com"); g("config", "user.name", "t")
json.dump({"releaseTrain": {"branch": "train/release", "smallFixes": {"maxFiles": 2, "maxChangedLines": 500}},
           "generated": {"paths": ["gen/"]}}, open(os.path.join(repo, ".claude/ds-config.json"), "w"))
g("add", "-A"); g("commit", "-qm", "base")
g("checkout", "-qb", "I1-big")
for i in range(3):
    open(os.path.join(repo, "f%d.ts" % i), "w").write("x\n")
g("add", "-A"); g("commit", "-qm", "big")
p = run("check", {"base": "train/release"}, cwd=repo)
say(p.returncode == 2 and "run /devstride:review local-full train/release" in p.stderr, "git: an unreviewed large fix is refused", p.stderr)
p = run("record", {"base": "train/release", "cycles": 2, "engines": [{"engine": "claude", "result": "no-findings"}, {"engine": "codex", "result": "no-findings"}], "findings": []}, cwd=repo)
common = g("rev-parse", "--path-format=absolute", "--git-common-dir")
say(p.returncode == 0 and json.loads(p.stdout)["receipt"].startswith(os.path.join(common, "devstride", "reviews", "local-full")), "git: record writes under the git common dir", p.stderr)
p = run("check", {"base": "train/release"}, cwd=repo)
say(p.returncode == 0 and json.loads(p.stdout)["verdict"] == "reviewed", "git: the reviewed head is admitted", p.stdout + p.stderr)
wt = os.path.join(work, "wt"); g("worktree", "add", "-q", "--detach", wt, "I1-big")
p = run("check", {"base": "train/release"}, cwd=wt)
say(p.returncode == 0 and json.loads(p.stdout)["verdict"] == "reviewed", "git: another worktree of the repository finds the receipt", p.stdout + p.stderr)
g("checkout", "-q", "train/release"); open(os.path.join(repo, "t.ts"), "w").write("t\n"); g("add", "-A"); g("commit", "-qm", "train moved")
p = run("check", {"base": "train/release", "head": "I1-big"}, cwd=repo)
say(p.returncode == 0 and json.loads(p.stdout)["verdict"] == "reviewed", "git: the train moving on alone leaves the reviewed diff as it was", p.stdout + p.stderr)
reviewed = g("rev-parse", "I1-big")
receipt_file = os.path.join(common, "devstride", "reviews", "local-full", reviewed + ".json")
say(len(json.load(open(receipt_file)).get("patchId") or "") == 40, "git: record keeps the story's patch id", open(receipt_file).read())
g("checkout", "-q", "I1-big"); g("merge", "-q", "--no-edit", "train/release")
p = run("check", {"base": "train/release"}, cwd=repo)
out = json.loads(p.stdout) if p.returncode == 0 else {}
say(out.get("verdict") == "reviewed" and ("Review carried forward from %s" % reviewed) in out.get("mergeBody", "")
    and out["mergeBody"].startswith("Review: LOCAL-FULL at %s" % reviewed),
    "git: the train merged in under an unchanged patch carries the review forward", p.stdout + p.stderr)
os.makedirs(os.path.join(repo, "gen")); open(os.path.join(repo, "gen", "api.json"), "w").write("regenerated\n")
g("add", "-A"); g("commit", "-qm", "regenerate")
p = run("check", {"base": "train/release"}, cwd=repo)
say(p.returncode == 0 and json.loads(p.stdout)["verdict"] == "reviewed", "git: a change only to generated files keeps the review", p.stdout + p.stderr)
stored = json.load(open(receipt_file)); stored.pop("patchId"); json.dump(stored, open(receipt_file, "w"))
p = run("check", {"base": "train/release"}, cwd=repo)
say(p.returncode == 0 and json.loads(p.stdout)["verdict"] == "reviewed", "git: a receipt kept before patch ids is matched from git", p.stdout + p.stderr)
p = run("check", {"base": "train/release", "patchId": "1" * 40}, cwd=repo)
say(p.returncode == 2 and "computed" in p.stderr, "git: a patch id passed in is refused where git computes it", p.stderr)
open(os.path.join(repo, "f0.ts"), "w").write("y\n"); g("commit", "-qam", "fix")
p = run("check", {"base": "train/release"}, cwd=repo)
say(p.returncode == 2 and "or on this same patch" in p.stderr, "git: a commit that changes the patch voids the review", p.stderr)
engines = [{"engine": "claude", "result": "no-findings"}, {"engine": "codex", "result": "no-findings"}]
review = lambda: run("record", {"base": "train/release", "cycles": 1, "engines": engines, "findings": []}, cwd=repo)
every = lambda paths: json.dump({"releaseTrain": {"branch": "train/release", "reviewEveryLanding": True}, "generated": {"paths": paths}},
                                open(os.path.join(repo, ".claude/ds-config.json"), "w"))
every(["gen/"]); g("checkout", "-q", "-b", "I2-ws", "train/release")
open(os.path.join(repo, "w.py"), "w").write("if x:\n    pass\ny = 1\n"); g("add", "w.py"); g("commit", "-qm", "story")
say(review().returncode == 0, "git: a second story is reviewed")
open(os.path.join(repo, "w.py"), "w").write("if x:\n    pass\n    y = 1\n"); g("add", "w.py"); g("commit", "-qm", "indent")
p = run("check", {"base": "train/release"}, cwd=repo)
say(p.returncode == 2 and "or on this same patch" in p.stderr, "git: a change only to indentation after the review is a changed patch", p.stdout + p.stderr)
g("checkout", "-q", "-b", "I2-copy", "train/release")
open(os.path.join(repo, "w.py"), "w").write("if x:\n    pass\ny = 1\n"); g("add", "w.py"); g("commit", "-qm", "the same story, written again")
p = run("check", {"base": "train/release"}, cwd=repo)
say(p.returncode == 2, "git: the same patch on a branch that does not hold the reviewed head is not carried", p.stdout + p.stderr)
every(["gen/**"]); g("checkout", "-q", "-b", "I3-glob", "train/release")
open(os.path.join(repo, "s.ts"), "w").write("s\n" * 3); g("add", "s.ts"); g("commit", "-qm", "story")
say(review().returncode == 0, "git: a third story is reviewed")
os.makedirs(os.path.join(repo, "gen", "v2")); open(os.path.join(repo, "gen", "v2", "api.json"), "w").write("again\n"); g("add", "gen"); g("commit", "-qm", "regenerate")
p = run("check", {"base": "train/release"}, cwd=repo)
say(p.returncode == 0 and json.loads(p.stdout)["verdict"] == "reviewed", "git: a generated.paths pattern (gen/**) leaves those files out too", p.stdout + p.stderr)
PY
)"
echo "$OUT" | sed 's/^/  /'
FAIL=0; echo "$OUT" | grep -q '^FAIL' && FAIL=1
[ "$(echo "$OUT" | grep -c '^ok')" -ge 50 ] || { echo "  FAIL too few cases ran"; FAIL=1; }
exit $FAIL
