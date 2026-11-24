#!/bin/bash
# Tests for skills/build-item/scripts/rollup.py — every case in
# skills/build-item/scripts/rollup-fixtures.json through the helper's own command line, plus its
# refusal contract (exit 2, one `rollup:` line, never a traceback). No git, no network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/skills/build-item/scripts/rollup.py"; FIX="$ROOT/skills/build-item/scripts/rollup-fixtures.json"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }

OUT="$(python3 - "$HELPER" "$FIX" <<'PY'
import copy, json, subprocess, sys
helper, fx = sys.argv[1], json.load(open(sys.argv[2]))

def merge(base, patch):
    out = copy.deepcopy(base)
    for key, value in patch.items():
        if value == "__delete__":
            out.pop(key, None)
        elif isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = merge(out[key], value)
        else:
            out[key] = value
    return out

def run(command, request):
    p = subprocess.run([sys.executable, helper, command], input=json.dumps(request), capture_output=True, text=True)
    return p

def answer(label, command, request, expect, contains=None):
    p = run(command, request)
    try:
        out = json.loads(p.stdout)
    except ValueError:
        out = None
    reason = None
    if command == "ready" and isinstance(out, dict):
        reason = out.pop("reason", None)  # a ready answer always explains itself; the words are checked by reasonContains
    good = p.returncode == 0 and p.stderr == "" and out == expect
    if command == "ready":
        good = good and isinstance(reason, str) and reason.strip() != "" and (contains is None or contains in reason)
    print(("ok   " if good else "FAIL ") + label + ("" if good else " -> rc=%d %s %s %r" % (p.returncode, p.stdout.strip(), p.stderr.strip(), reason)))

def refusal(label, command, request, contains):
    p = run(command, request)
    lines = p.stderr.rstrip("\n").split("\n")
    good = p.returncode == 2 and p.stdout == "" and len(lines) == 1 and lines[0].startswith("rollup: ") \
        and contains in lines[0] and "Traceback" not in p.stderr
    print(("ok   " if good else "FAIL ") + "refuses: " + label + ("" if good else " -> rc=%d %r" % (p.returncode, p.stderr)))

for c in fx["chain"]:
    answer("chain: " + c["name"], "chain", c["request"], c["expect"])
for c in fx["chainErrors"]:
    refusal("chain: " + c["name"], "chain", c["request"], c["contains"])
for c in fx["ready"]:
    answer("ready: " + c["name"], "ready", merge(fx["readyDefaults"], c["request"]), c["expect"], c.get("reasonContains"))
for c in fx["readyErrors"]:
    refusal("ready: " + c["name"], "ready", merge(fx["readyDefaults"], c["request"]), c["contains"])
PY
)"; RC=$?
printf '%s\n' "$OUT" | sed 's/^/  /'
if [ $RC -ne 0 ] || printf '%s\n' "$OUT" | grep -q '^FAIL'; then FAIL=1; fi
N="$(printf '%s\n' "$OUT" | grep -c '^ok')"
WANT="$(python3 -c 'import json,sys; f=json.load(open(sys.argv[1])); print(sum(len(f[k]) for k in ("chain","chainErrors","ready","readyErrors")))' "$FIX")"
[ "$N" = "$WANT" ] && [ "$N" -ge 72 ] && ok "(all $N fixture cases passed)" || bad "$N of $WANT fixture cases passed (at least 72 expected)"

# the cases the readiness rule must never lose (a fixture file that drops one fails here)
NAMES="$(python3 -c 'import json,sys; f=json.load(open(sys.argv[1])); print("\n".join(c["name"] for k in ("chain","chainErrors","ready","readyErrors") for c in f[k]))' "$FIX")"
for want in "three levels deep" "nested grouping counts only through its leaves" "deferred container and its members are excluded" \
            "a truncated descendants list" "an item that is not a rollup" "undetermined: names the two types and the remedy" \
            "the first entry is not the item asked about" "the answer is not an object" "rollup child does not count merely" \
            "HELD, the hold's reason quoted" "MANUAL" "ASK" \
            "the server's exact shape: work types and leaf parents as {id, name}" "the server's exact shape: descendants carry workTypeName" \
            "hidden children: every child the caller can see is complete" "no countsReadableChildrenOnly flag"; do
  printf '%s\n' "$NAMES" | grep -qF -- "$want" && ok "a fixture covers: $want" || bad "no fixture covers: $want"
done

# the refusal contract
for args in "ready|not json" "chain|[]" "ready|[]" "ready|\"text\"" "nope|{}"; do
  CMD="${args%%|*}"; IN="${args#*|}"
  ERR="$(printf '%s' "$IN" | python3 "$HELPER" "$CMD" 2>&1 >/dev/null)"; RC=$?
  if [ $RC -eq 2 ] && printf '%s' "$ERR" | grep -q '^rollup: ' && ! printf '%s' "$ERR" | grep -q Traceback; then
    ok "refuses $CMD <<< $IN with exit 2"; else bad "$CMD <<< $IN → rc=$RC $ERR"; fi
done
python3 "$HELPER" </dev/null >/dev/null 2>&1; [ $? -eq 2 ] && ok "no subcommand → exit 2" || bad "no subcommand"
python3 "$HELPER" chain ready </dev/null >/dev/null 2>&1; [ $? -eq 2 ] && ok "two subcommands → exit 2" || bad "two subcommands"

# dependency-free: standard library only
MODS="$(python3 -c 'import ast,sys; t=ast.parse(open(sys.argv[1]).read()); print(" ".join(sorted({a.name for n in ast.walk(t) if isinstance(n, ast.Import) for a in n.names} | {n.module for n in ast.walk(t) if isinstance(n, ast.ImportFrom)})))' "$HELPER")"
[ "$MODS" = "json sys" ] && ok "standard library only ($MODS)" || bad "imports: $MODS"
exit $FAIL
