#!/bin/bash
# Tests for skills/build-item/scripts/review-gate.py: every case in review-gate-fixtures.json
# through the helper's own command line (git-free), then a real repository: record a review, check
# it, and prove a new commit or a merged-in train voids it. No network.
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
        json.dump(r, open(os.path.join(d, head + ".json"), "w"))
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
for label, args, body in (("not JSON", ["check"], "{"), ("no subcommand", [], "{}"), ("unknown subcommand", ["merge"], "{}"), ("a JSON array", ["check"], "[]")):
    p = subprocess.run([sys.executable, helper] + args, input=body, capture_output=True, text=True)
    say(p.returncode == 2 and p.stderr.startswith("review-gate: ") and "Traceback" not in p.stderr, "refuses: " + label, repr(p.stderr))

# A real repository: the defaults (config file, git diff, receipts under the git common dir).
g = lambda *a, **k: subprocess.run(["git", "-C", repo] + list(a), check=True, capture_output=True, text=True, **k).stdout.strip()
repo = os.path.join(work, "repo"); os.makedirs(os.path.join(repo, ".claude"))
g("init", "-q", "-b", "train/release"); g("config", "user.email", "t@example.com"); g("config", "user.name", "t")
json.dump({"releaseTrain": {"branch": "train/release", "smallFixes": {"maxFiles": 2, "maxChangedLines": 500}}}, open(os.path.join(repo, ".claude/ds-config.json"), "w"))
g("add", "-A"); g("commit", "-qm", "base")
g("checkout", "-qb", "I1-big")
for i in range(3):
    open(os.path.join(repo, "f%d.ts" % i), "w").write("x\n")
g("add", "-A"); g("commit", "-qm", "big")
p = run("check", {"base": "train/release"}, cwd=repo)
say(p.returncode == 2 and "run /devstride:review local-full train/release" in p.stderr, "git: an unreviewed large fix is refused", p.stderr)
p = run("record", {"base": "train/release", "cycles": 2, "engines": ["claude", "codex"], "findings": []}, cwd=repo)
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
g("checkout", "-q", "I1-big"); g("merge", "-q", "--no-edit", "train/release")
p = run("check", {"base": "train/release"}, cwd=repo)
say(p.returncode == 2 and "LOCAL-FULL review settled" in p.stderr, "git: merging the train in is a new head: review again", p.stderr)
open(os.path.join(repo, "f0.ts"), "w").write("y\n"); g("commit", "-qam", "fix")
p = run("check", {"base": "train/release"}, cwd=repo)
say(p.returncode == 2, "git: a new commit voids the review", p.stderr)
PY
)"
echo "$OUT" | sed 's/^/  /'
FAIL=0; echo "$OUT" | grep -q '^FAIL' && FAIL=1
[ "$(echo "$OUT" | grep -c '^ok')" -ge 30 ] || { echo "  FAIL too few cases ran"; FAIL=1; }
exit $FAIL
