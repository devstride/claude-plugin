#!/bin/bash
# Tests for skills/ultracode-build/scripts/group-findings.py — fixtures under fixtures/findings/, no files written.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; SC="$ROOT/skills/ultracode-build/scripts/group-findings.py"; FX="$ROOT/scripts/tests/fixtures/findings"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
run() { python3 "$SC"; }
field() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }
# mutate FIXTURE PYTHON — load the fixture as `d`, exec the snippet against it, print the result
mutate() { python3 -c "
import json,sys; d=json.load(open(sys.argv[1])); code=sys.argv[2]; exec(code); print(json.dumps(d))" "$@"; }
gen() { python3 -c "import json; print(json.dumps($1))"; }   # a small input from a python expression
# every id in exactly one place: one group, or perFinding — never both, never neither
partition_ok() { python3 -c "
import json,sys; d=json.load(sys.stdin); ids=[f['id'] for f in json.load(open(sys.argv[1]))['findings']]
ing=[i for g in d['groups'] for i in g['findings']]; print(sorted(ing+d['perFinding'])==sorted(ids) and not set(ing)&set(d['perFinding']))" "$1"; }
err() { run 2>&1 >/dev/null; }   # stderr only, exit code preserved via $?

# (1) 12 findings / 6 files / 0 auth → exactly 3 verifiers (before: 12); every id in exactly one group; caps hold
J="$(run < "$FX/twelve-six-files.json")"
if [ "$(printf '%s' "$J" | field 'd["verifiers"]')" = 3 ] && [ "$(printf '%s' "$J" | partition_ok "$FX/twelve-six-files.json")" = True ] && [ "$(printf '%s' "$J" | field 'all(len(g["findings"])<=5 and len(g["files"])<=3 for g in d["groups"])')" = True ] && [ "$(printf '%s' "$J" | field 'd["groups"][0]["findings"]')" = "['F1', 'F2', 'F3', 'F4']" ]; then ok "(1) twelve-six-files: verifiers 3 (before 12), every id in exactly one group, G1 = F1–F4 in id order"; else bad "(1) $J"; fi

# (2) 12 findings with 2 security-lens findings → both per-finding, ABSENT from every group, verifiers = 2 groups + 2
J="$(run < "$FX/twelve-two-auth.json")"
if [ "$(printf '%s' "$J" | field 'd["perFinding"]')" = "['F6', 'F11']" ] && [ "$(printf '%s' "$J" | field 'd["counts"]["groups"]')" = 2 ] && [ "$(printf '%s' "$J" | field 'd["verifiers"]')" = 4 ] && [ "$(printf '%s' "$J" | partition_ok "$FX/twelve-two-auth.json")" = True ]; then ok "(2) twelve-two-auth: F6 + F11 per-finding and in no group, verifiers = 2 + 2"; else bad "(2) $J"; fi

# (3) a correctness finding whose FILE is in authBoundaryFiles → per-finding (the file rule); `./` and a `:line` anchor still match; a `dir/` entry is a prefix
J="$(mutate "$FX/twelve-six-files.json" 'd["authBoundaryFiles"]=["./src/orders/cart.ts"]; d["findings"][2]["file"]="src/orders/cart.ts:12"' | run)"
J2="$(mutate "$FX/twelve-six-files.json" 'd["authBoundaryFiles"]=["src/pricing/"]' | run)"
if [ "$(printf '%s' "$J" | field 'd["perFinding"]')" = "['F3', 'F4']" ] && [ "$(printf '%s' "$J2" | field 'd["perFinding"]')" = "['F5', 'F6', 'F7', 'F8']" ]; then ok "(3) auth-boundary FILE → per-finding whatever the lens; paths normalised; directory prefix honoured"; else bad "(3) $J | $J2"; fi

# (3b) a security finding whose file is ALSO listed → listed once, verifiers counted once
J="$(mutate "$FX/twelve-two-auth.json" 'd["authBoundaryFiles"]=["src/pricing/discount.ts"]' | run)"
if [ "$(printf '%s' "$J" | field 'd["perFinding"]')" = "['F5', 'F6', 'F11']" ] && [ "$(printf '%s' "$J" | field 'd["verifiers"]')" = "$(printf '%s' "$J" | field 'd["counts"]["groups"]+3')" ]; then ok "(3b) both auth rules on one finding → listed once"; else bad "(3b) $J"; fi

# (3c) the lens is normalised: "Security" / " SECURITY " / a list containing it → per-finding
J="$(mutate "$FX/twelve-six-files.json" 'd["findings"][0]["lens"]="Security"; d["findings"][1]["lens"]=" SECURITY "; d["findings"][2]["lens"]=["correctness","security"]' | run)"
if [ "$(printf '%s' "$J" | field 'd["perFinding"]')" = "['F1', 'F2', 'F3']" ]; then ok "(3c) lens normalised (case, space, list) → security still per-finding"; else bad "(3c) $J"; fi

# (4) 12 findings in one file → split IN ID ORDER into 5 / 5 / 2
J="$(gen '{"findings":[{"id":"F%d"%n,"file":"src/one.ts","line":n,"lens":"correctness","claim":"c"} for n in range(1,13)]}' | run)"
if [ "$(printf '%s' "$J" | field '[g["findings"] for g in d["groups"]]')" = "[['F1', 'F2', 'F3', 'F4', 'F5'], ['F6', 'F7', 'F8', 'F9', 'F10'], ['F11', 'F12']]" ]; then ok "(4) twelve findings in one file → F1–F5 / F6–F10 / F11–F12 (numeric id order, not F1,F10,F11…)"; else bad "(4) $J"; fi

# (5) 7 files with one finding each → 3 groups of ≤ 3 files
J="$(gen '{"findings":[{"id":"F%d"%n,"file":"src/m/f%d.ts"%n,"line":1,"lens":"correctness","claim":"c"} for n in range(1,8)]}' | run)"
if [ "$(printf '%s' "$J" | field 'd["verifiers"]')" = 3 ] && [ "$(printf '%s' "$J" | field 'all(len(g["files"])<=3 for g in d["groups"])')" = True ]; then ok "(5) seven single-finding files → 3 groups of ≤ 3 files"; else bad "(5) $J"; fi

# (5b) the caps are read from the input: maxFindings 2 / maxFiles 1 on fixture 1 → 6 groups of ≤ 2, one file each
J="$(mutate "$FX/twelve-six-files.json" 'd["maxFindings"]=2; d["maxFiles"]=1' | run)"
if [ "$(printf '%s' "$J" | field 'd["verifiers"]')" = 6 ] && [ "$(printf '%s' "$J" | field 'all(len(g["findings"])<=2 and len(g["files"])==1 for g in d["groups"])')" = True ]; then ok "(5b) maxFindings 2 / maxFiles 1 honoured → 6 single-file groups"; else bad "(5b) $J"; fi

# (5c) packing is largest-first: four same-directory files with 3,2,2,3 findings → 2 groups, not 3
J="$(gen '{"findings":[{"id":"F%d"%n,"file":"src/d/%s.ts"%f,"line":n,"lens":"correctness","claim":"c"} for n,f in enumerate(["a"]*3+["b"]*2+["c"]*2+["d"]*3,1)]}' | run)"
if [ "$(printf '%s' "$J" | field 'd["verifiers"]')" = 2 ]; then ok "(5c) 3,2,2,3 findings over four files → 2 groups (largest-first)"; else bad "(5c) $J"; fi

# (6) grouping: per-finding → verifiers = N, auth findings still per-finding
J="$(mutate "$FX/twelve-two-auth.json" 'd["grouping"]="per-finding"' | run)"
if [ "$(printf '%s' "$J" | field 'd["verifiers"]')" = 12 ] && [ "$(printf '%s' "$J" | field 'd["perFinding"]')" = "['F6', 'F11']" ] && [ "$(printf '%s' "$J" | field 'all(len(g["findings"])==1 for g in d["groups"])')" = True ]; then ok "(6) per-finding → verifiers = 12"; else bad "(6) $J"; fi

# (7) determinism: shuffled input yields byte-identical output — on the fixture where the id sort matters (perFinding, split buckets)
A="$(run < "$FX/twelve-two-auth.json")"
B="$(mutate "$FX/twelve-two-auth.json" 'import random; random.seed(7); random.shuffle(d["findings"]); d["findings"]=d["findings"][::-1]' | run)"
C="$(gen '{"findings":[{"id":"F%d"%n,"file":"src/one.ts","line":n,"lens":"correctness","claim":"c"} for n in [12,3,7,1,9,11,2,10,5,4,8,6]]}' | run)"
if [ "$A" = "$B" ] && [ "$(printf '%s' "$C" | field '[g["findings"] for g in d["groups"]]')" = "[['F1', 'F2', 'F3', 'F4', 'F5'], ['F6', 'F7', 'F8', 'F9', 'F10'], ['F11', 'F12']]" ]; then ok "(7) shuffled input → byte-identical output; split follows numeric id order regardless of input order"; else bad "(7) differs"; fi

# (8) malformed input → exit 1 naming the problem, never a traceback, never a degraded grouping
chk() { local label="$1" expect="$2"; shift 2; local E; E="$("$@" | err)"; local RC=$?; if [ "$RC" -eq 1 ] && printf '%s' "$E" | grep -q "$expect" && ! printf '%s' "$E" | grep -q Traceback; then ok "(8) $label → exit 1: $(printf '%s' "$E" | head -1 | cut -c1-70)"; else bad "(8) $label rc=$RC $E"; fi; }
chk "missing id"            "index 4"                        mutate "$FX/twelve-six-files.json" 'del d["findings"][4]["id"]'
chk "duplicate id"          "duplicate id F2"                mutate "$FX/twelve-six-files.json" 'd["findings"][3]["id"]="F2"'
chk "empty file"            "F3 has no file"                 mutate "$FX/twelve-six-files.json" 'd["findings"][2]["file"]=" "'
chk "missing lens"          "F1 has no lens"                 mutate "$FX/twelve-six-files.json" 'del d["findings"][0]["lens"]'
chk "misspelt lens"         "F1 has lens 'secuirty'"         mutate "$FX/twelve-six-files.json" 'd["findings"][0]["lens"]="secuirty"'
chk "bad grouping"          "must be per-file or per-finding" mutate "$FX/twelve-six-files.json" 'd["grouping"]="per-lens"'
chk "maxFindings 0"         "maxFindings must be >= 1"       mutate "$FX/twelve-six-files.json" 'd["maxFindings"]=0'
chk "maxFiles \"3\""        "maxFiles must be an integer"    mutate "$FX/twelve-six-files.json" 'd["maxFiles"]="3"'
chk "authBoundaryFiles str" "authBoundaryFiles"              mutate "$FX/twelve-six-files.json" 'd["authBoundaryFiles"]="src/orders/cart.ts"'
chk "top-level list"        "must be a JSON object"          gen '[]'
chk "not JSON"              "not JSON"                       printf '{'
exit $FAIL
