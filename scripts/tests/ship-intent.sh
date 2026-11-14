#!/bin/bash
# Tests for skills/build-item/scripts/ship-intent.py: every case in ship-intent-fixtures.json
# through the helper's own command line. No network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/skills/build-item/scripts/ship-intent.py"; FIX="$ROOT/skills/build-item/scripts/ship-intent-fixtures.json"
OUT="$(python3 - "$HELPER" "$FIX" <<'PY'
import json, subprocess, sys
helper, fx = sys.argv[1], json.load(open(sys.argv[2]))

def run(mode, text):
    return subprocess.run([sys.executable, helper, mode], input=text, capture_output=True, text=True)

def say(good, label, extra=""):
    print(("ok   " if good else "FAIL ") + label + ("" if good else " -> " + extra))

for c in fx["cases"]:
    p = run(c["run"], json.dumps(c["request"]))
    good = p.returncode == 0 and json.loads(p.stdout) == c["expect"]
    say(good, "%s: %s" % (c["run"], c["name"]), "rc=%d %s %s" % (p.returncode, p.stdout.strip(), p.stderr.strip()))
for c in fx["errors"]:
    p = run(c["run"], json.dumps(c["request"]))
    lines = p.stderr.splitlines()
    good = p.returncode == 2 and p.stdout == "" and len(lines) == 1 and lines[0].startswith("ship-intent: ") and c["contains"] in lines[0]
    say(good, "refuses: " + c["name"], "rc=%d %r" % (p.returncode, p.stderr))
for mode in ("record", "decide"):
    p = run(mode, "[")
    say(p.returncode == 2 and p.stdout == "" and p.stderr.startswith("ship-intent: "), "refuses: not JSON (%s)" % mode, p.stderr)
    p = run(mode, "[]")
    say(p.returncode == 2 and p.stderr.startswith("ship-intent: "), "refuses: not an object (%s)" % mode, p.stderr)
p = subprocess.run([sys.executable, helper, "claim"], input="{}", capture_output=True, text=True)
say(p.returncode == 2 and p.stderr.startswith("usage: "), "refuses: an unknown subcommand", p.stderr)
# with no clock given, the estimate is in the future and no holder ever appears in an answer
p = run("record", json.dumps({"lane": "train", "unit": "I20130", "branch": "b", "target": "t", "stage": "landing"}))
out = json.loads(p.stdout) if p.returncode == 0 else {}
say(sorted(out.get("payload", {})) == ["branch", "class", "lane", "readyBy", "stage", "target", "unit"], "record: the payload carries exactly the seven keys", p.stdout + p.stderr)
say("holder" not in p.stdout, "record: no holder in the answer", p.stdout)
PY
)"
echo "$OUT"
FAILS=$(printf '%s\n' "$OUT" | grep -c '^FAIL')
[ "$FAILS" -eq 0 ] || { echo "ship-intent: $FAILS failed"; exit 1; }
