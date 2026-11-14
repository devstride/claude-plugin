#!/bin/bash
# Tests for skills/rationalize-gantt/scripts/cascade-dates.py — dating a plan's leaves as a gapless
# dependency cascade from a start date, with an assumed length per leaf. No git, no network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; SC="$ROOT/skills/rationalize-gantt/scripts/cascade-dates.py"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
run() { printf '%s' "$1" | python3 "$SC"; }
field() { python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(eval(sys.argv[1])))" "$1"; }
expect() { # label request python-expression expected-json [expected-exit]
  local out rc; out="$(run "$2")"; rc=$?; local got; got="$(printf '%s' "$out" | field "$3")"
  if [ "$got" = "$4" ] && [ "$rc" = "${5:-0}" ]; then ok "$1"; else bad "$1 -> rc=$rc $out (wanted $3 = $4)"; fi
}
DATES='[(a["number"],a["startDate"],a["dueDate"]) for a in d["assignments"]]'
# A chain I1 -> I2 -> I3, with I4 and I5 both waiting only on I2, and I6 the last deliverable.
PLAN='[{"number":"I1"},{"number":"I2","blockedBy":["I1"]},{"number":"I3","blockedBy":["I2"]},{"number":"I4","blockedBy":["I2"]},{"number":"I5","blockedBy":["I2"]},{"number":"I6","blockedBy":["I3","I4","I5"]}]'

expect "a start date: the deepest leaf starts on it and every blocker is due before what it blocks starts" \
  "{\"today\":\"2026-11-14\",\"start\":\"2026-12-01\",\"leaves\":$PLAN}" "[d['start'],d['end'],$DATES]" \
  '["2026-12-01", "2026-12-04", [["I1", "2026-12-01", "2026-12-01"], ["I2", "2026-12-02", "2026-12-02"], ["I3", "2026-12-03", "2026-12-03"], ["I4", "2026-12-03", "2026-12-03"], ["I5", "2026-12-03", "2026-12-03"], ["I6", "2026-12-04", "2026-12-04"]]]'
expect "no start date: the plan starts the day after today, never today or earlier" \
  "{\"today\":\"2026-11-14\",\"leaves\":$PLAN}" "[d['start'],d['requestedStart'],d['heldBy'],d['assignments'][0]['startDate']]" \
  '["2026-11-15", "2026-11-15", null, "2026-11-15"]'
expect "itemDays 5: each leaf spans five days and the next depth starts the day after" \
  "{\"today\":\"2026-11-14\",\"start\":\"2026-12-01\",\"itemDays\":5,\"leaves\":$PLAN}" "[d['itemDays'],d['end'],$DATES]" \
  '[5, "2026-12-20", [["I1", "2026-12-01", "2026-12-05"], ["I2", "2026-12-06", "2026-12-10"], ["I3", "2026-12-11", "2026-12-15"], ["I4", "2026-12-11", "2026-12-15"], ["I5", "2026-12-11", "2026-12-15"], ["I6", "2026-12-16", "2026-12-20"]]]'
expect "leaves sit as late as their dependents allow: a short branch lands beside the end of the long one" \
  '{"today":"2026-11-14","start":"2026-12-01","leaves":[{"number":"I1"},{"number":"I2","blockedBy":["I1"]},{"number":"I3","blockedBy":["I2"]},{"number":"I7"},{"number":"I9","blockedBy":["I3","I7"]}]}' \
  "[(a['number'],a['startDate'],a['depth']) for a in d['assignments']]" \
  '[["I1", "2026-12-01", 3], ["I2", "2026-12-02", 2], ["I3", "2026-12-03", 1], ["I7", "2026-12-03", 1], ["I9", "2026-12-04", 0]]'
expect "the distribution counts leaves per start day and has no empty slot" \
  "{\"today\":\"2026-11-14\",\"start\":\"2026-12-01\",\"leaves\":$PLAN}" "[(x['startDate'],x['count']) for x in d['distribution']]" \
  '[["2026-12-01", 1], ["2026-12-02", 1], ["2026-12-03", 3], ["2026-12-04", 1]]'
expect "an edge to something that is not a leaf dates nothing and is listed" \
  '{"today":"2026-11-14","start":"2026-12-01","leaves":[{"number":"I1","blockedBy":["I50","I1x"]},{"number":"I2","blockedBy":["I1"]}]}' \
  "[d['outsideEdges'],$DATES]" \
  '[[{"number": "I1", "blockedBy": "I50"}, {"number": "I1", "blockedBy": "I1x"}], [["I1", "2026-12-01", "2026-12-01"], ["I2", "2026-12-02", "2026-12-02"]]]'
expect "a repeated edge counts once" \
  '{"today":"2026-11-14","start":"2026-12-01","leaves":[{"number":"I1"},{"number":"I2","blockedBy":["I1","I1"]}]}' \
  "$DATES" '[["I1", "2026-12-01", "2026-12-01"], ["I2", "2026-12-02", "2026-12-02"]]'
expect "a fixed leaf is never assigned and keeps its dates" \
  '{"today":"2026-11-14","start":"2026-12-01","leaves":[{"number":"I1","fixed":true,"startDate":"2026-11-10","dueDate":"2026-11-10"},{"number":"I2","blockedBy":["I1"]},{"number":"I3","blockedBy":["I2"]}]}' \
  "[d['fixed'],d['heldBy'],$DATES]" '[["I1"], null, [["I2", "2026-12-01", "2026-12-01"], ["I3", "2026-12-02", "2026-12-02"]]]'
expect "a fixed blocker due on or after the requested start holds the whole cascade until the day after it" \
  '{"today":"2026-11-14","start":"2026-12-01","leaves":[{"number":"I1","fixed":true,"startDate":"2026-12-01","dueDate":"2026-12-03"},{"number":"I2","blockedBy":["I1"]},{"number":"I3"}]}' \
  "[d['start'],d['requestedStart'],d['heldBy'],$DATES]" \
  '["2026-12-04", "2026-12-01", "I1", [["I2", "2026-12-04", "2026-12-04"], ["I3", "2026-12-04", "2026-12-04"]]]'
expect "a fixed leaf that blocks nothing open never holds the start" \
  '{"today":"2026-11-14","start":"2026-12-01","leaves":[{"number":"I1","fixed":true,"startDate":"2026-12-09","dueDate":"2026-12-09"},{"number":"I2"}]}' \
  "[d['start'],d['heldBy']]" '["2026-12-01", null]'
expect "a cycle that runs through a fixed leaf still stops the pass with no dates" \
  '{"today":"2026-11-14","start":"2026-12-01","leaves":[{"number":"I1","fixed":true,"blockedBy":["I2"],"startDate":"2026-11-10","dueDate":"2026-11-10"},{"number":"I2","blockedBy":["I1"]},{"number":"I3","blockedBy":["I2"]}]}' \
  "[sorted(d),d['cycles'][0]['members'],d['cycles'][0]['path']]" '[["cycles"], ["I1", "I2"], ["I1", "I2", "I1"]]' 1
expect "a fixed leaf blocked by an open one, with no cycle, is history: it keeps its dates and holds nothing" \
  '{"today":"2026-11-14","leaves":[{"number":"I1"},{"number":"I2","fixed":true,"blockedBy":["I1"],"startDate":"2026-11-10","dueDate":"2026-11-10"},{"number":"I3","blockedBy":["I2"]}]}' \
  "[d['heldBy'],$DATES]" '[null, [["I1", "2026-11-15", "2026-11-15"], ["I3", "2026-11-15", "2026-11-15"]]]'
expect "a fixed blocker inside the plan holds nothing when the leaf it blocks already starts after it" \
  '{"today":"2026-11-14","start":"2026-12-01","leaves":[{"number":"I1","fixed":true,"startDate":"2026-12-03","dueDate":"2026-12-03"},{"number":"I2"},{"number":"I3","blockedBy":["I2"]},{"number":"I4","blockedBy":["I3"]},{"number":"I5","blockedBy":["I4","I1"]}]}' \
  "[d['start'],d['heldBy'],d['end']]" '["2026-12-01", null, "2026-12-04"]'
expect "a held cascade moves by the fewest days that clear every fixed blocker" \
  '{"today":"2026-11-14","start":"2026-12-01","leaves":[{"number":"I1","fixed":true,"startDate":"2026-12-02","dueDate":"2026-12-02"},{"number":"I2"},{"number":"I3","blockedBy":["I2"]},{"number":"I4","blockedBy":["I3","I1"]}]}' \
  "[d['start'],d['requestedStart'],d['heldBy'],$DATES]" \
  '["2026-12-01", "2026-12-01", null, [["I2", "2026-12-01", "2026-12-01"], ["I3", "2026-12-02", "2026-12-02"], ["I4", "2026-12-03", "2026-12-03"]]]'
expect "two fixed blockers that hold equally: the lower item number is named, whatever order the edges arrive in" \
  '{"today":"2026-11-14","start":"2026-12-01","leaves":[{"number":"I2","fixed":true,"startDate":"2026-12-05","dueDate":"2026-12-05"},{"number":"I1","fixed":true,"startDate":"2026-12-05","dueDate":"2026-12-05"},{"number":"I3","blockedBy":["I2","I1"]}]}' \
  "[d['start'],d['heldBy']]" '["2026-12-06", "I1"]'
expect "a fixed blocker with only a start date holds by that date" \
  '{"today":"2026-11-14","start":"2026-12-01","leaves":[{"number":"I1","fixed":true,"startDate":"2026-12-20"},{"number":"I2","blockedBy":["I1"]}]}' \
  "[d['start'],d['heldBy']]" '["2026-12-21", "I1"]'
expect "no itemDays: the length the dated open leaves already share is kept" \
  '{"today":"2026-11-14","start":"2026-12-01","leaves":[{"number":"I1","startDate":"2026-11-01","dueDate":"2026-11-03"},{"number":"I2","blockedBy":["I1"],"startDate":"2026-11-04","dueDate":"2026-11-06"},{"number":"I3","blockedBy":["I2"]},{"number":"I4","fixed":true,"startDate":"2026-10-01","dueDate":"2026-10-09"}]}' \
  "[d['itemDays'],d['itemDaysFrom'],$DATES]" \
  '[3, "existing", [["I1", "2026-12-01", "2026-12-03"], ["I2", "2026-12-04", "2026-12-06"], ["I3", "2026-12-07", "2026-12-09"]]]'
expect "no itemDays, a three-day plan with a new one-day placeholder: the length most open leaves have is kept" \
  '{"today":"2026-11-14","start":"2026-12-01","leaves":[{"number":"I9","fixed":true,"startDate":"2026-11-10","dueDate":"2026-11-12"},{"number":"I10","blockedBy":["I9"],"startDate":"2026-12-01","dueDate":"2026-12-03"},{"number":"I11","blockedBy":["I10"],"startDate":"2026-12-04","dueDate":"2026-12-06"},{"number":"I50","blockedBy":["I11"],"startDate":"2026-11-14","dueDate":"2026-11-14"}]}' \
  "[d['itemDays'],d['itemDaysFrom'],$DATES]" \
  '[3, "existing", [["I10", "2026-12-01", "2026-12-03"], ["I11", "2026-12-04", "2026-12-06"], ["I50", "2026-12-07", "2026-12-09"]]]'
expect "no itemDays, as many one-day stories as three-day ones: the longer length wins the tie" \
  '{"today":"2026-11-14","leaves":[{"number":"I1","startDate":"2026-11-01","dueDate":"2026-11-03"},{"number":"I2","startDate":"2026-11-10","dueDate":"2026-11-10"}]}' \
  "[d['itemDays'],d['itemDaysFrom']]" '[3, "existing"]'
expect "no itemDays, today-dated placeholders outnumber the plan's stories: they have no vote" \
  '{"today":"2026-11-14","start":"2026-12-01","leaves":[{"number":"I3","startDate":"2026-12-01","dueDate":"2026-12-03"},{"number":"I50","blockedBy":["I3"],"startDate":"2026-11-14","dueDate":"2026-11-14"},{"number":"I51","blockedBy":["I50"],"startDate":"2026-11-14","dueDate":"2026-11-14"},{"number":"I52","blockedBy":["I51"],"startDate":"2026-11-14","dueDate":"2026-11-14"}]}' \
  "[d['itemDays'],d['itemDaysFrom'],d['end']]" '[3, "existing", "2026-12-12"]'
expect "no start, open leaves already dated in the future: the plan keeps the start it has" \
  '{"today":"2026-11-14","leaves":[{"number":"I10","startDate":"2026-12-01","dueDate":"2026-12-03"},{"number":"I11","blockedBy":["I10"],"startDate":"2026-12-04","dueDate":"2026-12-06"}]}' \
  "[d['start'],d['startFrom'],$DATES]" \
  '["2026-12-01", "existing", [["I10", "2026-12-01", "2026-12-03"], ["I11", "2026-12-04", "2026-12-06"]]]'
expect "no start, a future plan extended with a today-dated placeholder: the placeholder does not pull it to tomorrow" \
  '{"today":"2026-11-14","leaves":[{"number":"I10","startDate":"2026-12-01","dueDate":"2026-12-03"},{"number":"I11","blockedBy":["I10"],"startDate":"2026-12-04","dueDate":"2026-12-06"},{"number":"I50","blockedBy":["I11"],"startDate":"2026-11-14","dueDate":"2026-11-14"}]}' \
  "[d['start'],d['startFrom'],d['itemDays'],$DATES]" \
  '["2026-12-01", "existing", 3, [["I10", "2026-12-01", "2026-12-03"], ["I11", "2026-12-04", "2026-12-06"], ["I50", "2026-12-07", "2026-12-09"]]]'
expect "no start, open leaves dated today or earlier: the day after today, never today" \
  '{"today":"2026-11-14","leaves":[{"number":"I10","startDate":"2026-11-05","dueDate":"2026-11-05"},{"number":"I11","blockedBy":["I10"],"startDate":"2026-11-15","dueDate":"2026-11-15"}]}' \
  "[d['start'],d['startFrom']]" '["2026-11-15", "default"]'
expect "a given start wins over the start the plan has, earlier or later" \
  '{"today":"2026-11-14","start":"2026-11-20","leaves":[{"number":"I10","startDate":"2026-12-01","dueDate":"2026-12-01"}]}' \
  "[d['start'],d['startFrom'],d['requestedStart']]" '["2026-11-20", "given", "2026-11-20"]'
expect "no itemDays and no open leaf with both dates in order: one day" \
  '{"today":"2026-11-14","leaves":[{"number":"I1","startDate":"2026-11-05","dueDate":"2026-11-03"},{"number":"I2","startDate":"2026-11-04"},{"number":"I3","fixed":true,"startDate":"2026-10-01","dueDate":"2026-10-09"}]}' \
  "[d['itemDays'],d['itemDaysFrom']]" '[1, "default"]'
expect "a given itemDays wins over the length the leaves carry" \
  '{"today":"2026-11-14","itemDays":2,"leaves":[{"number":"I1","startDate":"2026-11-01","dueDate":"2026-11-03"}]}' \
  "[d['itemDays'],d['itemDaysFrom'],$DATES]" '[2, "given", [["I1", "2026-11-15", "2026-11-16"]]]'
expect "group spans cover every dated leaf below the group, fixed ones included" \
  '{"today":"2026-11-14","start":"2026-12-01","itemDays":2,"leaves":[{"number":"I1","fixed":true,"startDate":"2026-11-10","dueDate":"2026-11-10","groups":["I70","I80"]},{"number":"I2","blockedBy":["I1"],"groups":["I70","I80"]},{"number":"I3","blockedBy":["I2"],"groups":["I71","I80"]},{"number":"I4","fixed":true,"groups":["I72"]}]}' \
  "d['groupSpans']" \
  '{"I70": {"startDate": "2026-11-10", "dueDate": "2026-12-02"}, "I71": {"startDate": "2026-12-03", "dueDate": "2026-12-04"}, "I80": {"startDate": "2026-11-10", "dueDate": "2026-12-04"}}'
expect "a fixed leaf with only one of its dates still widens its group\'s span" \
  '{"today":"2026-11-14","start":"2026-12-01","leaves":[{"number":"I1","fixed":true,"startDate":"2026-11-10","groups":["I70"]},{"number":"I2","fixed":true,"dueDate":"2026-12-20","groups":["I70"]},{"number":"I3","groups":["I70"]}]}' \
  "d['groupSpans']" '{"I70": {"startDate": "2026-11-10", "dueDate": "2026-12-20"}}'
expect "nothing open: no dates and no end" \
  '{"today":"2026-11-14","leaves":[{"number":"I1","fixed":true}]}' "[d['assignments'],d['end'],d['distribution']]" '[[], null, []]'

SAME="$(python3 - "$SC" "$PLAN" <<'PY'
import json, subprocess, sys
script, plan = sys.argv[1], json.loads(sys.argv[2])
def dates(leaves):
    out = subprocess.run([sys.executable, script], input=json.dumps({"today": "2026-11-14", "start": "2026-12-01", "itemDays": 2, "leaves": leaves}),
                         capture_output=True, text=True).stdout
    return [(a["number"], a["startDate"], a["dueDate"]) for a in json.loads(out)["assignments"]]
print(dates(plan) == dates(list(reversed(plan))) == dates(plan))
PY
)"
[ "$SAME" = True ] && ok "the dates do not depend on the order the leaves arrive in, and a re-run changes nothing" || bad "order or re-run changed the dates"

DEEP="$(python3 -c "
import json
print(json.dumps({'today':'2026-11-14','start':'2026-12-01','leaves':[{'number':'I%d'%i,'blockedBy':(['I%d'%(i-1)] if i else [])} for i in range(3000)]}))")"
expect "a chain 3,000 leaves deep is dated without running out of stack" "$DEEP" \
  "[len(d['assignments']),d['assignments'][0]['number'],d['assignments'][-1]['depth'],d['end']]" '[3000, "I0", 0, "2035-02-16"]'
DEEPCYCLE="$(python3 -c "
import json
n=3000
print(json.dumps({'today':'2026-11-14','leaves':[{'number':'I%d'%i,'blockedBy':['I%d'%((i-1)%n)]} for i in range(n)]}))")"
expect "a cycle 3,000 leaves round is reported without running out of stack" "$DEEPCYCLE" \
  "[len(d['cycles']),len(d['cycles'][0]['members']),len(d['cycles'][0]['path']),'assignments' in d]" '[1, 3000, 3001, false]' 1

# Cycles: exit 1, no dates, only the true members — an innocent blocker of a member is not named.
CYCLE='{"today":"2026-11-14","leaves":[{"number":"I1","blockedBy":["I2"]},{"number":"I2","blockedBy":["I1","I3"]},{"number":"I3"},{"number":"I4","blockedBy":["I4"]},{"number":"I5","blockedBy":["I6"]},{"number":"I6","blockedBy":["I7"]},{"number":"I7","blockedBy":["I5"]},{"number":"I8","blockedBy":["I5"]}]}'
expect "a cycle writes no dates and exits 1" "$CYCLE" "sorted(d)" '["cycles"]' 1
expect "only the true members are named: neither a blocker of a member (I3) nor a leaf waiting on one (I8)" "$CYCLE" \
  "[c['members'] for c in d['cycles']]" '[["I1", "I2"], ["I4"], ["I5", "I6", "I7"]]' 1
expect "each cycle's path reads blocker to blocked and ends where it began" "$CYCLE" \
  "[c['path'] for c in d['cycles']]" '[["I1", "I2", "I1"], ["I4", "I4"], ["I5", "I7", "I6", "I5"]]' 1
PATHS_OK="$(run "$CYCLE" | python3 -c "
import json,sys
req=json.loads(sys.argv[1]); by={l['number']:l.get('blockedBy',[]) for l in req['leaves']}
print(all(a in by[b] for c in json.load(sys.stdin)['cycles'] for a,b in zip(c['path'],c['path'][1:])))" "$CYCLE")"
[ "$PATHS_OK" = True ] && ok "every step of a reported path is a real blocked-by edge" || bad "a reported path has a step that is not an edge"

for bad_input in 'not json' '[]' '{"leaves":[]}' '{"today":"2026-13-40","leaves":[]}' '{"today":"2026-11-14","start":"soon","leaves":[]}' \
  '{"today":"2026-11-14","leaves":"x"}' '{"today":"2026-11-14","leaves":[{"blockedBy":[]}]}' '{"today":"2026-11-14","leaves":[{"number":5}]}' \
  '{"today":"2026-11-14","leaves":[{"number":"I1"},{"number":"I1"}]}' '{"today":"2026-11-14","leaves":[{"number":"I1","blockedBy":"I2"}]}' \
  '{"today":"2026-11-14","leaves":[{"number":"I1","groups":[7]}]}' '{"today":"2026-11-14","leaves":[{"number":"I1","fixed":true,"dueDate":"then"}]}' \
  '{"today":"2026-11-14","leaves":[{"number":"I1","fixed":"true"}]}' '{"today":"2026-11-14","itemDays":4000000,"leaves":[{"number":"I1"},{"number":"I2","blockedBy":["I1"]}]}' \
  '{"today":"2026-11-14","itemDays":0,"leaves":[]}' '{"today":"2026-11-14","itemDays":1.5,"leaves":[]}' '{"today":"2026-11-14","itemDays":"3","leaves":[]}' '{"today":"2026-11-14","itemDays":true,"leaves":[]}'; do
  out="$(run "$bad_input")"; rc=$?
  if [ "$rc" = 2 ] && printf '%s' "$out" | python3 -c 'import json,sys; assert "error" in json.load(sys.stdin)' 2>/dev/null; then ok "malformed input exits 2 with a JSON error ($bad_input)"; else bad "malformed $bad_input -> rc=$rc $out"; fi
done

[ "$FAIL" -eq 0 ]
