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

for bad_input in 'not json' '{"children":[]}' '{"title":"Deferred","children":"x"}' '{"title":"Deferred","legacyTitles":"x","children":[]}' '{"title":"Deferred","legacyTitles":[5],"children":[]}' '{"title":"Deferred","children":[{"number":5,"title":"Deferred"}]}'; do
  out="$(run match "$bad_input")"; rc=$?
  if [ "$rc" = 2 ] && printf '%s' "$out" | python3 -c 'import json,sys; assert "error" in json.load(sys.stdin)' 2>/dev/null; then ok "malformed match input exits 2 with a JSON error ($bad_input)"; else bad "malformed $bad_input -> rc=$rc $out"; fi
done
out="$(printf '{}' | python3 "$SC" bogus)"; [ $? = 2 ] && ok "unknown subcommand exits 2" || bad "unknown subcommand -> $out"

NODES='[{"number":"I1","parentNumber":"I0"},{"number":"I2","parentNumber":"I1"},{"number":"I3","parentNumber":"I2"},{"number":"I4","parentNumber":"I0"},{"number":"I5","parentNumber":"I4"},{"number":"I6","parentNumber":"I0"},{"number":"I7","parentNumber":"I6"}]'
expect "members: nested descendants included, sibling tree excluded" members "{\"containers\":[\"I1\"],\"nodes\":$NODES}" 'd["members"]' '["I1", "I2", "I3"]'
expect "members: two containers are both honoured" members "{\"containers\":[\"I1\",\"I6\"],\"nodes\":$NODES}" 'd["members"]' '["I1", "I2", "I3", "I6", "I7"]'
expect "members: a parent cycle terminates" members '{"containers":["I1"],"nodes":[{"number":"I8","parentNumber":"I9"},{"number":"I9","parentNumber":"I8"},{"number":"I2","parentNumber":"I1"}]}' 'd["members"]' '["I1", "I2"]'
out="$(run members '{"containers":"I1","nodes":[]}')"; [ $? = 2 ] && ok "malformed members input exits 2" || bad "malformed members -> $out"

[ "$FAIL" -eq 0 ]
