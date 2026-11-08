#!/bin/bash
# Tests for skills/build-item/scripts/consequence-notices.py: every case in
# consequence-notices-fixtures.json through the helper's own command line, then a real repository
# for the diff it reads itself, then the doctor lines. No network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/skills/build-item/scripts/consequence-notices.py"; FIX="$ROOT/skills/build-item/scripts/consequence-notices-fixtures.json"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
OUT="$(python3 - "$HELPER" "$FIX" "$WORK" <<'PY'
import json, os, subprocess, sys
helper, fx, work = sys.argv[1], json.load(open(sys.argv[2])), sys.argv[3]

def run(mode, req, cwd=None, args=()):
    return subprocess.run([sys.executable, helper, mode] + list(args), input=json.dumps(req),
                          capture_output=True, text=True, cwd=cwd)

def say(good, label, extra=""):
    print(("ok   " if good else "FAIL ") + label + ("" if good else " -> " + extra))

def judge(out, exp):
    html = (out.get("comment") or {}).get("html", "")
    good = out["post"] == exp["post"] and len(out["notices"]) == exp["notices"]
    good = good and ("recap" not in exp or out["recap"] == exp["recap"])
    good = good and (out["comment"] is not None) == exp["post"] and isinstance(out.get("reason"), str)
    good = good and all(s in html for s in exp.get("html", [])) and not any(s in html for s in exp.get("absent", []))
    return good

for c in fx["cases"]:
    p = run("check", c["request"])
    good = p.returncode == 0 and judge(json.loads(p.stdout), c["expect"])
    say(good, c["name"], "rc=%d %s %s" % (p.returncode, p.stdout.strip(), p.stderr.strip()))
for c in fx["cases"]:  # what check posts, collect reads back: same files, same side
    p = run("check", c["request"])
    out = json.loads(p.stdout) if p.returncode == 0 else {}
    if not out.get("post") or not out.get("notices"):
        continue
    back = run("collect", {"config": {}, "items": [{"number": c["request"]["item"], "comments": [out["comment"]]}]})
    got = json.loads(back.stdout)["notices"][0]["findings"] if back.returncode == 0 else []
    good = [(f["file"], f["where"], f["removed"]) for f in got] == [(n["file"], n["where"], n["side"] == "old") for n in out["notices"]]
    say(good, "round trip: " + c["name"], back.stdout + back.stderr)
for c in fx["cases"]:  # a posted notice passed back as earlier is never posted again
    p = run("check", c["request"])
    out = json.loads(p.stdout) if p.returncode == 0 else {}
    if not out.get("post"):
        continue
    again = run("check", dict(c["request"], earlier=c["request"].get("earlier", []) + [out["comment"]]))
    say(again.returncode == 0 and json.loads(again.stdout)["post"] is False, "posted once: " + c["name"], again.stdout + again.stderr)
for c in fx["errors"]:
    p = run("check", c["request"], cwd=work)
    lines = p.stderr.splitlines()
    good = p.returncode == 2 and p.stdout == "" and len(lines) == 1 and lines[0].startswith("consequence-notices: ") and c["contains"] in lines[0]
    say(good, "refuses: " + c["name"], "rc=%d %r" % (p.returncode, p.stderr))
for c in fx["collect"]:
    p = run("collect", c["request"])
    say(p.returncode == 0 and json.loads(p.stdout) == c["expect"], "collect: " + c["name"], p.stdout + p.stderr)
p = subprocess.run([sys.executable, helper, "check"], input="[", capture_output=True, text=True)
say(p.returncode == 2 and p.stderr.startswith("consequence-notices: "), "refuses: not JSON", p.stderr)

# A real repository: the helper reads base...head itself, and a file the config turns off.
repo = os.path.join(work, "repo"); os.makedirs(repo)
def git(*a):
    return subprocess.run(["git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@example.com"] + list(a),
                          check=True, capture_output=True, text=True).stdout.strip()
git("init", "-q", "-b", "main")
os.makedirs(os.path.join(repo, "api"))
open(os.path.join(repo, "api", "routes.ts"), "w").write("a\nb\nrouter.get('/v1/export', x);\nc\n")
git("add", "."); git("commit", "-qm", "base")
git("checkout", "-qb", "story")
open(os.path.join(repo, "api", "routes.ts"), "w").write("a\nb\nc\n")
open(os.path.join(repo, "my file.txt"), "w").write("new\n")
open(os.path.join(repo, "legacy.properties"), "wb").write("name=caf\xe9\n".encode("latin-1"))
git("add", "."); git("commit", "-qm", "story")
head = git("rev-parse", "HEAD")
base_req = {"item": "I20130", "head": head, "base": "main", "author": {"username": "ada", "name": "Ada Example"}, "earlier": []}
p = run("check", dict(base_req, findings=[{"category": "removed-caller-surface", "file": "api/routes.ts", "lines": "3",
                                            "side": "old", "sentence": "The export route is gone."}]), cwd=repo)
good = p.returncode == 0 and json.loads(p.stdout)["post"] is True
say(good, "reads base...head itself and accepts a removed line", p.stdout + p.stderr)
p = run("check", dict(base_req, findings=[{"category": "interface-break", "file": "my file.txt", "lines": "1",
                                            "sentence": "A new file."}]), cwd=repo)
say(p.returncode == 0 and json.loads(p.stdout)["post"] is True, "a path with a space", p.stdout + p.stderr)
git("config", "diff.noprefix", "true")
p = run("check", dict(base_req, findings=[{"category": "interface-break", "file": "legacy.properties", "lines": "1",
                                            "sentence": "A Latin-1 file in the diff."}]), cwd=repo)
say(p.returncode == 0 and json.loads(p.stdout)["post"] is True, "a Latin-1 file under diff.noprefix", p.stdout + p.stderr)
git("config", "--unset", "diff.noprefix")
p = run("check", dict(base_req, base="no-such-branch", findings=[]), cwd=repo)
say(p.returncode == 2 and "git diff" in p.stderr, "refuses: a base git cannot read", p.stderr)
os.makedirs(os.path.join(repo, ".claude"))
json.dump({"consequenceNotices": {"enabled": False}}, open(os.path.join(repo, ".claude", "ds-config.json"), "w"))
p = run("check", dict(base_req, findings=[]), cwd=repo)
say(p.returncode == 0 and json.loads(p.stdout)["post"] is False and "off" in json.loads(p.stdout)["reason"],
    "reads .claude/ds-config.json when config is absent", p.stdout + p.stderr)

# doctor
def doc(cfg):
    path = os.path.join(work, "cfg.json"); json.dump(cfg, open(path, "w"))
    return subprocess.run([sys.executable, helper, "doctor", "--config", path], capture_output=True, text=True)
p = doc({})
say(p.returncode == 0 and p.stdout.startswith("OK consequenceNotices: not set"), "doctor: not set", p.stdout)
p = doc({"consequenceNotices": {"notify": ["bo"], "categories": [{"id": "data-retention", "title": "T", "means": "M"}]}})
say(p.returncode == 0 and "5 categories" in p.stdout and "bo (resolve each in DevStride)" in p.stdout, "doctor: categories and notify", p.stdout)
p = doc({"consequenceNotices": {"categories": [{"id": "Bad Id", "title": "T", "means": "M"}], "notify": "bo"}})
say(p.returncode == 1 and p.stdout.count("ERROR ") == 2 and "OK " not in p.stdout, "doctor: two errors exit 1, no OK beside them", p.stdout)
PY
)"; RC=$?
echo "$OUT"
[ "$RC" -eq 0 ] || { echo "FAIL the test driver exited $RC"; exit 1; }
! printf '%s\n' "$OUT" | grep -q '^FAIL'
