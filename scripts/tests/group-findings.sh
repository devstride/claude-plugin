#!/bin/bash
# Tests for skills/ultracode-build/scripts/group-findings.py — fixtures under fixtures/findings/, no network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; SC="$ROOT/skills/ultracode-build/scripts/group-findings.py"; FX="$ROOT/scripts/tests/fixtures/findings"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
run() { python3 "$SC"; }
field() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }
# a fixture's findings with the given ids' lens/file overridden, or its top-level keys changed
mutate() { python3 -c "
import json,sys; d=json.load(open(sys.argv[1])); code=sys.argv[2]; exec(code); print(json.dumps(d))" "$@"; }

# (1) 12 findings / 6 files / 0 auth → verifiers ≤ 6 (before: 12); every id in exactly one group
J="$(run < "$FX/twelve-six-files.json")"
V="$(printf '%s' "$J" | field 'd["verifiers"]')"; COVER="$(printf '%s' "$J" | field 'sorted(i for g in d["groups"] for i in g["findings"])==sorted("F%d"%n for n in range(1,13)) and len(d["perFinding"])==0')"
OK5="$(printf '%s' "$J" | field 'all(len(g["findings"])<=5 and len(g["files"])<=3 for g in d["groups"])')"
if [ "$V" -le 6 ] && [ "$COVER" = True ] && [ "$OK5" = True ]; then ok "(1) twelve-six-files: verifiers $V (≤ 6; before 12), every id in exactly one group"; else bad "(1) $J"; fi

# (2) 12 findings with 2 security-lens findings → both in perFinding, verifiers = G + 2, G ≤ 5
J="$(run < "$FX/twelve-two-auth.json")"
PF="$(printf '%s' "$J" | field 'sorted(d["perFinding"])')"; G="$(printf '%s' "$J" | field 'd["counts"]["fileGroups"]')"; V="$(printf '%s' "$J" | field 'd["verifiers"]')"
if [ "$PF" = "['F11', 'F6']" ] && [ "$V" -eq $((G + 2)) ] && [ "$G" -le 5 ]; then ok "(2) twelve-two-auth: F6 + F11 per-finding, verifiers = $G + 2"; else bad "(2) $J"; fi

# (3) a correctness finding whose FILE is in authBoundaryFiles → perFinding (the file rule, not just the lens)
J="$(mutate "$FX/twelve-six-files.json" 'd["authBoundaryFiles"]=["src/orders/cart.ts"]' | run)"
if [ "$(printf '%s' "$J" | field 'sorted(d["perFinding"])')" = "['F3', 'F4']" ]; then ok "(3) auth-boundary FILE → its findings per-finding whatever the lens"; else bad "(3) $J"; fi

# (4) 9 findings in one file → split into two groups of ≤ 5
J="$(python3 -c 'import json; print(json.dumps({"findings":[{"id":"F%d"%n,"file":"src/one.ts","line":n,"lens":"correctness","claim":"c"} for n in range(1,10)]}))' | run)"
if [ "$(printf '%s' "$J" | field 'sorted(len(g["findings"]) for g in d["groups"])')" = "[4, 5]" ]; then ok "(4) nine findings in one file → groups of 5 and 4"; else bad "(4) $J"; fi

# (5) 7 files with one finding each → packed into ≤ 3 groups of ≤ 3 files
J="$(python3 -c 'import json; print(json.dumps({"findings":[{"id":"F%d"%n,"file":"src/m/f%d.ts"%n,"line":1,"lens":"correctness","claim":"c"} for n in range(1,8)]}))' | run)"
if [ "$(printf '%s' "$J" | field 'd["verifiers"]')" -le 3 ] && [ "$(printf '%s' "$J" | field 'all(len(g["files"])<=3 for g in d["groups"])')" = True ]; then ok "(5) seven single-finding files → $(printf '%s' "$J" | field 'd["verifiers"]') groups of ≤ 3 files"; else bad "(5) $J"; fi

# (6) grouping: per-finding → verifiers = N
J="$(mutate "$FX/twelve-two-auth.json" 'd["grouping"]="per-finding"' | run)"
if [ "$(printf '%s' "$J" | field 'd["verifiers"]')" = 12 ] && [ "$(printf '%s' "$J" | field 'len(d["perFinding"])')" = 2 ]; then ok "(6) per-finding → verifiers = 12 (auth findings still listed per-finding)"; else bad "(6) $J"; fi

# (7) determinism: shuffled input yields byte-identical output
A="$(run < "$FX/twelve-six-files.json")"
B="$(mutate "$FX/twelve-six-files.json" 'import random; random.seed(7); random.shuffle(d["findings"]); d["findings"]=d["findings"][::-1]' | run)"
if [ "$A" = "$B" ]; then ok "(7) shuffled input → byte-identical output"; else bad "(7) differs:\n$A\n$B"; fi

# (8) a finding without an id → non-zero exit naming it
ERR="$(mutate "$FX/twelve-six-files.json" 'del d["findings"][4]["id"]' | run 2>&1 >/dev/null)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$ERR" | grep -q "index 4" && printf '%s' "$ERR" | grep -q "src/pricing/discount.ts"; then ok "(8) missing id → exit $RC naming index 4 and its file"; else bad "(8) rc=$RC $ERR"; fi
exit $FAIL
