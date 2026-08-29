#!/bin/bash
# Tests for skills/review/scripts/rereview-scope.sh — a throwaway repo per run, no network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; SC="$ROOT/skills/review/scripts/rereview-scope.sh"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
g() { git -C "$TMP/r" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
mkdir "$TMP/r" && g init -q -b main && echo base > "$TMP/r/README.md" && g add -A && g commit -qm base
g checkout -qb story
for i in $(seq 1 14); do printf 'line %d-a\nline %d-b\nline %d-c\nline %d-d\n' $i $i $i $i > "$TMP/r/f$i.txt"; done
g add -A && g commit -qm "story: 14 files" && R1="$(g rev-parse HEAD)"
scope() { (cd "$TMP/r" && /bin/bash "$SC" "$@"); }
field() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }

# (1) a two-file fix touching only round-1 files → delta
printf 'line 1-a\nline 1-b FIXED\nline 1-c\nline 1-d\n' > "$TMP/r/f1.txt"; printf 'line 2-a FIXED\nline 2-b\nline 2-c\nline 2-d\n' > "$TMP/r/f2.txt"; g commit -qam "fix two files"
J="$(scope --base main --reviewed-head "$R1")"; S1="$(printf '%s' "$J" | field 'd["scope"]')"
if [ "$S1" = delta ] && [ "$(printf '%s' "$J" | field 'd["delta"]["files"]')" = 2 ] && [ "$(printf '%s' "$J" | field 'd["reviewed"]["files"]')" = 14 ] && [ "$(printf '%s' "$J" | field 'd["delta"]["lines"] <= 0.5*d["reviewed"]["lines"]')" = True ] && [ "$(printf '%s' "$J" | field 'd["delta"]["lines"]')" = 4 ] && [ "$(printf '%s' "$J" | field 'd["reviewed"]["lines"]')" = 56 ]; then ok "(1) two-file fix inside round 1 → delta (4 of 56 lines, 2 of 14 files, $(printf '%s' "$J" | field 'd["delta"]["bytes"]') B)"; else bad "(1) $J"; fi

# (1b) a later safety cycle scopes from the immediately preceding reviewed head, not cycle 1
R2="$(g rev-parse HEAD)"; sed 's/FIXED/FIXED AGAIN/' "$TMP/r/f1.txt" > "$TMP/r/f1.next" && mv "$TMP/r/f1.next" "$TMP/r/f1.txt" && g commit -qam "second-cycle critical fix"
J="$(scope --base main --reviewed-head "$R2")"
if [ "$(printf '%s' "$J" | field 'd["scope"]')" = delta ] && [ "$(printf '%s' "$J" | field 'd["reviewedHead"]')" = "$R2" ] && [ "$(printf '%s' "$J" | field 'd["delta"]["lines"]')" = 2 ]; then ok "(1b) cycle N uses the prior cycle anchor → delta (2 lines)"; else bad "(1b) $J"; fi
g reset -q --hard "$R2"

# (2) a fix adding a file round 1 never touched → full: new-file
echo new > "$TMP/r/extra.txt"; g add -A; g commit -qm "fix adds a file"
J="$(scope --base main --reviewed-head "$R1")"
if [ "$(printf '%s' "$J" | field 'd["scope"]')" = full ] && printf '%s' "$J" | grep -q '"reason":"new-file extra.txt' ; then ok "(2) new file in the fix → full: new-file extra.txt"; else bad "(2) $J"; fi
g reset -q --hard "HEAD~1"

# (3) a fix rewriting > 50% of round-1 lines (4 files fully rewritten: 32 of 56 = 57%) → full
for i in 1 2 3 4; do printf 'R %d-a\nR %d-b\nR %d-c\nR %d-d\n' $i $i $i $i > "$TMP/r/f$i.txt"; done; g commit -qam "rewrite four files"
J="$(scope --base main --reviewed-head "$R1")"
if [ "$(printf '%s' "$J" | field 'd["scope"]')" = full ] && printf '%s' "$J" | grep -q '"reason":"delta [0-9]* of [0-9]* lines (> 50%)"'; then ok "(3) > 50% of round-1 lines rewritten → full ($(printf '%s' "$J" | field 'd["reason"]'))"; else bad "(3) $J"; fi

# (6) --threshold 0.9 turns case 3 into delta — the threshold is a parameter, the rule is fixed
J="$(scope --base main --reviewed-head "$R1" --threshold 0.9)"
if [ "$(printf '%s' "$J" | field 'd["scope"]')" = delta ]; then ok "(6) the same 57% rewrite with --threshold 0.9 → delta"; else bad "(6) $J"; fi
g reset -q --hard "$R1"

# (4) no fix commit → none
J="$(scope --base main --reviewed-head "$R1")"
if [ "$(printf '%s' "$J" | field 'd["scope"]')" = none ] && [ "$(printf '%s' "$J" | field 'd["delta"]["files"]')" = 0 ]; then ok "(4) HEAD == reviewed head → none"; else bad "(4) $J"; fi

# (5) a rename inside the fix whose source was a round-1 file → delta (both sides matched)
g mv f3.txt f3-renamed.txt && g commit -qm "rename a round-1 file"
J="$(scope --base main --reviewed-head "$R1")"
if [ "$(printf '%s' "$J" | field 'd["scope"]')" = delta ] && [ "$(printf '%s' "$J" | field 'len(d["newFiles"])')" = 0 ]; then ok "(5) rename of a round-1 file → delta, no new file"; else bad "(5) $J"; fi
g reset -q --hard "$R1"

# (5b) a fix MOVING a round-1 file into a subdirectory (git's brace form `{ => sub}/f4.txt`) → delta
mkdir -p "$TMP/r/sub" && g mv f4.txt sub/f4.txt && printf 'line 4-a FIXED\nline 4-b\nline 4-c\nline 4-d\n' > "$TMP/r/sub/f4.txt" && g commit -qam "move a round-1 file into a subdirectory"
J="$(scope --base main --reviewed-head "$R1")"
if [ "$(printf '%s' "$J" | field 'd["scope"]')" = delta ] && [ "$(printf '%s' "$J" | field 'len(d["newFiles"])')" = 0 ]; then ok "(5b) move of a round-1 file into a subdirectory → delta, no new file"; else bad "(5b) $J"; fi
g reset -q --hard "$R1"

# (5c) round 1 itself moved a file out of a subdirectory; the fix edits the moved file → delta
g checkout -q main && mkdir -p "$TMP/r/deep" && printf 'm1\nm2\nm3\nm4\nm5\nm6\n' > "$TMP/r/deep/moved.txt" && g add -A && g commit -qm "main: a file in deep/" && g checkout -qb story2
g mv deep/moved.txt moved.txt && printf 'M1\nM2\nM3\nm4\nm5\nm6\n' > "$TMP/r/moved.txt" && g commit -qam "story2: move deep/moved.txt out, edit 3 lines" && R1B="$(g rev-parse HEAD)"
printf 'M1\nM2\nM3\nm4\nm5\nM6\n' > "$TMP/r/moved.txt" && g commit -qam "fix one line of the moved file"
J="$(scope --base main --reviewed-head "$R1B")"
if [ "$(printf '%s' "$J" | field 'd["scope"]')" = delta ] && [ "$(printf '%s' "$J" | field 'len(d["newFiles"])')" = 0 ]; then ok "(5c) round 1 moved a file out of a subdirectory; a fix to it → delta"; else bad "(5c) $J"; fi
# (5d) round 1 renamed a file; the fix RECREATES the old path → that is a new file → full
g checkout -q story2 && echo fresh > "$TMP/r/deep/moved.txt" && g add -A && g commit -qm "fix recreates the old path"
J="$(scope --base main --reviewed-head "$R1B")"
if [ "$(printf '%s' "$J" | field 'd["scope"]')" = full ] && printf '%s' "$J" | grep -q '"reason":"new-file deep/moved.txt'; then ok "(5d) fix recreates a path round 1 renamed away → full: new-file"; else bad "(5d) $J"; fi
g checkout -q story

# (5e) round 1 was a PURE rename (zero changed lines); a fix that rewrites the file → full (any delta > 50% of 0)
g checkout -q main && g checkout -qb story3 && g mv README.md README-moved.md && g commit -qm "story3: pure rename" && R1C="$(g rev-parse HEAD)"
echo rewritten > "$TMP/r/README-moved.md" && g commit -qam "fix rewrites the renamed file"
J="$(scope --base main --reviewed-head "$R1C")"
if [ "$(printf '%s' "$J" | field 'd["scope"]')" = full ] && printf '%s' "$J" | grep -q '"reason":"delta [0-9]* of 0 lines'; then ok "(5e) zero-line round 1, any rewrite → full"; else bad "(5e) $J"; fi
g checkout -q story

# (5f) a filename containing a TAB is kept whole, so a new tabbed file is still new → full
printf 'x\n' > "$TMP/r/tab	new.txt" && g add -A && g commit -qm "fix adds a file with a tab in its name"
J="$(scope --base main --reviewed-head "$R1")"
if [ "$(printf '%s' "$J" | field 'd["scope"]')" = full ] && [ "$(printf '%s' "$J" | field 'd["newFiles"][0]')" = "tab	new.txt" ]; then ok "(5f) tab in a filename survives numstat parsing → full: new-file"; else bad "(5f) $J"; fi
g reset -q --hard "$R1"

# (9) a fix touching a non-UTF-8 text file still decides, exit 0, one JSON line
printf 'line 5-a caf\351\nline 5-b\nline 5-c\nline 5-d\n' > "$TMP/r/f5.txt" && g commit -qam "latin-1 byte in a fix"
J="$(scope --base main --reviewed-head "$R1" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$J" | field 'd["scope"]')" = delta ]; then ok "(9) non-UTF-8 byte in the delta → still a decision (delta), exit 0"; else bad "(9) rc=$RC $J"; fi
g reset -q --hard "$R1"

# (10) a path round 1 DELETED is not a round-1 file: a fix recreating it → full: new-file
g rm -q f6.txt && g commit -qm "story: delete f6" && R1D="$(g rev-parse HEAD)"
echo back > "$TMP/r/f6.txt" && g add -A && g commit -qm "fix recreates the deleted file"
J="$(scope --base main --reviewed-head "$R1D")"
if [ "$(printf '%s' "$J" | field 'd["scope"]')" = full ] && printf '%s' "$J" | grep -q '"reason":"new-file f6.txt'; then ok "(10) fix recreates a path round 1 deleted → full: new-file"; else bad "(10) $J"; fi
g reset -q --hard "$R1"

# (7) a rebase moved the patch → full: history-rewritten
g checkout -q main && echo more >> "$TMP/r/README.md" && g commit -qam "main moves" && g checkout -q story && g rebase -q main >/dev/null 2>&1
J="$(scope --base main --reviewed-head "$R1")"
if [ "$(printf '%s' "$J" | field 'd["scope"]')" = full ] && printf '%s' "$J" | grep -q history-rewritten; then ok "(7) reviewed head no longer an ancestor → full: history-rewritten"; else bad "(7) $J"; fi

# (8) usage: an unknown ref and a bad threshold are exit 2 with a JSON line
J="$(scope --base main --reviewed-head deadbeef 2>&1)"; RC=$?; [ "$RC" -eq 2 ] && printf '%s' "$J" | grep -q usage-error && ok "(8) unknown --reviewed-head → usage-error, exit 2" || bad "(8) rc=$RC $J"
J="$(scope --base main --reviewed-head "$R1" --threshold half 2>&1)"; RC=$?; [ "$RC" -eq 2 ] && ok "(8b) non-numeric --threshold → exit 2" || bad "(8b) rc=$RC $J"
J="$(scope --base main --reviewed-head "$R1" --threshold 1.2.3 2>&1)"; RC=$?; [ "$RC" -eq 2 ] && printf '%s' "$J" | grep -q usage-error && ok "(8c) --threshold 1.2.3 → usage-error, exit 2 (no traceback)" || bad "(8c) rc=$RC $J"
J="$(scope --base main --reviewed-head "$R1" --threshold 0 2>&1)"; RC=$?; [ "$RC" -eq 2 ] && ok "(8d) --threshold 0 → exit 2 (must be in (0, 1])" || bad "(8d) rc=$RC $J"
exit $FAIL
