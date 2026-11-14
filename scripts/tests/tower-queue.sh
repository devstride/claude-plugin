#!/bin/bash
# Tests for skills/release/scripts/tower-queue.py — scope merge-and-deploy's queue rule: claim the
# tower only while no OTHER release pull request is open into production. The provider's
# `status --json` is a fake command reading a file. No network; nothing outside a private TMPDIR.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; Q="$ROOT/skills/release/scripts/tower-queue.py"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/repo/.claude"; cd "$WORK/repo" || exit 1
printf '#!/bin/bash\n[ "$1" = --json ] || exit 9\ncat "%s/status.json"\nexit "$(cat "%s/status.rc" 2>/dev/null || echo 0)"\n' "$WORK" "$WORK" > "$WORK/status"; chmod +x "$WORK/status"
printf '{"release": {"clearance": {"scope": "merge-and-deploy", "commands": {"claim": "c", "status": "%s/status", "heartbeat": "h", "release": "r", "adopt": "a"}}}}' "$WORK" > .claude/ds-config.json
st() { printf '%s' "$1" > "$WORK/status.json"; printf '%s' "${2:-0}" > "$WORK/status.rc"; }
run() { OUT="$(python3 "$Q" "$@" 2>&1)"; RC=$?; }

st '{"state": "clear", "derived": true, "onFinal": null, "waiting": []}'; run check
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^CLEAR (no other release pull request is open)$'; then ok "(1) no open release pull request → CLEAR"; else bad "(1) rc=$RC: $OUT"; fi

st '{"state": "clear", "derived": true, "onFinal": {"number": 41, "head": "release/26-10-18", "draft": false}, "waiting": []}'
run check --own-pr 41; A="$RC:$OUT"; run check; B="$RC:$OUT"
if [ "${A%%:*}" -eq 0 ] && printf '%s' "$A" | grep -q "^0:CLEAR (no release pull request older than #41 is open)" \
   && [ "${B%%:*}" -eq 2 ] && printf '%s' "$B" | grep -q '^2:WAIT #41 release/26-10-18 '; then
  ok "(2) only our own pull request on final with --own-pr → CLEAR; without it → WAIT #41"
else bad "(2) a=$A b=$B"; fi

st '{"state": "held", "derived": true, "onFinal": {"number": 41, "head": "release/26-10-18"}, "waiting": [{"number": 44, "head": "release/26-10-18-2"}]}'
run check --own-pr 44
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q '^WAIT #41 release/26-10-18 '; then ok "(3) another release pull request open ahead of ours → WAIT #41"; else bad "(3) rc=$RC: $OUT"; fi

# (3b) a NEWER release pull request (cut by hand beside ours) does not hold ours: first cut, first merged
st '{"state": "clear", "derived": true, "onFinal": {"number": 44, "head": "release/26-10-18-2"}, "waiting": [{"number": 41, "head": "release/26-10-18"}]}'
run check --own-pr 41; A="$RC:$OUT"; run check --own-pr 44; B="$RC:$OUT"
if printf '%s' "$A" | grep -q '^0:CLEAR' && printf '%s' "$B" | grep -q '^2:WAIT #41 '; then ok "(3b) only an OLDER release pull request is ahead: #41 CLEAR beside #44, #44 WAITs for #41"; else bad "(3b) a=$A b=$B"; fi

st '{"state": "clear", "derived": true, "onFinal": null, "waiting": [], "hotfixesLanded": [{"number": 50, "head": "a/hotfix/26-10-18/x", "mergedAt": "2026-10-18T10:00:00Z"}]}'
run check
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^CLEAR'; then ok "(4) a hotfix never queues a release → CLEAR"; else bad "(4) rc=$RC: $OUT"; fi

st '{"state": "unknown", "error": "the store could not be read"}' 1; run check; A="$RC:$OUT"
st '{"state": "clear", "derived": false, "onFinal": null, "waiting": []}'; run check; B="$RC:$OUT"
st 'not json'; run check; C="$RC:$OUT"
if printf '%s' "$A" | grep -q '^2:WAIT status unreadable (the store could not be read)' && printf '%s' "$B" | grep -q '^2:WAIT status unreadable (its release pull requests were not derived)' \
   && printf '%s' "$C" | grep -q '^2:WAIT status unreadable'; then
  ok "(5) UNKNOWN, not derived, or unparsable status → WAIT, never CLEAR"
else bad "(5) a=$A b=$B c=$C"; fi

# (7) waited staleMinutes behind another release pull request → ASK once (exit 3), naming it; under
#     the threshold, or with no other pull request open, it is WAIT or CLEAR as before
st '{"state": "clear", "derived": true, "onFinal": {"number": 41, "head": "release/26-10-18"}, "waiting": []}'
run check --own-pr 44 --waited-minutes 19; A="$RC:$OUT"; run check --own-pr 44 --waited-minutes 20; B="$RC:$OUT"
run check --own-pr 41 --waited-minutes 90; C="$RC:$OUT"; run check --waited-minutes soon; D="$RC:$OUT"
if printf '%s' "$A" | grep -q '^2:WAIT #41 ' && printf '%s' "$B" | grep -q '^3:ASK #41 release/26-10-18 (this release has waited 20 min behind it' \
   && printf '%s' "$C" | grep -q '^0:CLEAR' && printf '%s' "$D" | grep -q '^1:ERROR --waited-minutes'; then
  ok "(7) --waited-minutes ≥ staleMinutes (default 20) behind another pull request → ASK (exit 3); below it WAIT; our own → CLEAR; a bad value → ERROR"
else bad "(7) a=$A b=$B c=$C d=$D"; fi

printf '{"release": {}}' > .claude/ds-config.json; run check; A="$RC:$OUT"; run check --own-pr x; B="$RC:$OUT"
if [ "${A%%:*}" -eq 1 ] && printf '%s' "$A" | grep -q '^1:ERROR release.clearance is not set' && [ "${B%%:*}" -eq 1 ]; then
  ok "(6) no release.clearance or a bad --own-pr → ERROR, exit 1"
else bad "(6) a=$A b=$B"; fi

exit $FAIL
