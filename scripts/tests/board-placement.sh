#!/bin/bash
# Tests for skills/setup/scripts/board-placement.py — the board placement rules: personal-path,
# validate, resolve, classify. No network; every run uses a throwaway repository and a throwaway
# personal file.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; SC="$ROOT/skills/setup/scripts/board-placement.py"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
TMP="$(mktemp -d)" || exit 2; trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" init -q
MINE="$TMP/mine.json"
export DEVSTRIDE_BOARD_PLACEMENT_FILE="$MINE"
cfg() { mkdir -p "$TMP/.claude"; printf '%s' "$1" > "$TMP/.claude/ds-config.json"; }
mine() { printf '%s' "$1" > "$MINE"; }
bp() { (cd "$TMP" && python3 "$SC" "$@"); }
first() { printf '%s' "$1" | head -1; }

# One folder ("prog") holding two long cycles and a long-lived board, a sub-folder ("sprints")
# holding three short cycles, a kanban board elsewhere, and the Active Agents board.
BOARDS='[
 {"id":"pi1","label":"PI 1","boardFolderId":"prog","startDate":"2026-01-01","endDate":"2026-03-31"},
 {"id":"pi2","label":"PI 2","boardFolderId":"prog","startDate":"2026-04-01","endDate":"2026-06-30"},
 {"id":"agents","label":"Active Agents","boardFolderId":"prog"},
 {"id":"s1","label":"Sprint 1","boardFolderId":"sprints","startDate":"2026-01-01","endDate":"2026-01-14"},
 {"id":"s2","label":"Sprint 2","boardFolderId":"sprints","startDate":"2026-01-15","endDate":"2026-01-28"},
 {"id":"s3","label":"Sprint 3","boardFolderId":"sprints","startDate":"2026-01-29","endDate":"2026-02-11","archived":true},
 {"id":"kanban","label":"Kanban","boardFolderId":"ops"},
 {"id":"old","label":"Old board","boardFolderId":"ops","archived":true}]'
CYCLES='{"activeAgents":{"boardId":"agents","commands":{"start":"x <root>","end":"y"}},"boardPlacement":{"rules":[
 {"name":"Ops work","match":{"team":["t-ops"]},"place":{"board":"kanban"}},
 {"name":"Spikes","match":{"workType":["story"],"tag":["Spike"]},"place":{"none":true}},
 {"name":"Epics","match":{"workType":["Epic"]},"place":{"cycleFolder":"prog"}},
 {"name":"Leaves","match":{"workType":["Story","Defect"]},"place":{"cycleFolder":"sprints"}}]}}'
resolve() { # item-json date -> one line
  printf '{"item": %s, "boards": %s, "date": "%s"}' "$1" "$BOARDS" "$2" | bp resolve
}
expect() { # label item date wanted-prefix
  local out; out="$(resolve "$2" "$3")"
  case "$out" in "$4"*) ok "$1" ;; *) bad "$1 -> $out" ;; esac
}
classify() { # date extra-json-members -> findings json
  printf '{"boards": %s, "date": "%s"%s}' "$BOARDS" "$1" "${2:-}" | bp classify
}
checks() { python3 -c 'import json,sys; print(" ".join("%s:%s" % (f["check"], f["severity"]) for f in json.load(sys.stdin)["findings"]))'; }

# personal-path
rm -f "$MINE"
[ "$(bp personal-path)" = "$MINE" ] && ok "the environment names the personal file" || bad "personal-path env -> $(bp personal-path)"
git -C "$TMP" remote add origin https://example.com/Acme/Widgets.git
out="$(cd "$TMP" && env -u DEVSTRIDE_BOARD_PLACEMENT_FILE CLAUDE_CONFIG_DIR="$TMP/conf" python3 "$SC" personal-path)"
[ "$out" = "$TMP/conf/devstride/board-placement/acme__widgets.json" ] && ok "the default personal file is named for the repository's remote" || bad "personal-path default -> $out"
git -C "$TMP" remote set-url origin git@example.com:Acme/Widgets.git
out="$(cd "$TMP" && env -u DEVSTRIDE_BOARD_PLACEMENT_FILE CLAUDE_CONFIG_DIR="$TMP/conf" python3 "$SC" personal-path)"
[ "$out" = "$TMP/conf/devstride/board-placement/acme__widgets.json" ] && ok "an ssh remote names the same file" || bad "personal-path ssh -> $out"

# validate
for c in '{}' '{"boardPlacement": null}'; do
  cfg "$c"; out="$(bp validate)"; rc=$?
  [ "$rc" = 0 ] && [ "$out" = "BOARD PLACEMENT: NOT CONFIGURED" ] && ok "absent or null block, no personal file: not configured ($c)" || bad "$c -> rc=$rc $out"
done
rm -f "$TMP/.claude/ds-config.json"; out="$(bp validate)"
[ "$out" = "BOARD PLACEMENT: NOT CONFIGURED" ] && ok "no config file yet is not configured" || bad "no config -> $out"
cfg "$CYCLES"; out="$(bp validate)"; rc=$?
[ "$rc" = 0 ] && [ "$(first "$out")" = "BOARD PLACEMENT: VALID" ] \
  && [ "$(printf '%s' "$out" | sed -n 2p | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["rules"]), d["personalRules"], d["rules"][0]["source"])')" = "4 0 repository" ] \
  && ok "a full block is valid, every rule marked as the repository's" || bad "full block -> rc=$rc $out"
expect_invalid() { # label config needle
  cfg "$2"; local out rc; out="$(bp validate)"; rc=$?
  if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "$3"; then ok "$1"; else bad "$1 -> rc=$rc $out"; fi
}
expect_invalid "a non-object block is invalid" '{"boardPlacement": "yes"}' "must be an object or null"
expect_invalid "a block without rules is invalid" '{"boardPlacement": {}}' "boardPlacement.rules: must be an array"
expect_invalid "an unknown block key is reported" '{"boardPlacement": {"rules": [], "rule": []}}' "boardPlacement.rule: not a known key"
expect_invalid "a rule without a place is invalid" '{"boardPlacement": {"rules": [{"match": {}}]}}' "rules\[0\].place: must be an object"
expect_invalid "a place naming two homes is invalid" '{"boardPlacement": {"rules": [{"place": {"board": "b", "cycleFolder": "f"}}]}}' "exactly one of"
expect_invalid "an empty place is invalid" '{"boardPlacement": {"rules": [{"place": {}}]}}' "exactly one of"
expect_invalid "none must be true" '{"boardPlacement": {"rules": [{"place": {"none": false}}]}}' "place.none: must be true"
expect_invalid "an empty board id is invalid" '{"boardPlacement": {"rules": [{"place": {"board": " "}}]}}' "place.board: must be a non-empty id"
expect_invalid "an unknown condition is reported" '{"boardPlacement": {"rules": [{"match": {"worktype": ["Story"]}, "place": {"none": true}}]}}' "match.worktype: not a known condition"
expect_invalid "a condition must be a list" '{"boardPlacement": {"rules": [{"match": {"workType": "Story"}, "place": {"none": true}}]}}' "match.workType: must be a non-empty array"
expect_invalid "an empty condition list is invalid" '{"boardPlacement": {"rules": [{"match": {"tag": []}, "place": {"none": true}}]}}' "match.tag: must be a non-empty array"
expect_invalid "under takes item numbers" '{"boardPlacement": {"rules": [{"match": {"under": ["Epic 4"]}, "place": {"none": true}}]}}' "is not an item number"
expect_invalid "a custom field needs values" '{"boardPlacement": {"rules": [{"match": {"customField": {"f1": []}}, "place": {"none": true}}]}}' "match.customField.f1"
expect_invalid "an unknown rule key is reported" '{"boardPlacement": {"rules": [{"plce": {}, "place": {"none": true}}]}}' "rules\[0\].plce: not a known key"
expect_invalid "a rule that places on the Active Agents board is invalid" '{"activeAgents":{"boardId":"agents","commands":{"start":"x <root>","end":"y"}},"boardPlacement":{"rules":[{"name":"Wrong","place":{"board":"agents"}}]}}' "holds plan roots only"
cfg '{"activeAgents":{"boardId":"agents","commands":{"start":"x <root>","end":"y"}},"boardPlacement":{"rules":[{"place":{"none":true}}]}}'
mine '{"rules": [{"name": "Mine", "place": {"board": "agents"}}]}'
out="$(bp validate)"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q "personal rule 'Mine': places items on activeAgents.boardId" && ok "a personal rule that places on the Active Agents board is invalid too" || bad "personal agents -> rc=$rc $out"
rm -f "$MINE"
cfg '{"boardPlacement": {"rules": [{"place": {}}, {"match": {"tag": []}, "place": {"none": false}}]}}'
out="$(bp validate)"; [ "$(first "$out")" = "BOARD PLACEMENT: INVALID (3)" ] && ok "every problem is reported, not just the first" || bad "multi -> $out"
cfg '{"boardPlacement": {"_note": "x", "rules": [{"_why": "y", "match": {"_c": 1}, "place": {"none": true, "_d": 2}}]}}'
[ "$(first "$(bp validate)")" = "BOARD PLACEMENT: VALID" ] && ok "underscore keys are notes, never problems" || bad "underscore keys -> $(bp validate)"
printf 'not json' > "$TMP/.claude/ds-config.json"; bp validate >/dev/null; [ $? = 2 ] && ok "an unreadable config exits 2" || bad "unreadable config"

# personal rules
cfg "$CYCLES"; mine '{"rules": [{"name": "My stories", "match": {"workType": ["Story"]}, "place": {"board": "kanban"}}]}'
out="$(bp validate)"
[ "$(printf '%s' "$out" | sed -n 2p | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["rules"]), d["personalRules"], d["rules"][0]["source"], d["rules"][1]["source"])')" = "5 1 personal repository" ] \
  && ok "personal rules come first, then the repository's" || bad "personal order -> $out"
expect "a personal rule wins over the repository's" '{"workType":"Story","boardId":null}' 2026-01-20 "PLACE MOVE kanban"
expect "a type the personal rule does not name still follows the repository" '{"workType":"Defect","boardId":null}' 2026-01-20 "PLACE MOVE s2"
cfg '{}'; out="$(bp validate)"
[ "$(first "$out")" = "BOARD PLACEMENT: NOT CONFIGURED" ] && printf '%s' "$out" | sed -n 2p | grep -q "^NOTE personal rules in .* are ignored" \
  && ok "personal rules without a repository block are ignored, and said so" || bad "personal only -> $out"
expect "ignored personal rules place nothing" '{"workType":"Story","boardId":null}' 2026-01-20 "PLACE NONE (no board placement rules)"
[ "$(printf '{"boards": [], "date": "2026-01-10"}' | bp classify | python3 -c 'import json,sys; print(" ".join(f["check"] for f in json.load(sys.stdin)["findings"]))')" = "not-configured personal-ignored" ] \
  && ok "doctor is told about ignored personal rules" || bad "classify personal-ignored"
mine '{"rules": [{"place": {}}]}'; cfg "$CYCLES"; out="$(bp validate)"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q "personal rules\[0\].place" && ok "a broken personal file is named as such" || bad "broken personal -> rc=$rc $out"
out="$(resolve '{"workType":"Story","boardId":null}' 2026-01-20)"
[ "$out" = "PLACE UNRESOLVED (the rules are invalid; run validate)" ] && ok "invalid rules place nothing" || bad "invalid resolve -> $out"
printf 'nope' > "$MINE"; bp validate >/dev/null; [ $? = 2 ] && ok "an unreadable personal file exits 2" || bad "unreadable personal"
rm -f "$MINE"

# resolve — cycles
cfg "$CYCLES"
expect "a story with no board goes to the sprint covering the day" '{"workType":"Story","boardId":null}' 2026-01-20 "PLACE MOVE s2 (Sprint 2; repository rule 'Leaves')"
expect "the first day of a cycle is inside it" '{"workType":"Story","boardId":null}' 2026-01-15 "PLACE MOVE s2"
expect "the last day of a cycle is inside it" '{"workType":"Story","boardId":null}' 2026-01-14 "PLACE MOVE s1"
expect "an epic goes to the long cycle in the same day" '{"workType":"Epic","boardId":null}' 2026-01-20 "PLACE MOVE pi1"
expect "a long-lived board sharing the cycle folder is never picked as a cycle" '{"workType":"Epic","boardId":null}' 2026-05-02 "PLACE MOVE pi2"
expect "work type names compare without case" '{"workType":"DEFECT","boardId":null}' 2026-01-20 "PLACE MOVE s2"
expect "an archived cycle board does not count" '{"workType":"Story","boardId":null}' 2026-02-01 "PLACE UNRESOLVED"
expect "a day no cycle covers is unresolved, never a guess" '{"workType":"Story","boardId":null}' 2026-07-01 "PLACE UNRESOLVED (repository rule 'Leaves': no dated board in that folder covers 2026-07-01)"
expect "already on the right board: nothing to do" '{"workType":"Story","boardId":"s2"}' 2026-01-20 "PLACE KEEP (already on Sprint 2)"
expect "a story left on last cycle's board is carried over" '{"workType":"Story","boardId":"s1"}' 2026-01-20 "PLACE MOVE s2 (Sprint 2, carried over from Sprint 1"
expect "a story on the Active Agents board is moved off it" '{"workType":"Story","boardId":"agents"}' 2026-01-20 "PLACE MOVE s2"
expect "a story a person planned into a later cycle stays there" '{"workType":"Story","boardId":"s2"}' 2026-01-10 "PLACE KEEP (on Sprint 2, which a person chose)"
expect "a board a person chose is kept" '{"workType":"Story","boardId":"kanban"}' 2026-01-20 "PLACE KEEP (on Kanban, which a person chose)"
expect "a long cycle is not a carry-over source for a short one" '{"workType":"Story","boardId":"pi1"}' 2026-01-20 "PLACE KEEP (on PI 1"
expect "a board the snapshot lacks is kept" '{"workType":"Story","boardId":"elsewhere"}' 2026-01-20 "PLACE KEEP (on elsewhere"
expect "a Done item never moves" '{"workType":"Story","boardId":null,"done":true}' 2026-01-20 "PLACE KEEP (the item is Done)"
expect "a Done item is kept even on a day no cycle covers" '{"workType":"Story","boardId":"s1","done":true}' 2026-07-01 "PLACE KEEP (the item is Done)"
expect "a type no rule names is not placed" '{"workType":"Capability","boardId":null}' 2026-01-20 "PLACE NONE (no rule matches a Capability)"

# resolve — the other conditions, first match wins
expect "a team rule placed first wins over the type rule" '{"workType":"Story","teamId":"t-ops","boardId":null}' 2026-01-20 "PLACE MOVE kanban (Kanban; repository rule 'Ops work')"
expect "another team falls through" '{"workType":"Story","teamId":"t-dev","boardId":null}' 2026-01-20 "PLACE MOVE s2"
expect "a tag rule can say no board" '{"workType":"Story","tags":["spike","x"],"boardId":null}' 2026-01-20 "PLACE NONE (repository rule 'Spikes' says no board)"
expect "every condition of a rule must hold" '{"workType":"Defect","tags":["spike"],"boardId":null}' 2026-01-20 "PLACE MOVE s2"
expect "no board never takes an item off a board" '{"workType":"Story","tags":["spike"],"boardId":"kanban"}' 2026-01-20 "PLACE NONE"
cfg '{"boardPlacement":{"rules":[
 {"name":"Field","match":{"customField":{"f1":["Platform","Infra"]}},"place":{"board":"kanban"}},
 {"name":"Under","match":{"under":["i42","F7"]},"place":{"board":"old"}},
 {"name":"Rest","place":{"cycleFolder":"sprints"}}]}}'
expect "a custom field value matches" '{"workType":"Story","customFields":{"f1":"platform"},"boardId":null}' 2026-01-20 "PLACE MOVE kanban"
expect "a multi-value custom field matches on any value" '{"workType":"Story","customFields":{"f1":["Web","Infra"]},"boardId":null}' 2026-01-20 "PLACE MOVE kanban"
expect "another field value falls through" '{"workType":"Story","customFields":{"f1":"Web"},"boardId":null}' 2026-01-20 "PLACE MOVE s2"
expect "an item under a named ancestor matches" '{"workType":"Story","ancestors":["I9","I42"],"boardId":null}' 2026-01-20 "PLACE UNRESOLVED (repository rule 'Under' names a board that is missing or archived)"
expect "a rule with no conditions matches everything left" '{"workType":"Anything","boardId":null}' 2026-01-20 "PLACE MOVE s2"
cfg '{"boardPlacement":{"rules":[{"place":{"board":"kanban"}}]}}'
expect "one perpetual board for everything" '{"workType":"Epic","boardId":null}' 2031-09-09 "PLACE MOVE kanban"
cfg '{"activeAgents":{"boardId":"s2","commands":{"start":"x <root>","end":"y"}},"boardPlacement":{"rules":[{"name":"Leaves","place":{"cycleFolder":"sprints"}}]}}'
expect "a cycle that turns out to be the Active Agents board is refused" '{"workType":"Story","boardId":null}' 2026-01-20 "PLACE UNRESOLVED (repository rule 'Leaves' leads to the Active Agents board"
# resolve — cycles that overlap or share a day
ALL="$BOARDS"
BOARDS='[
 {"id":"q1","label":"Quarter 1","boardFolderId":"mix","startDate":"2026-01-01","endDate":"2026-03-31"},
 {"id":"w3","label":"Week 3","boardFolderId":"mix","startDate":"2026-01-15","endDate":"2026-01-21"},
 {"id":"a","label":"Cycle A","boardFolderId":"edge","startDate":"2026-01-01","endDate":"2026-01-14"},
 {"id":"b","label":"Cycle B","boardFolderId":"edge","startDate":"2026-01-14","endDate":"2026-02-03"},
 {"id":"c","label":"Cycle C","boardFolderId":"edge","startDate":"2026-03-01","endDate":"2026-03-14"}]'
cfg '{"boardPlacement":{"rules":[{"name":"Mixed","place":{"cycleFolder":"mix"}}]}}'
expect "the shortest of two overlapping cycles wins" '{"workType":"Story","boardId":null}' 2026-01-20 "PLACE MOVE w3"
expect "a longer cycle still running is a person's choice, never a carry-over" '{"workType":"Story","boardId":"q1"}' 2026-01-20 "PLACE KEEP (on Quarter 1, which a person chose)"
cfg '{"boardPlacement":{"rules":[{"name":"Edge","place":{"cycleFolder":"edge"}}]}}'
expect "absent and null item fields read as none" '{"workType":"Story","tags":null,"ancestors":null,"customFields":null,"done":null,"boardId":null}' 2026-01-20 "PLACE MOVE b"
expect "two cycles sharing a day, the later one longer: the one starting that day wins" '{"workType":"Story","boardId":null}' 2026-01-14 "PLACE MOVE b"
[ "$(classify 2026-01-10 | checks)" = "" ] && ok "a cycle that starts the day the current one ends follows it" || bad "classify shared day -> $(classify 2026-01-10 | checks)"
[ "$(classify 2026-01-20 | checks)" = "no-next-cycle:INFO" ] && ok "a gap after the current cycle is reported even when a later cycle exists" || bad "classify gap -> $(classify 2026-01-20 | checks)"
[ "$(printf '{"boards": %s, "date": "2026-01-14"}' "$BOARDS" | bp current --folder edge)" = "CURRENT b Cycle B" ] && ok "current names a folder's cycle for a day" || bad "current"
[ "$(printf '{"boards": %s, "date": "2026-02-10"}' "$BOARDS" | bp current --folder edge)" = "CURRENT NONE" ] && ok "current says when no cycle covers the day" || bad "current none"
printf '{"boards": [], "date": "2026-02-10"}' | bp current >/dev/null; [ $? = 2 ] && ok "current without a folder exits 2" || bad "current no folder"
cfg '{"activeAgents":{"boardId":"b","commands":{"start":"x <root>","end":"y"}},"boardPlacement":{"rules":[{"name":"Edge","place":{"cycleFolder":"edge"}}]}}'
out="$(classify 2026-01-20)"
[ "$(printf '%s' "$out" | checks)" = "rule-board:FAIL" ] && printf '%s' "$out" | grep -q "Active Agents board" && ok "a folder whose cycle today is the Active Agents board is a failure" || bad "classify agents cycle -> $out"
BOARDS="$ALL"
cfg '{"boardPlacement":{"rules":[{"name":"All","match":{"_note":"everything"},"place":{"board":"kanban"}},{"name":"Late","match":{"workType":["Story"]},"place":{"none":true}}]}}'
[ "$(classify 2026-01-10 | checks)" = "unreachable:INFO" ] && ok "a rule whose match holds only a note still matches everything" || bad "classify note-only -> $(classify 2026-01-10 | checks)"
cfg '{}'
expect "nothing configured places nothing" '{"workType":"Story","boardId":null}' 2026-01-20 "PLACE NONE (no board placement rules)"

# resolve — unusable input
cfg "$CYCLES"
printf 'x' | bp resolve >/dev/null; [ $? = 2 ] && ok "stdin that is not JSON exits 2" || bad "bad stdin"
printf '{"item": {}, "boards": [], "date": "2026-01-01"}' | bp resolve >/dev/null; [ $? = 2 ] && ok "an item without a work type exits 2" || bad "no work type"
printf '{"item": {"workType": "Story"}, "boards": [], "date": "soon"}' | bp resolve >/dev/null; [ $? = 2 ] && ok "a date that is not a date exits 2" || bad "bad date"
printf '{"item": {"workType": "Story"}, "boards": [{"label": "x"}], "date": "2026-01-01"}' | bp resolve >/dev/null; [ $? = 2 ] && ok "a board without an id exits 2" || bad "board without id"
for bad_item in '{"workType":"Story","tags":"spike"}' '{"workType":"Story","tags":[5]}' '{"workType":"Story","ancestors":[{"itemNumber":"I42"}]}' \
    '{"workType":"Story","boardId":{"id":"kanban"}}' '{"workType":"Story","done":"false"}' '{"workType":"Story","customFields":[]}'; do
  out="$(printf '{"item": %s, "boards": [], "date": "2026-01-01"}' "$bad_item" | bp resolve)"; rc=$?
  [ "$rc" = 2 ] && printf '%s' "$out" | grep -q '"error"' && ok "a wrong-shaped item field exits 2 with one error line ($bad_item)" || bad "$bad_item -> rc=$rc $out"
done
out="$(printf '{"item": {"workType": "Story"}, "boards": %s, "date": "2026-01-20T08:00:00Z"}' "$BOARDS" | bp resolve)"
case "$out" in "PLACE MOVE s2"*) ok "a timestamp is read as its day" ;; *) bad "timestamp -> $out" ;; esac

# classify
cfg '{}'
[ "$(classify 2026-01-10 | checks)" = "not-configured:INFO" ] && ok "nothing configured is INFO, never a failure" || bad "classify unconfigured -> $(classify 2026-01-10)"
cfg "$CYCLES"
[ "$(classify 2026-01-10 ', "placedTypes": ["Epic","Story","Defect"], "workTypes": ["Epic","Story","Defect","Capability"], "teams": ["t-ops"], "tags": ["spike"]' | checks)" = "" ] && ok "a healthy set of rules has no findings" || bad "classify clean -> $(classify 2026-01-10 ', "placedTypes": ["Epic","Story","Defect"], "workTypes": ["Epic","Story","Defect","Capability"], "teams": ["t-ops"], "tags": ["spike"]')"
[ "$(classify 2026-01-20 | checks)" = "no-next-cycle:INFO" ] && ok "the last cycle of a folder: the next one does not exist yet (INFO)" || bad "classify next -> $(classify 2026-01-20 | checks)"
[ "$(classify 2026-02-01 | checks)" = "no-current-cycle:FAIL" ] && ok "no cycle covering today is a failure" || bad "classify current -> $(classify 2026-02-01 | checks)"
out="$(classify 2026-07-04 | checks)"
[ "$out" = "no-current-cycle:FAIL no-current-cycle:FAIL" ] && ok "each cycle folder is reported once" || bad "classify both folders -> $out"
out="$(classify 2026-01-10 ', "placedTypes": ["Epic","Story","Task"], "workTypes": ["Epic","Defect"], "teams": [], "tags": []')"
[ "$(printf '%s' "$out" | checks)" = "unknown-team:FAIL unknown-worktype:FAIL unknown-tag:FAIL unknown-worktype:FAIL uncovered-type:FAIL" ] \
  && printf '%s' "$out" | grep -q 'no rule says where these go: Task' \
  && ok "unknown teams, types and tags are failures; an unanswered type is named" || bad "classify unknown -> $out"
cfg '{"boardPlacement":{"rules":[
 {"name":"A","match":{"customField":{"f9":["x"]}},"place":{"board":"old"}},
 {"name":"B","match":{"workType":["Story"]},"place":{"board":"gone"}},
 {"name":"C","match":{"workType":["Epic"]},"place":{"cycleFolder":"ops"}},
 {"name":"D","place":{"none":true}},
 {"name":"E","match":{"workType":["Defect"]},"place":{"board":"kanban"}}]}}'
out="$(classify 2026-01-10 ', "placedTypes": ["Epic","Story","Defect"], "customFields": ["f1"]')"
[ "$(printf '%s' "$out" | checks)" = "unknown-field:FAIL rule-board:FAIL rule-board:FAIL rule-folder:FAIL unreachable:INFO" ] \
  && printf '%s' "$out" | grep -q "names a board that is archived" && printf '%s' "$out" | grep -q "names a board that is missing" \
  && ok "archived and missing boards, a folder with no cycles, an unknown field and a rule nothing reaches" || bad "classify boards -> $out"
cfg "$CYCLES"; mine '{"rules": [{"name": "My stories", "match": {"workType": ["Story"]}, "place": {"board": "kanban"}}]}'
out="$(classify 2026-01-10)"
[ "$(printf '%s' "$out" | checks)" = "personal:INFO" ] && printf '%s' "$out" | grep -q "1 personal rule" && ok "personal rules in effect are reported (INFO)" || bad "classify personal -> $out"
mine '{"rules": [{"place": {}}]}'
[ "$(classify 2026-01-10 | checks)" = "invalid:FAIL" ] && ok "invalid rules are one failure each" || bad "classify invalid -> $(classify 2026-01-10)"
rm -f "$MINE"
printf '{"boards": 4, "date": "2026-01-01"}' | bp classify >/dev/null; [ $? = 2 ] && ok "boards that are not a list exit 2" || bad "classify bad boards"
(cd "$TMP" && python3 "$SC" nonsense >/dev/null); [ $? = 2 ] && ok "an unknown subcommand exits 2" || bad "unknown subcommand"

[ "$FAIL" = 0 ] && echo "PASS board-placement.sh" || echo "FAIL board-placement.sh"
exit "$FAIL"
