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
J="$(scope --base main --round1 "$R1")"; S1="$(printf '%s' "$J" | field 'd["scope"]')"
if [ "$S1" = delta ] && [ "$(printf '%s' "$J" | field 'd["delta"]["files"]')" = 2 ] && [ "$(printf '%s' "$J" | field 'd["round1"]["files"]')" = 14 ] && [ "$(printf '%s' "$J" | field 'd["delta"]["bytes"] <= 0.5*d["round1"]["bytes"]')" = True ]; then ok "(1) two-file fix inside round 1 → delta ($(printf '%s' "$J" | field 'd["delta"]["bytes"]') B of $(printf '%s' "$J" | field 'd["round1"]["bytes"]') B, 2 of 14 files)"; else bad "(1) $J"; fi

# (2) a fix adding a file round 1 never touched → full: new-file
echo new > "$TMP/r/extra.txt"; g add -A; g commit -qm "fix adds a file"
J="$(scope --base main --round1 "$R1")"
if [ "$(printf '%s' "$J" | field 'd["scope"]')" = full ] && printf '%s' "$J" | grep -q '"reason":"new-file extra.txt' ; then ok "(2) new file in the fix → full: new-file extra.txt"; else bad "(2) $J"; fi
g reset -q --hard "HEAD~1"

# (3) a fix rewriting > 50% of round-1 lines (4 files fully rewritten: 32 of 56 = 57%) → full
for i in 1 2 3 4; do printf 'R %d-a\nR %d-b\nR %d-c\nR %d-d\n' $i $i $i $i > "$TMP/r/f$i.txt"; done; g commit -qam "rewrite four files"
J="$(scope --base main --round1 "$R1")"
if [ "$(printf '%s' "$J" | field 'd["scope"]')" = full ] && printf '%s' "$J" | grep -q '"reason":"delta [0-9]* of [0-9]* lines (> 50%)"'; then ok "(3) > 50% of round-1 lines rewritten → full ($(printf '%s' "$J" | field 'd["reason"]'))"; else bad "(3) $J"; fi

# (6) --threshold 0.9 turns case 3 into delta — the threshold is a parameter, the rule is fixed
J="$(scope --base main --round1 "$R1" --threshold 0.9)"
if [ "$(printf '%s' "$J" | field 'd["scope"]')" = delta ]; then ok "(6) the same 57% rewrite with --threshold 0.9 → delta"; else bad "(6) $J"; fi
g reset -q --hard "$R1"

# (4) no fix commit → none
J="$(scope --base main --round1 "$R1")"
if [ "$(printf '%s' "$J" | field 'd["scope"]')" = none ] && [ "$(printf '%s' "$J" | field 'd["delta"]["files"]')" = 0 ]; then ok "(4) HEAD == round1 → none"; else bad "(4) $J"; fi

# (5) a rename inside the fix whose source was a round-1 file → delta (both sides matched)
g mv f3.txt f3-renamed.txt && g commit -qm "rename a round-1 file"
J="$(scope --base main --round1 "$R1")"
if [ "$(printf '%s' "$J" | field 'd["scope"]')" = delta ] && [ "$(printf '%s' "$J" | field 'len(d["newFiles"])')" = 0 ]; then ok "(5) rename of a round-1 file → delta, no new file"; else bad "(5) $J"; fi
g reset -q --hard "$R1"

# (7) a rebase moved the patch → full: history-rewritten
g checkout -q main && echo more >> "$TMP/r/README.md" && g commit -qam "main moves" && g checkout -q story && g rebase -q main >/dev/null 2>&1
J="$(scope --base main --round1 "$R1")"
if [ "$(printf '%s' "$J" | field 'd["scope"]')" = full ] && printf '%s' "$J" | grep -q history-rewritten; then ok "(7) round-1 head no longer an ancestor → full: history-rewritten"; else bad "(7) $J"; fi

# (8) usage: an unknown ref and a bad threshold are exit 2 with a JSON line
J="$(scope --base main --round1 deadbeef 2>&1)"; RC=$?; [ "$RC" -eq 2 ] && printf '%s' "$J" | grep -q usage-error && ok "(8) unknown --round1 → usage-error, exit 2" || bad "(8) rc=$RC $J"
J="$(scope --base main --round1 "$R1" --threshold half 2>&1)"; RC=$?; [ "$RC" -eq 2 ] && ok "(8b) non-numeric --threshold → exit 2" || bad "(8b) rc=$RC $J"
exit $FAIL
