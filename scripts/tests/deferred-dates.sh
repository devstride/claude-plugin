#!/bin/bash
# Tests for skills/rationalize-gantt/scripts/deferred-dates.py — dating a plan's deferred items
# after its last value leaf. No git, no network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; SC="$ROOT/skills/rationalize-gantt/scripts/deferred-dates.py"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
run() { printf '%s' "$1" | python3 "$SC"; }
field() { python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(eval(sys.argv[1])))" "$1"; }
expect() { # label request python-expression expected-json
  local out; out="$(run "$2")"; local got; got="$(printf '%s' "$out" | field "$3")"
  if [ "$got" = "$4" ]; then ok "$1"; else bad "$1 -> $out (wanted $3 = $4)"; fi
}
DATES='[(a["number"],a["startDate"],a["dueDate"],a["reason"]) for a in d["assignments"]]'
LEAVES='[{"number":"I1","dueDate":"2026-10-30"},{"number":"I2","dueDate":"2026-11-01"}]'

expect "three open items after boundary 2026-11-01, in item-number order" \
  "{\"today\":\"2026-10-01\",\"valueLeaves\":$LEAVES,\"deferred\":[{\"number\":\"I12\"},{\"number\":\"I9\"},{\"number\":\"I10\"}]}" \
  "[d['boundary'],$DATES]" \
  '["2026-11-01", [["I9", "2026-11-02", "2026-11-02", "scheduled"], ["I10", "2026-11-03", "2026-11-03", "scheduled"], ["I12", "2026-11-04", "2026-11-04", "scheduled"]]]'
expect "an item already starting after the boundary is kept and uses up no day" \
  "{\"today\":\"2026-10-01\",\"valueLeaves\":$LEAVES,\"deferred\":[{\"number\":\"I9\",\"startDate\":\"2026-12-15\",\"dueDate\":\"2026-12-16\"},{\"number\":\"I10\"}]}" \
  "$DATES" '[["I9", "2026-12-15", "2026-12-16", "kept"], ["I10", "2026-11-02", "2026-11-02", "scheduled"]]'
expect "an item dated before the boundary (a creation placeholder) is rescheduled" \
  "{\"today\":\"2026-10-01\",\"valueLeaves\":$LEAVES,\"deferred\":[{\"number\":\"I9\",\"startDate\":\"2026-10-31\",\"dueDate\":\"2026-10-31\"}]}" \
  "$DATES" '[["I9", "2026-11-02", "2026-11-02", "scheduled"]]'
expect "a Done item is untouched and listed" \
  "{\"today\":\"2026-10-01\",\"valueLeaves\":$LEAVES,\"deferred\":[{\"number\":\"I9\",\"done\":true,\"startDate\":\"2026-08-01\",\"dueDate\":\"2026-08-01\"},{\"number\":\"I10\"}]}" \
  "[d['untouchedDone'],$DATES]" '[["I9"], [["I10", "2026-11-02", "2026-11-02", "scheduled"]]]'
expect "no value leaves: the block starts the day after today, never today" \
  '{"today":"2026-11-04","valueLeaves":[],"deferred":[{"number":"I9"}]}' \
  "[d['boundary'],$DATES]" '["2026-11-04", [["I9", "2026-11-05", "2026-11-05", "scheduled"]]]'
expect "value leaves that all ended in the past: deferred items still start the day after today" \
  '{"today":"2026-11-14","valueLeaves":[{"number":"I1","dueDate":"2026-10-30"},{"number":"I2","dueDate":"2026-11-01"}],"deferred":[{"number":"I9"},{"number":"I10"}]}' \
  "[d['boundary'],$DATES]" '["2026-11-14", [["I9", "2026-11-15", "2026-11-15", "scheduled"], ["I10", "2026-11-16", "2026-11-16", "scheduled"]]]'
expect "a plan start date: deferred items never begin before it" \
  '{"today":"2026-11-14","start":"2026-12-01","valueLeaves":[{"number":"I1","dueDate":"2026-10-30"}],"deferred":[{"number":"I9"}]}' \
  "[d['boundary'],$DATES]" '["2026-11-30", [["I9", "2026-12-01", "2026-12-01", "scheduled"]]]'
expect "a plan that ends after its start date: deferred items follow its last leaf" \
  '{"today":"2026-11-14","start":"2026-12-01","valueLeaves":[{"number":"I1","dueDate":"2026-12-06"}],"deferred":[{"number":"I9"}]}' \
  "[d['boundary'],$DATES]" '["2026-12-06", [["I9", "2026-12-07", "2026-12-07", "scheduled"]]]'
expect "a future start with no due date is scheduled, not kept" \
  "{\"today\":\"2026-10-01\",\"valueLeaves\":$LEAVES,\"deferred\":[{\"number\":\"I9\",\"startDate\":\"2026-12-15\"}]}" \
  "$DATES" '[["I9", "2026-11-02", "2026-11-02", "scheduled"]]'
expect "an inverted range (due before start) is scheduled, not kept" \
  "{\"today\":\"2026-10-01\",\"valueLeaves\":$LEAVES,\"deferred\":[{\"number\":\"I9\",\"startDate\":\"2026-12-15\",\"dueDate\":\"2026-12-01\"}]}" \
  "$DATES" '[["I9", "2026-11-02", "2026-11-02", "scheduled"]]'
expect "group spans cover only each group's own items" \
  "{\"today\":\"2026-10-01\",\"valueLeaves\":$LEAVES,\"deferred\":[{\"number\":\"I9\",\"groups\":[\"I5\"]},{\"number\":\"I10\",\"groups\":[\"I6\",\"I7\"]}]}" \
  "d['groupSpans']" '{"I5": {"startDate": "2026-11-02", "dueDate": "2026-11-02"}, "I6": {"startDate": "2026-11-03", "dueDate": "2026-11-03"}, "I7": {"startDate": "2026-11-03", "dueDate": "2026-11-03"}}'
expect "the container span is the min and max of the assignments" \
  "{\"today\":\"2026-10-01\",\"valueLeaves\":$LEAVES,\"deferred\":[{\"number\":\"I9\",\"startDate\":\"2026-12-15\",\"dueDate\":\"2026-12-16\"},{\"number\":\"I10\"}]}" \
  "d['containerSpan']" '{"startDate": "2026-11-02", "dueDate": "2026-12-16"}'
expect "nothing open: no span" \
  "{\"today\":\"2026-10-01\",\"valueLeaves\":$LEAVES,\"deferred\":[{\"number\":\"I9\",\"done\":true}]}" \
  "[d['assignments'],d['containerSpan']]" '[[], null]'

FIRST="$(run "{\"today\":\"2026-10-01\",\"valueLeaves\":$LEAVES,\"deferred\":[{\"number\":\"I9\"},{\"number\":\"I10\"}]}")"
SECOND_IN="$(printf '%s' "$FIRST" | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps({'today':'2026-10-01','valueLeaves':$LEAVES,'deferred':[{'number':a['number'],'startDate':a['startDate'],'dueDate':a['dueDate']} for a in d['assignments']]}))")"
SAME="$(python3 -c "import json,sys; a=json.loads(sys.argv[1])['assignments']; b=json.loads(sys.argv[2])['assignments']; print([(x['number'],x['startDate'],x['dueDate']) for x in a]==[(x['number'],x['startDate'],x['dueDate']) for x in b] and all(x['reason']=='kept' for x in b))" "$FIRST" "$(run "$SECOND_IN")")"
[ "$SAME" = True ] && ok "re-running on its own output changes no date (every entry kept)" || bad "re-run changed dates: $FIRST"

expect "a later boundary reschedules items the previous run placed" \
  '{"today":"2026-10-01","valueLeaves":[{"number":"I1","dueDate":"2026-11-05"}],"deferred":[{"number":"I9","startDate":"2026-11-02","dueDate":"2026-11-02"},{"number":"I10","startDate":"2026-11-03","dueDate":"2026-11-03"}]}' \
  "$DATES" '[["I9", "2026-11-06", "2026-11-06", "scheduled"], ["I10", "2026-11-07", "2026-11-07", "scheduled"]]'

expect "itemDays 3: each scheduled item spans three days and the next starts the day after" \
  "{\"today\":\"2026-10-01\",\"itemDays\":3,\"valueLeaves\":$LEAVES,\"deferred\":[{\"number\":\"I9\"},{\"number\":\"I10\"}]}" \
  "[$DATES,d['containerSpan']]" \
  '[[["I9", "2026-11-02", "2026-11-04", "scheduled"], ["I10", "2026-11-05", "2026-11-07", "scheduled"]], {"startDate": "2026-11-02", "dueDate": "2026-11-07"}]'
expect "itemDays: a kept item keeps its own length and uses up no slot" \
  "{\"today\":\"2026-10-01\",\"itemDays\":2,\"valueLeaves\":$LEAVES,\"deferred\":[{\"number\":\"I9\",\"startDate\":\"2026-12-15\",\"dueDate\":\"2026-12-15\"},{\"number\":\"I10\"}]}" \
  "$DATES" '[["I9", "2026-12-15", "2026-12-15", "kept"], ["I10", "2026-11-02", "2026-11-03", "scheduled"]]'

for bad_input in 'not json' '{"valueLeaves":[],"deferred":[]}' '{"today":"2026-13-40","deferred":[]}' '{"today":"2026-11-04","deferred":"x"}' '{"today":"2026-11-04","deferred":[{"startDate":"2026-11-01"}]}' '{"today":"2026-11-04","deferred":[{"number":5}]}' '{"today":"2026-11-04","deferred":[{"number":"I1","groups":"I0"}]}' '{"today":"2026-11-04","deferred":[{"number":"I1","groups":[[]]}]}' '{"today":"2026-11-04","start":"soon","deferred":[]}' '{"today":"2026-11-04","itemDays":4000000,"deferred":[{"number":"I1"},{"number":"I2"}]}' '{"today":"2026-11-04","itemDays":0,"deferred":[]}' '{"today":"2026-11-04","itemDays":"2","deferred":[]}' '{"today":"2026-11-04","itemDays":true,"deferred":[]}'; do
  out="$(run "$bad_input")"; rc=$?
  if [ "$rc" = 2 ] && printf '%s' "$out" | python3 -c 'import json,sys; assert "error" in json.load(sys.stdin)' 2>/dev/null; then ok "malformed input exits 2 with a JSON error ($bad_input)"; else bad "malformed $bad_input -> rc=$rc $out"; fi
done

[ "$FAIL" -eq 0 ]
