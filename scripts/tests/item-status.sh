#!/bin/bash
# Tests for skills/build-item/scripts/item-status.py — every case in item-status-fixtures.json
# through the helper's own command line, plus its refusal contract (exit 2, one `item-status:`
# line, never a traceback) and its usage line. No network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/skills/build-item/scripts/item-status.py"; FIX="$ROOT/skills/build-item/scripts/item-status-fixtures.json"
FAIL=0
OUT="$(python3 - "$HELPER" "$FIX" <<'PY'
import json, subprocess, sys
helper, fx = sys.argv[1], json.load(open(sys.argv[2]))

def request(case):
    req = dict(case["request"])
    ws = dict(fx["workspace"]); ws.update(req.get("workspace", {})); req["workspace"] = ws
    return req

def run(args, body):
    return subprocess.run([sys.executable, helper] + args, input=body, capture_output=True, text=True)

for case in fx["cases"]:
    p = run(["decide"], json.dumps(request(case)))
    try:
        out = json.loads(p.stdout)
    except ValueError:
        out = None
    good = p.returncode == 0 and isinstance(out, dict) and isinstance(out.pop("message", None), str) and out == case["expect"]
    print(("ok   " if good else "FAIL ") + case["name"] + ("" if good else " -> rc=%d %s %s" % (p.returncode, p.stdout.strip(), p.stderr.strip())))
for case in fx["errors"]:
    p = run(["decide"], json.dumps(request(case)))
    lines = p.stderr.strip().split("\n")
    good = p.returncode == 2 and p.stdout == "" and len(lines) == 1 and lines[0].startswith("item-status: ")
    print(("ok   " if good else "FAIL ") + "refuses: " + case["name"] + ("" if good else " -> rc=%d %r" % (p.returncode, p.stderr)))
for label, args, body in (("not JSON", ["decide"], "{"), ("no subcommand", [], "{}"), ("unknown subcommand", ["move"], "{}"),
                          ("a JSON array", ["decide"], "[]")):
    p = run(args, body)
    good = p.returncode == 2 and p.stderr.startswith("item-status: ") and "Traceback" not in p.stderr
    print(("ok   " if good else "FAIL ") + "refuses: " + label)
# The messages a caller shows must name the item.
p = run(["decide"], json.dumps(request(fx["cases"][0])))
print(("ok   " if "I101" in json.loads(p.stdout)["message"] else "FAIL ") + "message names the item")
PY
)"
echo "$OUT" | sed 's/^/  /'
echo "$OUT" | grep -q '^FAIL' && FAIL=1
[ "$(echo "$OUT" | grep -c '^ok')" -ge 30 ] || { echo "  FAIL too few cases ran"; FAIL=1; }
exit $FAIL
