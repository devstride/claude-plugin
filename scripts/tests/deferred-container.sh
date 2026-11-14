#!/bin/bash
# Tests for skills/build-item/scripts/deferred-container.py — the deferred container's identity
# (match) and membership (members) rules. No git, no network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; SC="$ROOT/skills/build-item/scripts/deferred-container.py"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
run() { printf '%s' "$2" | python3 "$SC" "$1"; }
field() { python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(eval(sys.argv[1])))" "$1"; }
expect() { # label command request python-expression expected-json
  local out; out="$(run "$2" "$3")"; local got; got="$(printf '%s' "$out" | field "$4")"
  if [ "$got" = "$5" ]; then ok "$1"; else bad "$1 -> $out (wanted $4 = $5)"; fi
}

expect "current title matches" match '{"title":"Deferred","children":[{"number":"I20","title":"Deferred"},{"number":"I21","title":"Epic A"}]}' '[d["container"],d["matchedBy"],d["create"]]' '["I20", "title", false]'
expect "built-in legacy title matches under the default config" match '{"title":"Deferred","children":[{"number":"I30","title":"Deferred defects"}]}' '[d["container"],d["matchedBy"]]' '["I30", "legacy"]'
expect "case and whitespace variant matches" match '{"title":"Deferred","children":[{"number":"I31","title":"  deferred   DEFECTS "}]}' 'd["container"]' '"I31"'
expect "configured extra legacy title matches" match '{"title":"Deferred","legacyTitles":["Deferred Items"],"children":[{"number":"I32","title":"Deferred Items"}]}' 'd["container"]' '"I32"'
expect "a configured title matches, a leftover Deferred does not" match '{"title":"Parked work","children":[{"number":"I33","title":"Parked work"},{"number":"I34","title":"Deferred"}]}' '[d["container"],d["all"]]' '["I33", ["I33"]]'
expect "a title that only contains the word is not a match" match '{"title":"Deferred","children":[{"number":"I35","title":"Phase 2 - Deferred Cleanups & Tech-Debt Retirement"},{"number":"I36","title":"Deferred and later"}]}' '[d["container"],d["create"]]' '[null, true]'
expect "two matches: the lower number wins, numerically (I9 before I10)" match '{"title":"Deferred","children":[{"number":"I10","title":"Deferred"},{"number":"I9","title":"Deferred defects"}]}' '[d["container"],d["duplicates"],d["all"],d["matchedBy"]]' '["I9", ["I10"], ["I9", "I10"], "legacy"]'
expect "no match: create" match '{"title":"Deferred","children":[]}' '[d["container"],d["all"],d["duplicates"],d["matchedBy"],d["create"]]' '[null, [], [], null, true]'
expect "an empty legacy entry is skipped, never a refusal" match '{"title":"Deferred","legacyTitles":["Deferred defects",""],"children":[{"number":"I38","title":"Deferred"}]}' 'd["container"]' '"I38"'
expect "a configured list never removes the built-in legacy title" match '{"title":"Deferred","legacyTitles":["Something else"],"children":[{"number":"I37","title":"Deferred defects"}]}' 'd["container"]' '"I37"'

expect "settle: an open epic whose stories are all Done closes, then the plan" settle '{"root":{"number":"I1","done":false},"containers":[],"nodes":[{"number":"I2","parentNumber":"I1","leaf":false,"done":false},{"number":"I3","parentNumber":"I2","leaf":true,"done":true}]}' '[d["close"],d["root"],d["openValue"]]' '[["I2"], "close", []]'
expect "settle: an epic with an open story stays open and so does the plan" settle '{"root":{"number":"I1","done":false},"containers":[],"nodes":[{"number":"I2","parentNumber":"I1","leaf":false,"done":false},{"number":"I3","parentNumber":"I2","leaf":true,"done":false}]}' '[d["close"],d["root"],d["openValue"]]' '[[], "keep-open", ["I3"]]'
expect "settle: an empty open epic outside the container holds the plan open" settle '{"root":{"number":"I1","done":false},"containers":[],"nodes":[{"number":"I2","parentNumber":"I1","leaf":false,"done":false}]}' '[d["close"],d["root"],d["openValue"]]' '[[], "keep-open", ["I2"]]'
expect "settle: a duplicate container's finished contents close it and do not hold the plan open" settle '{"root":{"number":"I1","done":false},"containers":["I9","I20"],"nodes":[{"number":"I2","parentNumber":"I1","leaf":true,"done":true},{"number":"I9","parentNumber":"I1","leaf":false,"done":true},{"number":"I20","parentNumber":"I1","leaf":false,"done":false},{"number":"I21","parentNumber":"I20","leaf":true,"done":true}]}' '[d["close"],d["root"],d["openValue"]]' '[["I20"], "close", []]'
expect "settle: open work under a duplicate container is deferred work" settle '{"root":{"number":"I1","done":false},"containers":["I9","I20"],"nodes":[{"number":"I9","parentNumber":"I1","leaf":false,"done":true},{"number":"I20","parentNumber":"I1","leaf":false,"done":false},{"number":"I21","parentNumber":"I20","leaf":true,"done":false}]}' '[d["openDeferred"],d["openValue"],d["root"]]' '[["I21"], [], "keep-open"]'
for bad_input in 'not json' '{"children":[]}' '{"title":"Deferred","children":"x"}' '{"title":"Deferred","legacyTitles":"x","children":[]}' '{"title":"Deferred","legacyTitles":[5],"children":[]}' '{"title":"Deferred","children":[{"number":5,"title":"Deferred"}]}' '{"title":"Deferred","children":[{"number":"I5"}]}'; do
  out="$(run match "$bad_input")"; rc=$?
  if [ "$rc" = 2 ] && printf '%s' "$out" | python3 -c 'import json,sys; assert "error" in json.load(sys.stdin)' 2>/dev/null; then ok "malformed match input exits 2 with a JSON error ($bad_input)"; else bad "malformed $bad_input -> rc=$rc $out"; fi
done
out="$(printf '{}' | python3 "$SC" bogus)"; [ $? = 2 ] && ok "unknown subcommand exits 2" || bad "unknown subcommand -> $out"

NODES='[{"number":"I1","parentNumber":"I0"},{"number":"I2","parentNumber":"I1"},{"number":"I3","parentNumber":"I2"},{"number":"I4","parentNumber":"I0"},{"number":"I5","parentNumber":"I4"},{"number":"I6","parentNumber":"I0"},{"number":"I7","parentNumber":"I6"}]'
expect "members: nested descendants included, sibling tree excluded" members "{\"containers\":[\"I1\"],\"nodes\":$NODES}" 'd["members"]' '["I1", "I2", "I3"]'
expect "members: two containers are both honoured" members "{\"containers\":[\"I1\",\"I6\"],\"nodes\":$NODES}" 'd["members"]' '["I1", "I2", "I3", "I6", "I7"]'
expect "members: a parent cycle terminates" members '{"containers":["I1"],"nodes":[{"number":"I8","parentNumber":"I9"},{"number":"I9","parentNumber":"I8"},{"number":"I2","parentNumber":"I1"}]}' 'd["members"]' '["I1", "I2"]'
out="$(run members '{"containers":"I1","nodes":[]}')"; [ $? = 2 ] && ok "malformed members input exits 2" || bad "malformed members -> $out"
out="$(run members '{"containers":["I1"],"nodes":[{"number":"I2"}]}')"; [ $? = 2 ] && ok "a node without parentNumber exits 2" || bad "missing parentNumber -> $out"

# settle: what closes (deferred-container.md "Closing"). I1 root; I2 epic, I3/I4 its stories; I9 the container, I10 a story, I11 a defect.
N() { printf '{"number":"%s","parentNumber":"%s","leaf":%s,"done":%s}' "$1" "$2" "$3" "$4"; }
TREE() { printf '[%s,%s,%s,%s,%s,%s]' "$(N I2 I1 false "$1")" "$(N I3 I2 true "$2")" "$(N I4 I2 true "$3")" "$(N I9 I1 false "$4")" "$(N I10 I9 true "$5")" "$(N I11 I9 true "$6")"; }
SET() { printf '{"root":{"number":"I1","done":%s},"containers":["I9"],"nodes":%s}' "$1" "$2"; }
expect "settle: everything finished closes the container, then the plan" settle "$(SET false "$(TREE true true true false true true)")" '[d["close"],d["root"],d["openDeferred"],d["openValue"]]' '[["I9"], "close", [], []]'
expect "settle: unbuilt deferred work keeps the container and the plan open (owner decision)" settle "$(SET false "$(TREE true true true false false true)")" '[d["close"],d["root"],d["openDeferred"]]' '[[], "keep-open", ["I10"]]'
expect "settle: deferred work finished but the plan's own work open closes only the container" settle "$(SET false "$(TREE false true false false true true)")" '[d["close"],d["root"],d["openValue"]]' '[["I9"], "keep-open", ["I4"]]'
expect "settle: an open epic whose stories are all Done closes with the plan (no release closes it)" settle "$(SET false "$(TREE false true true true true true)")" '[d["close"],d["root"],d["openValue"]]' '[["I2"], "close", []]'
expect "settle: a new filing under a closed container reopens it and the plan" settle "$(SET true "$(TREE true true true true false true)")" '[d["reopen"],d["close"],d["root"]]' '[["I9"], [], "reopen"]'
expect "settle: a finished, closed plan stays done" settle "$(SET true "$(TREE true true true true true true)")" '[d["close"],d["reopen"],d["root"]]' '[[], [], "done"]'
expect "settle: an empty open container closes" settle "$(SET false "[$(N I2 I1 false true),$(N I9 I1 false false)]")" '[d["close"],d["root"]]' '[["I9"], "close"]'
expect "settle: no container, plan finished" settle '{"root":{"number":"I1","done":false},"containers":[],"nodes":[{"number":"I3","parentNumber":"I1","leaf":true,"done":true}]}' '[d["close"],d["root"]]' '[[], "close"]'
NEST="[$(N I9 I1 false false),$(N I12 I9 false false),$(N I13 I12 true true),$(N I14 I9 true true)]"
expect "settle: a nested node inside the container closes before the container" settle "$(SET false "$NEST")" 'd["close"]' '["I12", "I9"]'
for bad_input in '{"containers":[],"nodes":[]}' '{"root":{"number":"I1","done":"no"},"containers":[],"nodes":[]}' '{"root":{"number":"I1","done":false},"containers":["I9"],"nodes":[]}' '{"root":{"number":"I1","done":false},"containers":"I9","nodes":[]}' '{"root":{"number":"I1","done":false},"containers":[],"nodes":[{"number":"I2","parentNumber":"I1","leaf":true}]}' '{"root":{"number":"I1","done":false},"containers":[],"nodes":[{"number":"I1","parentNumber":null,"leaf":false,"done":false}]}'; do
  out="$(run settle "$bad_input")"; rc=$?
  if [ "$rc" = 2 ]; then ok "malformed settle input exits 2 ($bad_input)"; else bad "malformed settle $bad_input -> rc=$rc $out"; fi
done

[ "$FAIL" -eq 0 ]
