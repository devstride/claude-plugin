#!/bin/bash
# Tests for skills/setup/scripts/active-agents.py — the Active Agents block: validate, merge-labels,
# render, run, classify. No network; run uses throwaway commands in a temporary repository.
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
expect_invalid "an unknown key is reported" '{"activeAgents": {"bord": "x", "commands": {"start": "x <root>", "end": "y"}}}' "activeAgents.bord"
cfg '{"activeAgents": {"staleMinutes": 0, "tagName": "", "commands": {"start": "x", "end": ""}}}'
out="$(aa validate)"; [ "$(first "$out")" = "ACTIVE AGENTS: INVALID (4)" ] && ok "every problem is reported, not just the first" || bad "multi -> $out"
printf 'not json' > "$TMP/.claude/ds-config.json"; aa validate >/dev/null; [ $? = 2 ] && ok "an unreadable config exits 2" || bad "unreadable config"

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
cfg '{"activeAgents": {"commands": {"start": "no-such-command-xyz <root>", "end": "true"}}}'
out="$(aa run start I1)"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q "FAILED exit 127" && ok "a missing command is reported, exit 0" || bad "missing cmd -> rc=$rc $out"
cfg '{}'; rm -f "$TMP/got.txt"
out="$(aa run start I1)"; [ "$out" = "ACTIVE AGENTS start: NOT CONFIGURED" ] && [ ! -e "$TMP/got.txt" ] && ok "an absent block runs nothing" || bad "absent run -> $out"
out="$(aa run start 'I1;true')"; [ $? = 2 ] && ok "run refuses a bad root before running anything" || bad "run bad root"

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
printf 'nope' | python3 "$SC" classify >/dev/null; [ $? = 2 ] && ok "malformed classify input exits 2" || bad "classify malformed"
out="$(python3 "$SC" bogus)"; [ $? = 2 ] && ok "an unknown subcommand exits 2" || bad "bogus"

# doctor's agents section is read-only: it names no DevStride write tool and runs no command
DOC="$ROOT/skills/doctor/references/agents.md"
W="$(grep -oE '\b(create|update|delete|archive|move|add|remove|reparent|bulk|mark|reopen|invoke)_[a-z_]+' "$DOC" | sort -u | tr '\n' ' ')"
[ -z "$W" ] && ok "doctor's agents section names no DevStride write tool" || bad "doctor agents names write tools: $W"
grep -q "never executed" "$DOC" && ok "doctor's agents section never runs the commands" || bad "doctor agents: commands may run"

[ "$FAIL" -eq 0 ]
