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

# small: is a one-off on the train a small fix (references/release-train.md)?
SMALL="$(python3 - "$HELPER" <<'PY2'
import json, subprocess, sys
helper = sys.argv[1]
base = {"releaseTrain": {"branch": "train/x", "smallFixes": {"maxFiles": 5, "maxChangedLines": 500}},
        "release": {"productionReview": {"highRiskPaths": ["src/auth/**"]}, "releaseBranchFixExclusions": ["migrations/**"]}}
def run(config, numstat):
    p = subprocess.run([sys.executable, helper, "small"], input=json.dumps({"config": config, "numstat": numstat}), capture_output=True, text=True)
    return p.returncode, (json.loads(p.stdout) if p.returncode == 0 else p.stderr)
def rows(*r): return "".join("%s\t%s\t%s\0" % x for x in r)
cases = [
  ("two files, 120 lines -> small", base, rows((100, 10, "a.ts"), (5, 5, "b.ts")), True, 2, 120),
  ("exactly 5 files and 500 lines -> small", base, rows(*[(100, 0, "f%d.ts" % i) for i in range(5)]), True, 5, 500),
  ("6 files -> not small", base, rows(*[(1, 0, "f%d.ts" % i) for i in range(6)]), False, 6, 6),
  ("501 lines -> not small", base, rows((501, 0, "a.ts")), False, 1, 501),
  ("a high-risk path -> not small", base, rows((1, 0, "src/auth/login.ts")), False, 1, 1),
  ("a high-risk path with a non-ASCII name and a space -> not small", base, rows((1, 0, "src/auth/café login.ts")), False, 1, 1),
  ("a fix exclusion -> not small", base, rows((1, 0, "migrations/0001.sql")), False, 1, 1),
  ("a binary file -> not small", base, rows(("-", "-", "logo.png")), False, 1, 0),
  ("empty diff -> not small", base, "", False, 0, 0),
  ("smallFixes unset -> not small", {"releaseTrain": {"branch": "train/x"}}, rows((1, 0, "a.ts")), False, 0, 0),
  ("the old supportTrain name is read too", {"supportTrain": base["releaseTrain"]}, rows((1, 0, "a.ts")), True, 1, 1),
]
for label, config, numstat, small, files, lines in cases:
    rc, out = run(config, numstat)
    good = rc == 0 and out["small"] is small and out["files"] == files and out["lines"] == lines and out["reason"]
    print(("ok   " if good else "FAIL ") + "small: " + label + ("" if good else " -> rc=%s %r" % (rc, out)))
for label, config, numstat in [
  ("maxFiles 0 is refused", {"releaseTrain": {"smallFixes": {"maxFiles": 0, "maxChangedLines": 5}}}, "1\t0\ta\0"),
  ("a malformed numstat line is refused", base, "nonsense\0"),
  ("numstat cut at its first NUL is refused", base, "1\t0\ta.ts\x001\t0\tsrc/auth/x.ts"),
  ("numstat with its NULs dropped is refused", base, "1\t0\ta.ts1\t0\tsrc/auth/x.ts"),
  ("both train names together are refused", {"releaseTrain": {"branch": "a"}, "supportTrain": {"branch": "b"}}, ""),
]:
    rc, out = run(config, numstat)
    good = rc == 2 and isinstance(out, str) and out.startswith("routing: ") and "Traceback" not in out
    print(("ok   " if good else "FAIL ") + "small: " + label + ("" if good else " -> rc=%s %r" % (rc, out)))
PY2
)"
printf '%s\n' "$SMALL" | sed 's/^/  /'
printf '%s\n' "$SMALL" | grep -q '^FAIL' && FAIL=1
[ "$(printf '%s\n' "$SMALL" | grep -c '^ok')" = 16 ] || { echo "  FAIL small: expected 16 cases"; FAIL=1; }

# dependency-free: standard library only
MODS="$(python3 -c 'import ast,sys; t=ast.parse(open(sys.argv[1]).read()); print(" ".join(sorted({a.name for n in ast.walk(t) if isinstance(n, ast.Import) for a in n.names} | {n.module for n in ast.walk(t) if isinstance(n, ast.ImportFrom)})))' "$HELPER")"
[ "$MODS" = "json re sys" ] && ok "standard library only ($MODS)" || bad "imports: $MODS"
exit $FAIL
