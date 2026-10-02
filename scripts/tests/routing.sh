#!/bin/bash
# Tests for skills/build-item/scripts/routing.py — every case in
# skills/build-item/scripts/routing-fixtures.json through the helper's own command line, plus
# its refusal contract (exit 2, one `routing:` line, never a traceback). No git, no network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/skills/build-item/scripts/routing.py"; FIX="$ROOT/skills/build-item/scripts/routing-fixtures.json"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }

OUT="$(python3 - "$HELPER" "$FIX" <<'PY'
import copy, json, subprocess, sys
helper, fixtures = sys.argv[1], json.load(open(sys.argv[2]))

def merge(base, patch):
    out = copy.deepcopy(base)
    for key, value in patch.items():
        out[key] = merge(out[key], value) if isinstance(value, dict) and isinstance(out.get(key), dict) else value
    return out

def run(command, request):
    p = subprocess.run([sys.executable, helper, command], input=json.dumps(request), capture_output=True, text=True)
    return p.returncode, (json.loads(p.stdout) if p.returncode == 0 else p.stderr)

def check(label, command, request, expect, error=False):
    rc, out = run(command, request)
    if error:
        good = rc == 2 and out.startswith("routing: ") and "Traceback" not in out
    else:
        if rc == 0 and isinstance(out, dict):
            out.pop("reason", None)
        good = rc == 0 and out == expect
    print(("ok   " if good else "FAIL ") + label + ("" if good else " -> rc=%s %r, expected %r" % (rc, out, expect)))

config = fixtures["config"]
for c in fixtures["match"]:
    check("match %s ~ %s" % (c["name"], c["patterns"]), "match", {"name": c["name"], "patterns": c["patterns"]},
          {"matches": c["pattern"] is not None, "pattern": c["pattern"]})
for c in fixtures["prefix"]:
    check("prefix %r" % c["userName"], "prefix", {"userName": c["userName"]}, {"prefix": c.get("prefix")}, c.get("error", False))
for c in fixtures["slug"]:
    req = {"title": c["title"]}
    if "words" in c:
        req["words"] = c["words"]
    check("slug %r" % c["title"], "slug", req, {"slug": c.get("slug")}, c.get("error", False))
for c in fixtures["branchName"]:
    req = dict(c, config=config); req.pop("branch")
    check("branch-name %s" % c["branch"], "branch-name", req, {"branch": c["branch"]})
for c in fixtures["excluded"]:
    check("excluded %s" % c["files"], "excluded", {"config": config, "files": c["files"]}, {"excluded": c["excluded"]})
for c in fixtures["target"]:
    req = dict(fixtures["targetDefaults"])
    req.update({k: v for k, v in c.items() if k not in ("name", "config", "expect", "error")})
    req["config"] = merge(config, c.get("config", {}))
    check("target: " + c["name"], "target", req, c.get("expect"), c.get("error", False))
PY
)"; RC=$?
printf '%s\n' "$OUT" | sed 's/^/  /'
if [ $RC -ne 0 ] || printf '%s\n' "$OUT" | grep -q '^FAIL'; then FAIL=1; fi
N="$(printf '%s\n' "$OUT" | grep -c '^ok')"
WANT="$(python3 -c 'import json,sys; f=json.load(open(sys.argv[1])); print(sum(len(f[k]) for k in ("match","prefix","slug","branchName","excluded","target")))' "$FIX")"
[ "$N" = "$WANT" ] && [ "$N" -ge 50 ] && ok "(all $N fixture cases passed)" || bad "$N of $WANT fixture cases passed"

# the refusal contract
for args in "target|{\"config\":{\"baseBranch\":\"develop\",\"hierarchyRoles\":{\"leaf\":[\"Story\"],\"releaseUnit\":\"Epic\"}},\"chain\":[{\"number\":\"I1\",\"workType\":\"Story\"}],\"heads\":[null]}" "slug|{\"title\":5}" "match|{\"name\":\"a\",\"patterns\":\"a\"}" "target|not json" "nope|{}" "target|[]" "target|{\"config\":{\"baseBranch\":\"develop\"},\"chain\":[]}" "match|{\"name\":\"a\",\"patterns\":[\"\"]}"; do
  CMD="${args%%|*}"; IN="${args#*|}"
  ERR="$(printf '%s' "$IN" | python3 "$HELPER" "$CMD" 2>&1 >/dev/null)"; RC=$?
  if [ $RC -eq 2 ] && printf '%s' "$ERR" | grep -q '^routing: ' && ! printf '%s' "$ERR" | grep -q Traceback; then
    ok "refuses $CMD <<< $IN with exit 2"; else bad "$CMD <<< $IN → rc=$RC $ERR"; fi
done
python3 "$HELPER" </dev/null >/dev/null 2>&1; [ $? -eq 2 ] && ok "no subcommand → exit 2" || bad "no subcommand"

# dependency-free: standard library only
MODS="$(python3 -c 'import ast,sys; t=ast.parse(open(sys.argv[1]).read()); print(" ".join(sorted({a.name for n in ast.walk(t) if isinstance(n, ast.Import) for a in n.names} | {n.module for n in ast.walk(t) if isinstance(n, ast.ImportFrom)})))' "$HELPER")"
[ "$MODS" = "json re sys" ] && ok "standard library only ($MODS)" || bad "imports: $MODS"
exit $FAIL
