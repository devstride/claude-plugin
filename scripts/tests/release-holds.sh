#!/bin/bash
# Tests for skills/build-item/scripts/release-holds.py: every case in release-holds-fixtures.json
# through the helper's own command line (git-free), then a real repository for "after I... is live"
# under a configuration that records no post-deploy status. No network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/skills/build-item/scripts/release-holds.py"; FIX="$ROOT/skills/build-item/scripts/release-holds-fixtures.json"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
OUT="$(python3 - "$HELPER" "$FIX" "$WORK" <<'PY'
import json, os, subprocess, sys
helper, fx, work = sys.argv[1], json.load(open(sys.argv[2])), sys.argv[3]

def run(req, cwd=None):
    return subprocess.run([sys.executable, helper, "decide"], input=json.dumps(req), capture_output=True, text=True, cwd=cwd)

def say(good, label, extra=""):
    print(("ok   " if good else "FAIL ") + label + ("" if good else " -> " + extra))

def strip(out):
    out = dict(out); good = isinstance(out.pop("reason", None), str)
    holds = []
    for h in out.get("holds", []):
        h = dict(h); good = good and isinstance(h.pop("reason", None), str); holds.append(h)
    out["holds"] = holds
    return good, out

for c in fx["cases"]:
    p = run(c["request"])
    good, out = strip(json.loads(p.stdout)) if p.returncode == 0 else (False, None)
    say(good and out == c["expect"], c["name"], "rc=%d %s %s" % (p.returncode, p.stdout.strip(), p.stderr.strip()))
for c in fx["errors"]:
    p = run(c["request"])
    lines = p.stderr.splitlines()
    good = p.returncode == 2 and p.stdout == "" and len(lines) == 1 and lines[0].startswith("release-holds: ") and c["contains"] in lines[0]
    say(good, "refuses: " + c["name"], "rc=%d %r" % (p.returncode, p.stderr))
p = subprocess.run([sys.executable, helper, "decide"], input="[", capture_output=True, text=True)
say(p.returncode == 2 and p.stderr.startswith("release-holds: "), "refuses: not JSON", p.stderr)

repo = os.path.join(work, "repo")
def git(*a): subprocess.run(["git", "-C", repo] + list(a), check=True, capture_output=True)
os.makedirs(os.path.join(repo, ".claude"))
git("init", "-q", "-b", "master"); git("config", "user.email", "t@example.com"); git("config", "user.name", "t")
json.dump({"release": {"productionBranch": "master", "holdTimeZone": "America/Chicago"}}, open(os.path.join(repo, ".claude", "ds-config.json"), "w"))
git("add", "-A"); git("commit", "-qm", "base")
req = {"items": [{"number": "I20102", "description": "<p>Release hold: after I20101 is live</p>"}], "productionRef": "master"}
p = run(req, cwd=repo); out = json.loads(p.stdout) if p.returncode == 0 else {}
say(out.get("held") is True, "git: nothing names I20101 on master: held", p.stdout + p.stderr)
git("commit", "-q", "--allow-empty", "-m", "feat: x [I201010]")
p = run(req, cwd=repo); out = json.loads(p.stdout) if p.returncode == 0 else {}
say(out.get("held") is True, "git: I201010 is not I20101", p.stdout + p.stderr)
git("commit", "-q", "--allow-empty", "-m", "chore: I20101ABC")
p = run(req, cwd=repo); out = json.loads(p.stdout) if p.returncode == 0 else {}
say(out.get("held") is True, "git: I20101ABC is not I20101", p.stdout + p.stderr)
git("commit", "-q", "--allow-empty", "-m", "fix(y): z [I20101]")
p = run(req, cwd=repo); out = json.loads(p.stdout) if p.returncode == 0 else {}
say(out.get("held") is False and "no post-deploy status" in out["holds"][0]["reason"], "git: merged, with no post-deploy status recorded: met, and says so", p.stdout + p.stderr)
# under cut-to-deploy, an item commit inside a merged branch is found through the merge (no gh here:
# the lookup fails, which must refuse, never read as live or as "not on production")
git("checkout", "-q", "-b", "side"); git("commit", "-q", "--allow-empty", "-m", "feat: a [I20105]"); git("commit", "-q", "--allow-empty", "-m", "feat: b")
git("checkout", "-q", "master"); git("merge", "-q", "--no-ff", "side", "-m", "merge side")
cfg = os.path.join(repo, ".claude", "ds-config.json")
json.dump({"release": {"productionBranch": "master", "clearance": {"scope": "cut-to-deploy"}}}, open(cfg, "w"))
env = dict(os.environ, PATH="/usr/bin:/bin", GH_HOST="invalid.example")
q = subprocess.run([sys.executable, helper, "decide"], input=json.dumps({"items": [{"number": "I20102", "description": "<p>Release hold: after I20105 is live</p>"}], "productionRef": "master"}),
                   capture_output=True, text=True, cwd=repo, env=env)
say(q.returncode == 2 and "release/post-deploy" in q.stderr, "git: a commit inside a merged branch reaches the status lookup; an unreadable status refuses", q.stdout + q.stderr)
p = run(dict(req, productionRef="origin/nowhere"), cwd=repo)
say(p.returncode == 2, "git: an unknown production ref refuses", p.stderr)
PY
)"
echo "$OUT"
FAILS=$(printf '%s\n' "$OUT" | grep -c '^FAIL')
[ "$FAILS" -eq 0 ] || { echo "release-holds: $FAILS failed"; exit 1; }
