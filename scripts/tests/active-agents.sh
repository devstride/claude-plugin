#!/bin/bash
# Tests for skills/setup/scripts/active-agents.py — the Active Agents block: validate, merge-labels,
# render, run, resolve-root, comment, came-from, settle, pick-view, classify. No network; run uses
# throwaway commands in a temporary repository.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; SC="$ROOT/skills/setup/scripts/active-agents.py"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" init -q
cfg() { mkdir -p "$TMP/.claude"; printf '%s' "$1" > "$TMP/.claude/ds-config.json"; }
aa() { (cd "$TMP" && python3 "$SC" "$@"); }
first() { printf '%s' "$1" | head -1; }

# validate
cfg '{"activeAgents": {"boardId": "b1", "tagName": "agent active", "tagColor": "green", "staleMinutes": 20, "commands": {"start": "echo start <root>", "end": "echo end"}}}'
out="$(aa validate)"; rc=$?
[ "$rc" = 0 ] && [ "$(first "$out")" = "ACTIVE AGENTS: VALID" ] && ok "a full block is valid" || bad "full block -> rc=$rc $out"
cfg '{"activeAgents": {"commands": {"start": "x <root>", "end": "y"}}}'
out="$(aa validate)"; eff="$(printf '%s' "$out" | sed -n 2p)"
[ "$(first "$out")" = "ACTIVE AGENTS: VALID" ] && [ "$(printf '%s' "$eff" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["tagName"], d["tagColor"], d["staleMinutes"], d["boardId"])')" = "agent active green 20 None" ] \
  && ok "a block with only the commands is valid, defaults filled" || bad "commands-only -> $out"
for c in '{"activeAgents": null}' '{}'; do
  cfg "$c"; out="$(aa validate)"; rc=$?
  [ "$rc" = 0 ] && [ "$out" = "ACTIVE AGENTS: NOT CONFIGURED" ] && ok "absent or null block: not configured ($c)" || bad "$c -> rc=$rc $out"
done
expect_invalid() { # label config needle
  cfg "$2"; local out rc; out="$(aa validate)"; rc=$?
  if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "$3"; then ok "$1"; else bad "$1 -> rc=$rc $out"; fi
}
expect_invalid "a non-object block is invalid" '{"activeAgents": "yes"}' "must be an object or null"
expect_invalid "an empty tag name is invalid" '{"activeAgents": {"tagName": " ", "commands": {"start": "x <root>", "end": "y"}}}' "activeAgents.tagName"
expect_invalid "a zero staleMinutes is invalid" '{"activeAgents": {"staleMinutes": 0, "commands": {"start": "x <root>", "end": "y"}}}' "activeAgents.staleMinutes"
expect_invalid "a fractional staleMinutes is invalid" '{"activeAgents": {"staleMinutes": 2.5, "commands": {"start": "x <root>", "end": "y"}}}' "activeAgents.staleMinutes"
expect_invalid "a boolean staleMinutes is invalid" '{"activeAgents": {"staleMinutes": true, "commands": {"start": "x <root>", "end": "y"}}}' "activeAgents.staleMinutes"
expect_invalid "a start command without <root> is invalid" '{"activeAgents": {"commands": {"start": "x", "end": "y"}}}' "must contain the <root> placeholder"
expect_invalid "a missing end command is invalid" '{"activeAgents": {"commands": {"start": "x <root>"}}}' "activeAgents.commands.end"
expect_invalid "missing commands are invalid" '{"activeAgents": {}}' "activeAgents.commands:"
expect_invalid "a colour create_label does not offer is invalid" '{"activeAgents": {"tagColor": "chartreuse", "commands": {"start": "x <root>", "end": "y"}}}' "activeAgents.tagColor: must be one of"
expect_invalid "an unknown key is reported" '{"activeAgents": {"bord": "x", "commands": {"start": "x <root>", "end": "y"}}}' "activeAgents.bord"
cfg '{"activeAgents": {"staleMinutes": 0, "tagName": "", "commands": {"start": "x", "end": ""}}}'
out="$(aa validate)"; [ "$(first "$out")" = "ACTIVE AGENTS: INVALID (4)" ] && ok "every problem is reported, not just the first" || bad "multi -> $out"
expect_invalid "an unknown command key is reported" '{"activeAgents": {"commands": {"start": "x <root>", "end": "y", "extra": "z"}}}' "activeAgents.commands.extra"
printf 'not json' > "$TMP/.claude/ds-config.json"; aa validate >/dev/null; [ $? = 2 ] && ok "an unreadable config exits 2" || bad "unreadable config"
rm -f "$TMP/.claude/ds-config.json"; out="$(aa validate)"; rc=$?
[ "$rc" = 0 ] && [ "$out" = "ACTIVE AGENTS: NOT CONFIGURED" ] && ok "no config file yet is not configured (setup agents can start a fresh repository)" || bad "no config -> rc=$rc $out"

for c in '"Capability"' 'null' '"Capabilty"'; do
  cfg '{"activeAgents": {"rootLevel": '"$c"', "commands": {"start": "x <root>", "end": "y"}}}'
  out="$(aa validate)"; rc=$?
  [ "$rc" = 0 ] && [ "$(first "$out")" = "ACTIVE AGENTS: VALID" ] && ok "rootLevel $c is valid" || bad "rootLevel $c -> rc=$rc $out"
done
cfg '{"activeAgents": {"commands": {"start": "x <root>", "end": "y"}}}'
[ "$(aa validate | sed -n 2p | python3 -c 'import json,sys; print(json.load(sys.stdin)["rootLevel"])')" = "None" ] && ok "an absent rootLevel is valid and reads as null (the level above the release unit)" || bad "absent rootLevel"
expect_invalid "an empty rootLevel is invalid" '{"activeAgents": {"rootLevel": " ", "commands": {"start": "x <root>", "end": "y"}}}' "activeAgents.rootLevel"
expect_invalid "a non-string rootLevel is invalid" '{"activeAgents": {"rootLevel": 3, "commands": {"start": "x <root>", "end": "y"}}}' "activeAgents.rootLevel"
expect_invalid "a list rootLevel is invalid" '{"activeAgents": {"rootLevel": ["Capability"], "commands": {"start": "x <root>", "end": "y"}}}' "activeAgents.rootLevel"

# merge-labels
m() { printf '%s' "$1" | python3 "$SC" merge-labels; }
out="$(m '{"labels":["a","b"],"tag":"t"}')"
[ "$out" = '{"change": true, "added": ["t"], "before": ["a", "b"], "after": ["a", "b", "t"]}' ] && ok "the tag is appended, every existing id kept, the difference printed" || bad "merge -> $out"
again="$(m "$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps({"labels": d["after"], "tag": "t"}))')")"
[ "$again" = '{"change": false, "added": [], "before": ["a", "b", "t"], "after": ["a", "b", "t"]}' ] && ok "merging twice equals merging once (no change)" || bad "idempotence -> $again"
for b in '{"labels":"a","tag":"t"}' '{"labels":["a"]}' '{"labels":[""],"tag":"t"}' 'nope'; do
  printf '%s' "$b" | python3 "$SC" merge-labels >/dev/null; [ $? = 2 ] && ok "malformed merge input exits 2 ($b)" || bad "merge $b"
done

# render
cfg '{"activeAgents": {"commands": {"start": "./tool start <root> --x", "end": "./tool end <root>"}}}'
[ "$(aa render start I12)" = "./tool start I12 --x" ] && ok "render substitutes an item number" || bad "render start"
[ "$(aa render end F7)" = "./tool end F7" ] && ok "render accepts a workstream number" || bad "render end"
for r in 'I1; rm -rf /' '' 'i12' 'https://example.com/I1' 'I12 ' 'I'; do
  out="$(aa render start "$r")"; rc=$?
  [ "$rc" = 2 ] && printf '%s' "$out" | grep -q '"error"' && ok "render refuses root '$r'" || bad "render '$r' -> rc=$rc $out"
done
out="$(aa render middle I1)"; [ $? = 2 ] && ok "render refuses an unknown verb" || bad "render verb"

# run — fail open, environment exported, from the repository root
mkdir -p "$TMP/sub"
cfg '{"activeAgents": {"tagName": "busy", "staleMinutes": 7, "commands": {"start": "printf \"%s|%s|%s|%s\" \"$ACTIVE_AGENTS_ROOT\" \"$ACTIVE_AGENTS_TAG\" \"$ACTIVE_AGENTS_STALE_MINUTES\" \"$(pwd)\" > got.txt; echo <root>", "end": "exit 3"}}}'
out="$(cd "$TMP/sub" && python3 "$SC" run start I44)"; rc=$?
REAL="$(cd "$TMP" && pwd -P)"
[ "$rc" = 0 ] && [ "$out" = "ACTIVE AGENTS start: DONE" ] && [ "$(cat "$TMP/got.txt")" = "I44|busy|7|$REAL" ] \
  && ok "run exports root, tag and staleMinutes and runs from the repository root" || bad "run start -> rc=$rc $out $(cat "$TMP/got.txt" 2>/dev/null)"
out="$(aa run end I44)"; rc=$?
[ "$rc" = 0 ] && [ "$out" = "ACTIVE AGENTS end: FAILED exit 3" ] && ok "a failing command is one line and exit 0 (fail open)" || bad "run end -> rc=$rc $out"
cfg '{"activeAgents": {"commands": {"start": "sleep 5; echo <root>", "end": "true"}}}'
T0=$(date +%s); out="$(aa run start I1 --timeout 0.5)"; rc=$?; T1=$(date +%s)
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q "FAILED timed out" && [ $((T1 - T0)) -lt 4 ] && ok "a hanging command is killed at the limit with its children, exit 0" || bad "timeout -> rc=$rc $out"
cfg '{"activeAgents": {"commands": {"start": "python3 -c \"import os,time; os.setsid(); time.sleep(4)\" & sleep 5; echo <root>", "end": "printf \"\\377\\376 bad\"; exit 4"}}}'
T0=$(date +%s); out="$(aa run start I1 --timeout 0.5)"; rc=$?; T1=$(date +%s)
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q "FAILED timed out" && [ $((T1 - T0)) -lt 3 ] && ok "a descendant that leaves the group does not hold run past the limit" || bad "detached -> rc=$rc $out $((T1 - T0))s"
out="$(aa run end I1)"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q "FAILED exit 4" && ok "output that is not UTF-8 still gives one FAILED line, exit 0" || bad "non-utf8 -> rc=$rc $out"
cfg '{"activeAgents": {"commands": {"start": "no-such-command-xyz <root>", "end": "true"}}}'
out="$(aa run start I1)"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q "FAILED exit 127" && ok "a missing command is reported, exit 0" || bad "missing cmd -> rc=$rc $out"
cfg '{}'; rm -f "$TMP/got.txt"
out="$(aa run start I1)"; [ "$out" = "ACTIVE AGENTS start: NOT CONFIGURED" ] && [ ! -e "$TMP/got.txt" ] && ok "an absent block runs nothing" || bad "absent run -> $out"
out="$(aa run start 'I1;true')"; [ $? = 2 ] && ok "run refuses a bad root before running anything" || bad "run bad root"

# resolve-root — never a question, first match wins
rr() { printf '%s' "$1" | python3 "$SC" resolve-root; }
CH='[{"number":"I30","workType":"Story"},{"number":"I20","workType":"Epic"},{"number":"I10","workType":"Capability"},{"number":"I5","workType":"Solution"}]'
L='"leafTypes":["Story","Defect"]'
[ "$(rr '{"chain":'"$CH"',"rootLevel":"Capability",'"$L"',"planRoot":"I5"}')" = "ROOT I10 (level Capability)" ] \
  && ok "a Story under an Epic under a Capability resolves to the Capability" || bad "level -> $(rr '{"chain":'"$CH"',"rootLevel":"Capability",'"$L"',"planRoot":"I5"}')"
[ "$(rr '{"chain":'"$CH"',"rootLevel":"Capability",'"$L"',"planRoot":"I5","argument":{"number":"I99","workType":"Solution"}}')" = "ROOT I99 (argument)" ] \
  && ok "the --board-root argument wins over everything" || bad "argument"
MK='[{"number":"I30","workType":"Story"},{"number":"I20","workType":"Epic","description":"<p>x</p><p><strong>Active Agents root:</strong> this item</p>"},{"number":"I10","workType":"Capability"}]'
[ "$(rr '{"chain":'"$MK"',"rootLevel":"Capability",'"$L"',"planRoot":"I10"}')" = "ROOT I20 (marker)" ] \
  && ok "the description marker wins over the level" || bad "marker -> $(rr '{"chain":'"$MK"',"rootLevel":"Capability",'"$L"'}')"
[ "$(rr '{"chain":[{"number":"I30","workType":"Story"},{"number":"I20","workType":"Epic","marker":true},{"number":"I10","workType":"Capability"}],"rootLevel":"Capability",'"$L"'}')" = "ROOT I20 (marker)" ] \
  && ok "a marker flag counts like the marker text" || bad "marker flag"
[ "$(rr '{"chain":[{"number":"I30","workType":"Story","marker":true},{"number":"I20","workType":"Epic"}],"rootLevel":"Epic",'"$L"'}')" = "ROOT I20 (level Epic)" ] \
  && ok "a marker on a leaf is never a root" || bad "leaf marker"
[ "$(rr '{"chain":[{"number":"I10","workType":"Capability"},{"number":"I5","workType":"Solution"}],"rootLevel":"Capability",'"$L"',"planRoot":"I5"}')" = "ROOT I10 (level Capability)" ] \
  && ok "the item itself resolves when it is that level" || bad "self"
[ "$(rr '{"chain":[{"number":"I30","workType":"Story"},{"number":"I20","workType":"Epic"}],"rootLevel":"Capability",'"$L"',"planRoot":"I20"}')" = "ROOT I20 (plan root)" ] \
  && ok "no ancestor at that level: the run's plan root" || bad "plan root"
out="$(rr '{"chain":[{"number":"I30","workType":"Story"},{"number":"F2","workType":null}],"rootLevel":"Capability",'"$L"',"planRoot":null}')"
[ "$out" = "ROOT NONE (no argument, no marker, no Capability above, no plan root)" ] && ok "a chain with no root: ROOT NONE with its reasons, exit 0" || bad "none -> $out"
DF='[{"number":"I31","workType":"Defect","deferred":true},{"number":"I21","workType":"Capability","deferred":true,"marker":true},{"number":"I10","workType":"Capability"}]'
[ "$(rr '{"chain":'"$DF"',"rootLevel":"Capability",'"$L"',"planRoot":"I21"}')" = "ROOT I10 (level Capability)" ] \
  && ok "the deferred container is never a root; its members resolve through the chain above it" || bad "deferred -> $(rr '{"chain":'"$DF"',"rootLevel":"Capability",'"$L"',"planRoot":"I21"}')"
[ "$(rr '{"chain":[{"number":"I31","workType":"Defect","deferred":true},{"number":"I21","workType":"Epic","deferred":true}],"rootLevel":"Capability",'"$L"',"planRoot":"I21"}' | cut -c1-9)" = "ROOT NONE" ] \
  && ok "a deferred container named as the plan root is still not a root" || bad "deferred plan root"
[ "$(rr '{"chain":[{"number":"I30","workType":"story"},{"number":"I10","workType":"Capabilty"}],"rootLevel":"CAPABILTY",'"$L"'}')" = "ROOT I10 (level Capabilty)" ] \
  && ok "the work type matches case-insensitively, the organization's own spelling kept" || bad "case"
[ "$(rr '{"chain":[{"number":"F3","workType":"Capability"},{"number":"I10","workType":"Capability"}],"rootLevel":"Capability",'"$L"'}')" = "ROOT I10 (level Capability)" ] \
  && ok "a workstream is never a root (it cannot sit on a board)" || bad "workstream"
for b in 'nope' '{"chain":"x"}' '{"chain":[{"number":"x"}]}' '{"chain":[],"planRoot":"I1;x"}' '{"chain":[],"rootLevel":3}'; do
  printf '%s' "$b" | python3 "$SC" resolve-root >/dev/null; [ $? = 2 ] && ok "malformed resolve-root input exits 2 ($b)" || bad "resolve $b"
done

# comment and came-from — the placement comment is the reversal record
cm() { python3 "$SC" comment "$@" | python3 -c 'import json,sys; print(json.load(sys.stdin)["html"])'; }
P1="$(cm placed --board b-old --label 'Q4 <Ops> board')"
printf '%s' "$P1" | grep -q 'Came from: Q4 &lt;Ops&gt; board (board b-old).' && ok "the placement comment names the board it came from, escaped" || bad "placed -> $P1"
P0="$(cm placed)"; R1="$(cm removed --board b-old --label Ops)"
printf '%s' "$R1" | grep -q 'Moved to: Ops (board b-old).' && ok "the removal comment names where it went" || bad "removed -> $R1"
python3 "$SC" comment middle >/dev/null; [ $? = 2 ] && ok "comment refuses an unknown kind" || bad "comment kind"
python3 "$SC" comment placed --board 'x y' >/dev/null; [ $? = 2 ] && ok "comment refuses a board id that is not an id" || bad "comment board"
cf() { python3 -c 'import json,sys; print(json.dumps({"comments": [{"html": h, "dateAdded": d} for h, d in zip(sys.argv[1::2], sys.argv[2::2])]}))' "$@" | python3 "$SC" came-from; }
[ "$(cf "$P1" 2026-01-02T00:00:00Z "<p>unrelated</p>" 2026-01-03T00:00:00Z)" = "FROM b-old" ] && ok "came-from reads the board out of the placement comment" || bad "came-from"
[ "$(cf "$P1" 2026-01-02T00:00:00Z "$P0" 2026-01-05T00:00:00Z)" = "FROM NONE (it was on no board)" ] && ok "the newest placement comment wins" || bad "newest"
[ "$(cf "$R1" 2026-01-02T00:00:00Z)" = "FROM NONE (no placement comment)" ] && ok "a removal comment is not a placement record" || bad "removal not placement"
[ "$(cf "<p>moved here from Sprint 4</p>" 2026-01-02T00:00:00Z)" = "FROM NONE (no placement comment)" ] && ok "a free-text comment is not read as a placement record" || bad "free text"

# settle — when a finished root comes off, and where it goes
st() { printf '%s' "$1" | python3 "$SC" settle; }
[ "$(st '{"remaining":2,"onBoard":true,"boardId":"aa","cameFrom":{"id":"b1","exists":true,"archived":false}}')" = "SETTLE KEEP (2 remaining)" ] && ok "a root with work left stays" || bad "keep remaining"
[ "$(st '{"remaining":0,"onBoard":false,"boardId":"aa","cameFrom":null}')" = "SETTLE KEEP (not on the Active Agents board)" ] && ok "a finished root not on the board needs nothing" || bad "keep off"
[ "$(st '{"remaining":0,"onBoard":true,"boardId":"aa","cameFrom":{"id":"b1","exists":true,"archived":false}}')" = "SETTLE MOVE b1" ] && ok "a finished root goes back to the board it came from" || bad "move"
for c in 'null' '{"id":"b1","exists":false}' '{"id":"b1","exists":true,"archived":true}' '{"id":"aa","exists":true,"archived":false}'; do
  [ "$(st '{"remaining":0,"onBoard":true,"boardId":"aa","cameFrom":'"$c"'}' | cut -c1-11)" = "SETTLE OFF " ] && ok "no board to go back to: off every board ($c)" || bad "off $c"
done
for b in '{"remaining":-1}' '{"remaining":true}' '{"remaining":"0"}' 'nope'; do
  printf '%s' "$b" | python3 "$SC" settle >/dev/null; [ $? = 2 ] && ok "malformed settle input exits 2 ($b)" || bad "settle $b"
done

# pick-view — adopt before creating, never a second view
pv() { printf '%s' "$1" | python3 "$SC" pick-view | tr '\n' '|'; }
VW='{"views":[{"id":"v1","label":"Active Agent Threads","visibility":"internal","boardView":"table","dataVersion":4},{"id":"v2","label":"Active Agent Threads","visibility":"internal","boardView":"table","dataVersion":9},{"id":"v3","label":"Active Agents","visibility":"personal","dataVersion":20},{"id":"v4","label":"Active Agents","visibility":"internal","boardView":"card","dataVersion":30},{"id":"v5","label":"Sprint","visibility":"internal","dataVersion":50}]}'
[ "$(pv "$VW")" = "VIEW ADOPT v2|VIEW DUPLICATE v1|" ] && ok "pick-view adopts the shared table view with the highest dataVersion and reports the rest" || bad "pick-view -> $(pv "$VW")"
[ "$(pv '{"views":[{"id":"v5","label":"Sprint","visibility":"internal","dataVersion":1}]}')" = "VIEW CREATE|" ] && ok "no shared Active Agents table view: create one" || bad "pick-view create"

# classify
c() { printf '%s' "$1" | python3 "$SC" classify; }
CLEAN='{"board":{"exists":true,"archived":false},"boardItems":[{"number":"I1","workType":"Epic"}],"leafTypes":["Story","Defect"],"tag":{"id":"t"},"planRootTypes":[{"name":"Epic","labelCollectionId":"g1"},{"name":"Capability","labelCollectionId":"g1"}],"labelCollections":{"g1":["x","t"]},"taggedItems":[{"number":"I1","done":false}]}'
[ "$(c "$CLEAN")" = '{"findings": []}' ] && ok "a clean snapshot has no findings" || bad "clean -> $(c "$CLEAN")"
checks() { c "$1" | python3 -c 'import json,sys; print(",".join(f["check"] for f in json.load(sys.stdin)["findings"]))'; }
DIRTY='{"board":null,"boardItems":[{"number":"I2","workType":"Story"},{"number":"I3","workType":"Defect"},{"number":"I4","workType":"Story"},{"number":"I5","workType":"Story"},{"number":"I6","workType":"Story"},{"number":"I7","workType":"Story"}],"leafTypes":["Story","Defect"],"tag":{"id":"t"},"planRootTypes":[{"name":"Epic","labelCollectionId":"g1"},{"name":"Solution","labelCollectionId":null}],"labelCollections":{"g1":["x"]},"taggedItems":[{"number":"I9","done":true}]}'
[ "$(checks "$DIRTY")" = "board,tag-allowed,tag-group,leaf-on-board,tag-on-done" ] && ok "classify flags a missing board, the tag not allowed, an ungrouped type, Stories on the board and the tag on a Done root" || bad "dirty -> $(c "$DIRTY")"
[ "$(c "$DIRTY" | python3 -c 'import json,sys; f=[x for x in json.load(sys.stdin)["findings"] if x["check"]=="leaf-on-board"][0]; print(f["count"], f["items"])')" = "6 ['I2', 'I3', 'I4', 'I5', 'I6']" ] \
  && ok "leaf-on-board counts all and lists the first five" || bad "leaf count"
[ "$(checks '{"board":{"exists":true,"archived":true},"tag":null}')" = "board,tag" ] && ok "an archived board and a missing tag are flagged" || bad "archived/no tag"
sev() { c "$1" | python3 -c 'import json,sys; print(",".join("%s:%s" % (f["check"], f["severity"]) for f in json.load(sys.stdin)["findings"]))'; }
[ "$(sev '{"configured":false,"boards":[{"id":"bb","label":"Active Agents","archived":false}]}')" = "not-adopted:INFO" ] \
  && ok "no block and a board present: INFO, not FAIL" || bad "no block board -> $(c '{"configured":false,"boards":[{"id":"bb","label":"Active Agents","archived":false}]}')"
[ "$(sev '{"configured":false,"boards":[{"id":"bb","label":"Active Agents","archived":true},{"id":"cc","label":"Sprint 4"}]}')" = "no-board:INFO" ] \
  && ok "no block and no board (an archived one does not count): INFO" || bad "no block no board"
[ "$(sev "$DIRTY")" = "board:FAIL,tag-allowed:FAIL,tag-group:INFO,leaf-on-board:FAIL,tag-on-done:FAIL" ] && ok "every finding carries its severity" || bad "severity -> $(sev "$DIRTY")"
DOB='{"board":{"exists":true,"archived":false},"boardItems":[{"number":"I1","workType":"Capability","remaining":0},{"number":"I2","workType":"Capability","remaining":3},{"number":"I3","workType":"Epic"},{"number":"I4","workType":"Story","remaining":0},{"number":"I6","workType":"Epic","remaining":false}],"leafTypes":["Story"],"tag":{"id":"t"},"planRootTypes":[{"name":"Capability","labelCollectionId":"g1"}],"labelCollections":{"g1":["t"]}}'
[ "$(c "$DOB" | python3 -c 'import json,sys; f=[x for x in json.load(sys.stdin)["findings"] if x["check"]=="done-on-board"][0]; print(f["severity"], f["items"])')" = "FAIL ['I1']" ] \
  && ok "done-on-board: a plan root with nothing left, never one with work left or an uncounted one" || bad "done-on-board -> $(c "$DOB")"
RL='{"board":{"exists":true,"archived":false},"tag":{"id":"t"},"rootLevel":"Capablity","planRootTypes":[{"name":"Capability","labelCollectionId":"g1"},{"name":"Epic","labelCollectionId":"g1"}],"labelCollections":{"g1":["t"]}}'
[ "$(sev "$RL")" = "root-level:FAIL" ] && ok "root-level: a rootLevel that names no non-leaf type fails" || bad "root-level -> $(c "$RL")"
[ "$(sev "${RL/Capablity/capability}")" = "" ] && ok "root-level matches case-insensitively" || bad "root-level case"
VB='{"board":{"exists":true,"archived":false},"tag":{"id":"t"},"views":'
[ "$(sev "$VB"'[]}')" = "view:INFO" ] && ok "view: no shared table view is INFO" || bad "view none"
TWO='[{"id":"v1","label":"Active Agent Threads","visibility":"internal","dataVersion":2,"columns":null},{"id":"v2","label":"Active Agent Threads","visibility":"internal","dataVersion":5,"columns":[{"identifier":"identifier"},{"identifier":"status"},{"identifier":"progress"},{"identifier":"priority"},{"identifier":"pullRequests"},{"identifier":"tags"}]}]'
[ "$(c "$VB$TWO}" | python3 -c 'import json,sys; f=json.load(sys.stdin)["findings"]; print(len(f), f[0]["severity"], f[0]["items"])')" = "1 INFO ['v1']" ] \
  && ok "view: two views of the name is INFO naming the duplicate, the adopted one's columns pass" || bad "view two -> $(c "$VB$TWO}")"
HID='[{"id":"v2","label":"Active Agents","visibility":"internal","dataVersion":5,"columns":[{"identifier":"identifier","visible":true},{"identifier":"status","visible":false},{"identifier":"progress"},{"identifier":"priority"},{"identifier":"tags"}]}]'
[ "$(c "$VB$HID}" | python3 -c 'import json,sys; f=json.load(sys.stdin)["findings"]; print(len(f), f[0]["severity"], f[0]["items"])')" = "1 INFO ['status', 'pullRequests']" ] \
  && ok "view: a starting column hidden or missing is INFO, never FAIL" || bad "view hidden -> $(c "$VB$HID}")"
printf 'nope' | python3 "$SC" classify >/dev/null; [ $? = 2 ] && ok "malformed classify input exits 2" || bad "classify malformed"
out="$(python3 "$SC" bogus)"; [ $? = 2 ] && ok "an unknown subcommand exits 2" || bad "bogus"

# doctor's agents section is read-only: it names no DevStride write tool and runs no command
DOC="$ROOT/skills/doctor/references/agents.md"
W="$(grep -oE '\b(create|update|delete|archive|move|add|remove|reparent|bulk|mark|reopen|invoke)_[a-z_]+' "$DOC" | sort -u | tr '\n' ' ')"
[ -z "$W" ] && ok "doctor's agents section names no DevStride write tool" || bad "doctor agents names write tools: $W"
grep -q "never executed" "$DOC" && ok "doctor's agents section never runs the commands" || bad "doctor agents: commands may run"

[ "$FAIL" -eq 0 ]
