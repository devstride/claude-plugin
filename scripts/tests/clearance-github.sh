#!/bin/bash
# Tests for skills/release/scripts/clearance-github.sh — the built-in release clearance provider.
# The ref lives in a REAL bare repository (the compare-and-swap is git's own); a fake `gh`
# (scripts/tests/fixtures/clearance/fake-gh.py) serves the pull-request facts and the user name.
# No network; nothing outside a private TMPDIR; no keeper process unless a case starts one.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; P="$ROOT/skills/release/scripts/clearance-github.sh"
FX="$ROOT/scripts/tests/fixtures/clearance"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"; printf '#!/bin/bash\nexec python3 "%s/fake-gh.py" "$@"\n' "$FX" > "$WORK/bin/gh"; chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH" HOME="$WORK/home" GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1; mkdir -p "$HOME"
printf '[user]\n\tname = t\n\temail = t@t\n' > "$GIT_CONFIG_GLOBAL"
export CLEARANCE_NO_KEEPER=1

# fresh NAME — a bare origin with a production branch, a work checkout, a fake-gh state
# directory and a local record path; the provider then runs as session me-1.
fresh() {
  STATE="$WORK/$1"; rm -rf "$STATE"; mkdir -p "$STATE"
  git init -q --bare "$STATE/origin.git"
  git init -q -b master "$STATE/work" 2>/dev/null || { git init -q "$STATE/work"; git -C "$STATE/work" checkout -q -b master; }
  git -C "$STATE/work" commit -q --allow-empty -m init
  git -C "$STATE/work" remote add origin "$STATE/origin.git"
  DEVSTRIDE_MERGE_GUARD=0 git -C "$STATE/work" push -q origin master 2>/dev/null
  cd "$STATE/work" || exit 1
  export FAKE_GH_STATE="$STATE" CLEARANCE_RECORD="$WORK/$1.record.json" CLEARANCE_REPO=o/r \
         CLEARANCE_PRODUCTION_BRANCH=master CLEARANCE_RELEASE_PATTERN='release/<YY-MM-DD>[-n]' \
         CLEARANCE_POLL_SECONDS=1 CLEARANCE_WAIT_MINUTES=1 CLEARANCE_STALE_MINUTES=20 \
         CLEARANCE_NOW=2026-10-18T10:05:00Z CLAUDE_CODE_SESSION_ID=me-1
  unset DEVSTRIDE_LEASE_TOKEN CODEX_THREAD_ID CLEARANCE_PHASE_BUDGETS
  rm -f "$CLEARANCE_RECORD" "$WORK/$1.record.owed.json"
}
# seed JSON — the ref points at a tag object carrying JSON (replacing whatever was there)
seed() {
  local head sha
  head="$(git rev-parse HEAD)"
  sha="$(printf 'object %s\ntype commit\ntag release-clearance\ntagger t <t@t> 1 +0000\n\n%s\n' "$head" "$1" | git hash-object -t tag -w --stdin)"
  git push -q origin ":refs/clearance/release" 2>/dev/null
  git push -q origin "${sha}:refs/clearance/release"
}
# held HOLDER PHASE BRANCH PR [HEARTBEAT] [PHASE_STARTED] — a clearance held by someone else
held() {
  local pr="null"; [ "$4" != "-" ] && pr="$4"
  local branch="null"; [ "$3" != "-" ] && branch="\"$3\""
  local started=""; [ -n "${6:-}" ] && started="$(printf ',"phaseStartedAt":"%s"' "$6")"
  seed "$(printf '{"v":1,"repo":"o/r","holder":"%s","user":"bob","machine":"m9","purpose":"release","phase":"%s","branch":%s,"pr":%s,"takenAt":"2026-10-18T09:50:00Z","heartbeatAt":"%s"%s}' \
    "$1" "$2" "$branch" "$pr" "${5:-2026-10-18T10:00:00Z}" "$started")"
}
refsha() { git ls-remote origin refs/clearance/release | cut -f1; }
record() { # record FIELD — read from the ref's tag object on origin
  local sha; sha="$(refsha)"; [ -n "$sha" ] || { echo "<no ref>"; return; }
  git fetch -q origin refs/clearance/release 2>/dev/null
  git cat-file -p "$sha" | sed -n '/^$/,$p' | tail -n +2 | python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1" 2>/dev/null
}
run() { OUT="$(bash "$P" "$@" 2>&1)"; RC=$?; }

# (1) a claim on a clear ref wins: CLEARED, the ref exists, the local record names the repo, 0600
fresh one
run claim --purpose release
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^CLEARED claude:me-1 2026-10-18T10:05:00Z' && [ -n "$(refsha)" ] \
   && [ "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["repo"], d["holder"])' "$CLEARANCE_RECORD")" = "o/r claude:me-1" ] \
   && [ "$(stat -c %a "$CLEARANCE_RECORD" 2>/dev/null || stat -f %Lp "$CLEARANCE_RECORD")" = 600 ] \
   && [ "$(record phase)" = claimed ] && [ "$(record user)" = alice ] && [ "$(git branch -a | grep -c clearance)" = 0 ] && [ "$(git tag | wc -l | tr -d ' ')" = 0 ]; then
  ok "(1) claim wins → CLEARED <holder> <takenAt>; ref created (no branch, no tag listed); local record {repo, holder} mode 0600"
else bad "(1) rc=$RC: $OUT"; fi

# (2) a second claim by the same session is idempotent
run claim
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'already held by this session'; then ok "(2) claiming again from the holder session is CLEARED, not BUSY"; else bad "(2) rc=$RC: $OUT"; fi

# (3) a claim while another fresh session holds it: BUSY with the holder line, exit 2, nothing pushed
fresh two; held claude:other review release/26-10-18 3981; BEFORE="$(refsha)"
run claim
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q '^BUSY held by bob on m9 since 2026-10-18T09:50:00Z, phase review, heartbeat 5 min ago — release/26-10-18 #3981$' \
   && [ "$(refsha)" = "$BEFORE" ] && [ ! -f "$CLEARANCE_RECORD" ]; then
  ok "(3) claim loses → BUSY held by <user> on <machine> since …, phase, heartbeat age; exit 2; ref untouched"
else bad "(3) rc=$RC: $OUT"; fi

# (4) a lost race: another claimant lands between this one's read and its push. A pre-receive
#     hook on origin declines the claimant's pushes while the ref is absent (a hook cannot move a
#     ref itself), and a side process creates the other claimant's ref the moment the first push
#     was declined; the claimant's loop re-reads, finds the winner, and reports BUSY.
fresh race
cat > "$STATE/origin.git/hooks/pre-receive" <<HOOK
#!/bin/bash
if [ -f "$STATE/race-armed" ] && ! git rev-parse -q --verify refs/clearance/release >/dev/null; then
  : > "$STATE/race-declined"; echo "another claimant is landing" >&2; exit 1
fi
exit 0
HOOK
chmod +x "$STATE/origin.git/hooks/pre-receive"
HEAD="$(git rev-parse HEAD)"
RSHA="$(printf 'object %s\ntype commit\ntag release-clearance\ntagger t <t@t> 1 +0000\n\n{"v":1,"holder":"claude:other","user":"bob","machine":"m9","phase":"claimed","branch":null,"pr":null,"takenAt":"2026-10-18T10:04:00Z","heartbeatAt":"2026-10-18T10:04:00Z"}\n' "$HEAD" | git hash-object -t tag -w --stdin)"
git push -q origin "${RSHA}:refs/race-seed/x"   # the object must exist on origin
: > "$STATE/race-armed"
( until [ -f "$STATE/race-declined" ]; do sleep 0.05; done; git -C "$STATE/origin.git" update-ref refs/clearance/release "$RSHA"; rm -f "$STATE/race-armed" ) &
run claim
wait
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q '^BUSY held by bob' && [ "$(refsha)" = "$RSHA" ] && [ -f "$STATE/race-declined" ]; then
  ok "(4) the ref appears under a claimant → its push is rejected by the lease; it loses with BUSY naming the winner"
else bad "(4) rc=$RC: $OUT (ref $(refsha) vs $RSHA)"; fi

# (5) stale clearance whose pull request was CLOSED unmerged → taken over in one compare-and-swap, CLEARED
#     (a MERGED one is never taken silently — case 16c)
fresh stale-closed; held claude:other pr release/26-10-17 3970 2026-10-18T09:30:00Z
printf '[{"number":3970,"headRefName":"release/26-10-17","state":"CLOSED"}]' > "$STATE/prs.json"
run claim
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'stale clearance taken over' && printf '%s' "$OUT" | grep -q 'closed' && printf '%s' "$OUT" | grep -q '^CLEARED claude:me-1' && [ "$(record holder)" = claude:me-1 ]; then
  ok "(5) stale (35 min) + closed pull request → taken over, then CLEARED for this session"
else bad "(5) rc=$RC: $OUT"; fi

# (6) stale with no pull request ever opened → taken over too
fresh stale-none; held claude:other cut release/26-10-17 - 2026-10-18T09:30:00Z
run claim
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'never opened' && [ "$(record holder)" = claude:me-1 ]; then
  ok "(6) stale with no pull request recorded → taken over"
else bad "(6) rc=$RC: $OUT"; fi

# (6b) two sessions taking over the same stale clearance: the lease lets exactly one through
fresh stale-two; held claude:other cut release/26-10-17 - 2026-10-18T09:30:00Z
OUT1="$(CLAUDE_CODE_SESSION_ID=me-1 bash "$P" claim 2>&1 & CLAUDE_CODE_SESSION_ID=me-2 CLEARANCE_RECORD="$WORK/stale-two.record2.json" bash "$P" claim 2>&1; wait)"
WINS="$(printf '%s\n' "$OUT1" | grep -c '^CLEARED')"; BUSY="$(printf '%s\n' "$OUT1" | grep -c '^BUSY')"
if [ "$WINS" -eq 1 ] && [ "$BUSY" -eq 1 ] && printf '%s' "$(record holder)" | grep -q '^claude:me-[12]$'; then
  ok "(6b) two concurrent takeovers of one stale clearance → one CLEARED, one BUSY (the lease decides)"
else bad "(6b) wins=$WINS busy=$BUSY: $OUT1"; fi

# (7) stale with its pull request still OPEN → STALE, exit 3, nothing touched
fresh stale-open; held claude:other review release/26-10-17 3970 2026-10-18T09:30:00Z
printf '[{"number":3970,"headRefName":"release/26-10-17","state":"OPEN","isDraft":true,"createdAt":"2026-10-18T09:35:00Z"}]' > "$STATE/prs.json"
run claim
if [ "$RC" -eq 3 ] && printf '%s' "$OUT" | grep -q '^STALE held by bob .* — STALE — pull request #3970 still open — adopt or wait$' && [ "$(record holder)" = claude:other ]; then
  ok "(7) stale + open pull request → STALE … pull request #n still open — adopt or wait; exit 3; untouched"
else bad "(7) rc=$RC: $OUT"; fi

# (8) adopt --yes takes over a stale clearance; the phase, branch and pull request survive
run adopt --yes
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^ADOPTED release/26-10-17 #3970$' && printf '%s' "$OUT" | grep -q '^Resume: branch release/26-10-17, pull request #3970, phase review$' \
   && [ "$(record holder)" = claude:me-1 ] && [ "$(record heartbeatAt)" = 2026-10-18T10:05:00Z ] && [ "$(record takenAt)" = 2026-10-18T09:50:00Z ] \
   && [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pr"])' "$CLEARANCE_RECORD")" = 3970 ]; then
  ok "(8) adopt --yes → holder rewritten, heartbeat now, takenAt kept; Resume line names branch, pull request, phase"
else bad "(8) rc=$RC: $OUT"; fi

# (9) adopt refuses a fresh clearance; without --yes it refuses to run at all
fresh adopt-fresh; held claude:other review release/26-10-18 3981
run adopt --yes; A="$RC:$OUT"
run adopt; B="$RC"
if [ "${A%%:*}" -eq 2 ] && printf '%s' "$A" | grep -q 'not stale, nothing to adopt' && [ "$B" -eq 1 ] && [ "$(record holder)" = claude:other ]; then
  ok "(9) adopt on a fresh clearance → BUSY … not stale (exit 2); adopt without --yes → error"
else bad "(9) got: $A / $B"; fi

# (10) heartbeat by a non-holder exits 4 and changes nothing; by the holder it updates phase/branch/pr
#      (a '#3990' is stored as 3990); after losing the clearance, the local record is gone
fresh beat; held claude:other review release/26-10-18 3981
printf '{"repo":"o/r","holder":"claude:me-1"}' > "$CLEARANCE_RECORD"
run heartbeat cut --branch release/26-10-18; A="$RC"
[ "$(record phase)" = review ] && SAME=1 || SAME=0; [ -f "$CLEARANCE_RECORD" ] && LEFT=1 || LEFT=0
fresh beat2; run claim; run heartbeat pr --branch release/26-10-18 --pr '#3990'
if [ "$A" -eq 4 ] && [ "$SAME" = 1 ] && [ "$LEFT" = 0 ] && [ "$RC" -eq 0 ] && [ "$(record phase)" = pr ] && [ "$(record branch)" = release/26-10-18 ] && [ "$(record pr)" = 3990 ] \
   && printf '%s' "$OUT" | grep -q '^HEARTBEAT pr 2026-10-18T10:05:00Z$' \
   && [ "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["branch"], d["pr"])' "$CLEARANCE_RECORD")" = "release/26-10-18 3990" ]; then
  ok "(10) heartbeat: non-holder → exit 4, record untouched, stale local record removed; holder → phase/branch/pr on the ref and locally"
else bad "(10) a=$A same=$SAME left=$LEFT rc=$RC: $OUT"; fi

# (11) release by a non-holder exits 4; --force releases and says whose it was; by the holder it
#      deletes the ref and removes the local record
fresh rel; held claude:other review release/26-10-18 3981
run release; A="$RC"; [ -n "$(refsha)" ] && KEPT=1 || KEPT=0
run release --force; B="$RC:$OUT"; [ -z "$(refsha)" ] && GONE=1 || GONE=0
fresh rel2; run claim; run release; C="$RC:$OUT"
if [ "$A" -eq 4 ] && [ "$KEPT" = 1 ] && [ "${B%%:*}" -eq 0 ] && printf '%s' "$B" | grep -q 'forcing release of a clearance held by bob' && [ "$GONE" = 1 ] \
   && [ "${C%%:*}" -eq 0 ] && printf '%s' "$C" | grep -q 'RELEASED' && [ -z "$(refsha)" ] && [ ! -f "$CLEARANCE_RECORD" ]; then
  ok "(11) release: non-holder → exit 4; --force → released, naming the holder; holder → ref deleted, local record removed"
else bad "(11) a=$A kept=$KEPT b=$B c=$C"; fi

# (12) release on a clear ref is a no-op that still clears a leftover local record
fresh rel3; printf '{"repo":"o/r","holder":"claude:me-1"}' > "$CLEARANCE_RECORD"
run release
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^CLEAR (nothing to release)' && [ ! -f "$CLEARANCE_RECORD" ]; then
  ok "(12) release with nothing held → CLEAR (nothing to release), stale local record removed"
else bad "(12) rc=$RC: $OUT"; fi

# (13) status: the clearance line, On final / Waiting (oldest open release pull request first by
#      number), Hotfix landed since takenAt only (an earlier hotfix is not listed); exit 0
fresh st; held claude:other ci release/26-10-18 3981
cat > "$STATE/prs.json" <<'J'
[{"number":3985,"headRefName":"release/26-10-18-2","state":"OPEN","isDraft":true,"createdAt":"2026-10-18T09:58:00Z"},
 {"number":3981,"headRefName":"release/26-10-18","state":"OPEN","isDraft":false,"createdAt":"2026-10-18T09:52:00Z"},
 {"number":3983,"headRefName":"phil/hotfix/26-10-18/I1-fix","state":"MERGED","mergedAt":"2026-10-18T10:01:00Z"},
 {"number":3960,"headRefName":"phil/hotfix/26-10-17/I2-old","state":"MERGED","mergedAt":"2026-10-18T09:00:00Z"},
 {"number":3984,"headRefName":"phil/26-10-18/I3-feature","state":"OPEN","isDraft":false,"createdAt":"2026-10-18T10:02:00Z"}]
J
run status
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^Clearance: held by bob on m9 since 2026-10-18T09:50:00Z, phase ci, heartbeat 5 min ago — release/26-10-18 #3981$' \
   && printf '%s' "$OUT" | grep -q '^On final: #3981 release/26-10-18$' && printf '%s' "$OUT" | grep -q '^Waiting: #3985 release/26-10-18-2 (draft)$' \
   && printf '%s' "$OUT" | grep -q '^Hotfix landed: #3983 phil/hotfix/26-10-18/I1-fix 2026-10-18T10:01:00Z$' && ! printf '%s' "$OUT" | grep -q '#3960' && ! printf '%s' "$OUT" | grep -q '#3984'; then
  ok "(13) status → Clearance line, On final (oldest release pull request), Waiting (draft), Hotfix landed since takenAt only"
else bad "(13) rc=$RC: $OUT"; fi
if grep -q -- '--state merged .*--search merged:>=2026-10-18' "$STATE/calls.log"; then
  ok "(13b) the merged list is asked for merges since the claim's date only (a busy production branch never fills the page)"
else bad "(13b) no --search merged:>=2026-10-18 in the gh calls log"; fi

# (14) status --short is one token line for the status line; --json carries the record and facts
run status --short; A="$RC:$OUT"
run status --json; B="$OUT"
J="$(printf '%s' "$B" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["state"], d["stale"], d["record"]["holder"], d["onFinal"]["number"], len(d["waiting"]), d["hotfixesLanded"][0]["number"], d["staleMinutes"])' 2>/dev/null)"
if [ "$A" = "0:release/26-10-18 · bob · ci" ] && [ "$J" = "held False claude:other 3981 1 3983 20" ]; then
  ok "(14) status --short → 'release/26-10-18 · bob · ci'; --json → state, stale, record, onFinal, waiting, hotfixesLanded"
else bad "(14) short=$A json=$J"; fi

# (15) status when clear: CLEAR, --short prints nothing, --json state clear; a stale one says STALE
fresh clear; run status; A="$RC:$OUT"; run status --short; B="$RC:$OUT"
run status --json; C="$(printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["state"], d["record"])')"
fresh stale-st; held claude:other review release/26-10-17 3970 2026-10-18T09:30:00Z; run status --short; D="$OUT"
if [ "$A" = "0:CLEAR" ] && [ "$B" = "0:" ] && [ "$C" = "clear None" ] && [ "$D" = "release/26-10-17 · bob · review · STALE" ]; then
  ok "(15) clear → CLEAR / nothing / state clear; a stale clearance renders '· STALE'"
else bad "(15) a=$A b=$B c=$C d=$D"; fi

# (16) a remote that cannot be asked is UNKNOWN with exit 1 — never shown as clear; --short
#      prints nothing at all (a status line must never render an error); so does a config error
fresh unknown; git remote set-url origin "$WORK/no-such-origin.git"
run status; A="$RC:$OUT"; run status --json; B="$OUT"
C="$(bash "$P" status --short 2>/dev/null)"; CRC=$?
D="$(CLEARANCE_REF=bad bash "$P" status --short 2>/dev/null)"; DRC=$?
if [ "${A%%:*}" -eq 1 ] && printf '%s' "$A" | grep -q 'UNKNOWN (' && printf '%s' "$B" | grep -q '"state": "unknown"' && [ "$CRC" -eq 1 ] && [ -z "$C" ] && [ "$DRC" -eq 1 ] && [ -z "$D" ]; then
  ok "(16) unreachable remote → UNKNOWN (…) exit 1, --json state unknown; --short prints nothing on any failure"
else bad "(16) a=$A b=$B c=$CRC:$C d=$DRC:$D"; fi

# (16b) the verdict is stdout's FIRST line even when progress precedes it (token, polls, a takeover)
fresh firstline; held claude:other cut release/26-10-17 - 2026-10-18T09:30:00Z
unset CLAUDE_CODE_SESSION_ID
FIRST="$(bash "$P" claim 2>/dev/null | head -1)"; export CLAUDE_CODE_SESSION_ID=me-1
fresh firstline2; held claude:other review release/26-10-18 3981
( sleep 2; git push -q origin ":refs/clearance/release" ) &
FIRST2="$(bash "$P" claim --wait 2>/dev/null | head -1)"; wait
if printf '%s' "$FIRST" | grep -q '^CLEARED token:' && printf '%s' "$FIRST2" | grep -q '^CLEARED claude:me-1'; then
  ok "(16b) stdout's first line is the verdict; the token, the takeover note and the BUSY polls go to stderr"
else bad "(16b) first='$FIRST' first2='$FIRST2'"; fi

# (16c) a stale clearance whose pull request MERGED is not a finished release: STALE exit 3
#       (the session died between the merge and the end of its close-out); adopt resumes it
fresh stale-merged-open; held claude:other deploy release/26-10-17 3970 2026-10-18T09:30:00Z
printf '[{"number":3970,"headRefName":"release/26-10-17","state":"MERGED","mergedAt":"2026-10-18T09:40:00Z"}]' > "$STATE/prs.json"
run claim; A="$RC:$OUT"; run adopt --yes; B="$RC:$OUT"
if [ "${A%%:*}" -eq 3 ] && printf '%s' "$A" | grep -q 'merged but the release was never closed out — adopt or wait' && [ "${B%%:*}" -eq 0 ] && [ "$(record holder)" = claude:me-1 ]; then
  ok "(16c) stale + merged pull request → STALE … never closed out (exit 3); adopt --yes resumes it"
else bad "(16c) a=$A b=$B"; fi

# (16d) a pull-request state that cannot be read is an error, never a 3; a CLOSED one is taken over
fresh stale-unknown; held claude:other review release/26-10-17 4242 2026-10-18T09:30:00Z
run claim; A="$RC:$OUT"
printf '[{"number":4242,"headRefName":"release/26-10-17","state":"CLOSED"}]' > "$STATE/prs.json"
run claim; B="$RC:$OUT"
if [ "${A%%:*}" -eq 1 ] && printf '%s' "$A" | grep -q 'could not be read' && [ "${B%%:*}" -eq 0 ] && [ "$(record holder)" = claude:me-1 ]; then
  ok "(16d) unreadable pull-request state → ERROR exit 1 (not 3); a closed pull request → taken over"
else bad "(16d) a=$A b=$B"; fi

# (16e) a claim by the session that already holds it renews the heartbeat
fresh renew; held claude:me-1 review release/26-10-18 3981 2026-10-18T09:30:00Z
run claim
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'heartbeat renewed' && [ "$(record heartbeatAt)" = 2026-10-18T10:05:00Z ]; then
  ok "(16e) re-claim by the holder → CLEARED and the heartbeat is renewed (a stale record is fresh again)"
else bad "(16e) rc=$RC: $OUT / $(record heartbeatAt)"; fi

# (16f) something that is not a clearance record holds the ref: claim and adopt refuse, status is
#       UNKNOWN exit 1, a non-forced release is NOT HOLDER, and only release --force clears it
fresh junk; seed 'not json at all'
run claim; A="$RC:$OUT"; run adopt --yes; B="$RC"; run status; C="$RC:$OUT"; run status --short; D="$RC:$OUT"; run release; E="$RC"; run release --force; F="$RC"
if [ "${A%%:*}" -eq 1 ] && printf '%s' "$A" | grep -q 'UNREADABLE record' && [ "$B" -eq 1 ] && [ "${C%%:*}" -eq 1 ] && printf '%s' "$C" | grep -q 'UNKNOWN (UNREADABLE' && [ "$D" = "1:" ] && [ "$E" -eq 4 ] && [ "$F" -eq 0 ] && [ -z "$(refsha)" ]; then
  ok "(16f) an unreadable record is never taken over: claim/adopt error, status UNKNOWN, release NOT HOLDER, --force clears"
else bad "(16f) a=$A b=$B c=$C d=$D e=$E f=$F"; fi

# (16g) a config file that exists but is not JSON is an error, not a fallback to the defaults
fresh badconfig; mkdir -p .claude; printf 'nope' > .claude/ds-config.json
run status
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'cannot be read as JSON'; then ok "(16g) a corrupt .claude/ds-config.json → ERROR, never the default ref"; else bad "(16g) rc=$RC: $OUT"; fi

# (16h) a non-holder's release leaves another session's local record alone; the holder's own is removed
fresh localown; held claude:other review release/26-10-18 3981
printf '{"repo":"o/r","holder":"claude:me-2"}' > "$CLEARANCE_RECORD"
run release; A="$RC"; [ -f "$CLEARANCE_RECORD" ] && KEPT=1 || KEPT=0
if [ "$A" -eq 4 ] && [ "$KEPT" = 1 ]; then ok "(16h) NOT HOLDER never removes a record that names another session on this machine"; else bad "(16h) a=$A kept=$KEPT"; fi

# (17) claim --wait polls (1 s here) and returns 0 when the holder releases
fresh wait; held claude:other review release/26-10-18 3981
( sleep 2; git push -q origin ":refs/clearance/release" ) &
START=$(date +%s); run claim --wait; END=$(date +%s)
if [ "$RC" -eq 0 ] && [ "$(printf '%s\n' "$OUT" | grep -c '^BUSY')" -ge 1 ] && printf '%s' "$OUT" | grep -q '^CLEARED claude:me-1' && [ $((END - START)) -ge 2 ] && [ $((END - START)) -le 20 ]; then
  ok "(17) claim --wait prints BUSY each poll and returns CLEARED when the clearance frees ($((END - START)) s)"
else bad "(17) rc=$RC in $((END - START)) s: $OUT"; fi

# (18) claim --wait gives up at waitMinutes with BUSY, exit 2
fresh waitout; held claude:other review release/26-10-18 3981
export CLEARANCE_WAIT_MINUTES=0
run claim --wait
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q '^BUSY'; then ok "(18) claim --wait past waitMinutes → BUSY, exit 2"; else bad "(18) rc=$RC: $OUT"; fi

# (19) a push the server refuses outright (a ruleset) names the finding, exit 1
fresh forbidden
printf '#!/bin/bash\necho "refusing to update protected ref (rule)" >&2; exit 1\n' > "$STATE/origin.git/hooks/pre-receive"; chmod +x "$STATE/origin.git/hooks/pre-receive"
OUT="$(perl -e 'alarm 60; exec @ARGV' bash "$P" claim 2>&1)"; RC=$?   # a regression that retries forever fails here, never hangs
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'refusing to update protected ref' && printf '%s' "$OUT" | grep -q 'ruleset that restricts ref creation'; then
  ok "(19) a refused push → ERROR keeping the server's words and naming the ruleset finding, exit 1"
else bad "(19) rc=$RC: $OUT"; fi

# (20) identity: DEVSTRIDE_LEASE_TOKEN wins; codex+claude join with +; neither → a printed token
fresh ident; export DEVSTRIDE_LEASE_TOKEN=tok-1; run claim; A="$(record holder)"
fresh ident2; export CODEX_THREAD_ID=c-9; run claim; B="$(record holder)"
fresh ident3; unset CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID; run claim; C="$(record holder)"; D="$OUT"
if [ "$A" = tok-1 ] && [ "$B" = "codex:c-9+claude:me-1" ] && printf '%s' "$C" | grep -q '^token:[0-9a-f]\{24\}$' && printf '%s' "$D" | grep -q "holder token $C — export it as DEVSTRIDE_LEASE_TOKEN"; then
  ok "(20) holder = DEVSTRIDE_LEASE_TOKEN, else codex:…+claude:…, else token:<random> printed once"
else bad "(20) a=$A b=$B c=$C d=$D"; fi

# (21) a release pattern absent: the release source itself is the release head for On final
fresh nopattern; export CLEARANCE_RELEASE_PATTERN=''
printf '[{"number":12,"headRefName":"develop","state":"OPEN","isDraft":false,"createdAt":"2026-10-18T09:52:00Z"}]' > "$STATE/prs.json"
run status
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^On final: #12 develop$'; then ok "(21) no releaseBranchPattern → a pull request headed by the release source is the release"; else bad "(21) rc=$RC: $OUT"; fi

# (22) the keeper: a claim starts a detached heartbeat tied to the owning process; it re-stamps
#      the ref on its own, stops when the owner dies, and release stops it too
fresh keeper; unset CLEARANCE_NO_KEEPER CLEARANCE_NOW
sleep 300 & OWNER=$!
export CLEARANCE_OWNER_PID=$OWNER CLEARANCE_KEEPER_SECONDS=1
run claim
KPID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["keeperPid"])' "$CLEARANCE_RECORD" 2>/dev/null)"
T0="$(record heartbeatAt)"; sleep 3; T1="$(record heartbeatAt)"
kill "$OWNER" 2>/dev/null; wait "$OWNER" 2>/dev/null; sleep 3
kill -0 "$KPID" 2>/dev/null && KALIVE=1 || KALIVE=0
if [ "$RC" -eq 0 ] && [ -n "$KPID" ] && [ "$T1" != "$T0" ] && [ "$KALIVE" = 0 ]; then
  ok "(22) claim starts a keeper (pid $KPID) that re-stamps the heartbeat; it exits once the owning process is gone"
else bad "(22) rc=$RC keeper=$KPID t0=$T0 t1=$T1 alive=$KALIVE"; fi
fresh keeper2; sleep 300 & OWNER=$!; export CLEARANCE_OWNER_PID=$OWNER
run claim; KPID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["keeperPid"])' "$CLEARANCE_RECORD" 2>/dev/null)"
run release; sleep 1; kill -0 "$KPID" 2>/dev/null && KALIVE=1 || KALIVE=0; kill "$OWNER" 2>/dev/null; wait "$OWNER" 2>/dev/null
if [ -n "$KPID" ] && [ "$KALIVE" = 0 ] && [ ! -f "$CLEARANCE_RECORD" ]; then ok "(22b) release stops the keeper and removes the local record"; else bad "(22b) keeper=$KPID alive=$KALIVE"; fi
export CLEARANCE_NO_KEEPER=1; unset CLEARANCE_OWNER_PID CLEARANCE_KEEPER_SECONDS

# (22c) the keeper never asks gh for the repository: with gh down from the first tick on, it keeps stamping
fresh keeper3; sleep 300 & OWNER=$!
( unset CLEARANCE_NO_KEEPER CLEARANCE_REPO; export CLEARANCE_OWNER_PID=$OWNER CLEARANCE_KEEPER_SECONDS=1; bash "$P" claim >/dev/null 2>&1 )
: > "$STATE/gh-down"
T0="$(record heartbeatAt)"; sleep 3; T1="$(record heartbeatAt)"
KPID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("keeperPid",""))' "$CLEARANCE_RECORD" 2>/dev/null)"
kill "$OWNER" 2>/dev/null; wait "$OWNER" 2>/dev/null; sleep 3; rm -f "$STATE/gh-down"
if [ -n "$KPID" ] && [ "$T1" != "$T0" ] && [ "$T1" \> "$T0" ] && ! kill -0 "$KPID" 2>/dev/null; then
  ok "(22c) the keeper (pid $KPID) stamps on while gh is unreachable, and still exits with its owner"
else bad "(22c) keeper=$KPID T0=$T0 T1=$T1"; fi

# (23) the holder's own keeper moving the ref is not a lost clearance: heartbeat and release carry on
#      from the object the keeper wrote. The hook declines EVERY push until the keeper's stamp is in
#      place (a side process installs it the moment the first push was declined), so the command
#      can only succeed by retrying with a lease on the stamped object — the keeper-moved path.
fresh ownstamp
run claim
cat > "$STATE/origin.git/hooks/pre-receive" <<HOOK
#!/bin/bash
if [ -f "$STATE/stamp-want" ]; then
  want="\$(cat "$STATE/stamp-want")"; have="\$(git rev-parse -q --verify refs/clearance/release)"
  if [ "\$have" != "\$want" ]; then : > "$STATE/stamp-declined"; echo "keeper landing" >&2; exit 1; fi
fi
exit 0
HOOK
chmod +x "$STATE/origin.git/hooks/pre-receive"
restamp() { # restamp AT — a tag for THIS holder with a fresh heartbeat, present on origin; a side process moves the ref to it once the first push was declined
  local sha
  sha="$(printf 'object %s\ntype commit\ntag release-clearance\ntagger t <t@t> 1 +0000\n\n{"v":1,"repo":"o/r","holder":"claude:me-1","user":"alice","machine":"m9","purpose":"release","phase":"claimed","branch":null,"pr":null,"takenAt":"2026-10-18T10:05:00Z","heartbeatAt":"%s"}\n' "$(git rev-parse HEAD)" "$1" | git hash-object -t tag -w --stdin)"
  git push -q origin "${sha}:refs/race-seed/s$RANDOM$RANDOM" || { echo "  (23) seed push failed" >&2; return 1; }
  rm -f "$STATE/stamp-declined" "$STATE/stamp-installed"; printf '%s' "$sha" > "$STATE/stamp-want"
  ( until [ -f "$STATE/stamp-declined" ]; do sleep 0.05; done; git -C "$STATE/origin.git" update-ref refs/clearance/release "$sha" && : > "$STATE/stamp-installed" ) &
}
restamp 2026-10-18T10:06:00Z && run heartbeat review --branch release/26-10-18; wait
HB_RC=$RC; HB_OUT="$OUT"; HB_DECLINED=0; [ -f "$STATE/stamp-declined" ] && [ -f "$STATE/stamp-installed" ] && HB_DECLINED=1
HB_PHASE="$(record phase)"
rm -f "$STATE/stamp-want"
restamp 2026-10-18T10:07:00Z && run release; wait
REL_DECLINED=0; [ -f "$STATE/stamp-declined" ] && [ -f "$STATE/stamp-installed" ] && REL_DECLINED=1
rm -f "$STATE/stamp-want"
if [ "$HB_RC" -eq 0 ] && printf '%s' "$HB_OUT" | grep -q '^HEARTBEAT review' && [ "$HB_DECLINED" = 1 ] && [ "$HB_PHASE" = review ] \
   && [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^RELEASED' && [ "$REL_DECLINED" = 1 ] && [ -z "$(refsha)" ] && [ ! -f "$CLEARANCE_RECORD" ]; then
  ok "(23) a stamp by this holder's own keeper between read and push → heartbeat and release retry with a lease on the stamped object, exit 0 (NOT HOLDER is for another holder)"
else bad "(23) heartbeat rc=$HB_RC declined+installed=$HB_DECLINED phase=$HB_PHASE: $HB_OUT / release rc=$RC declined+installed=$REL_DECLINED: $OUT (ref: $(refsha))"; fi

# (24) a checkout that has not fetched production's newest commits still claims and heartbeats: the
#      tag points at a blob of its own, never at a commit the checkout may lack
fresh stale-checkout
git clone -q "$STATE/origin.git" "$STATE/other" && git -C "$STATE/other" commit -q --allow-empty -m newer && DEVSTRIDE_MERGE_GUARD=0 git -C "$STATE/other" push -q origin HEAD:master
run claim; C_RC=$RC; C_OUT="$OUT"
run heartbeat cut --branch release/26-10-18
if [ "$C_RC" -eq 0 ] && [ "$RC" -eq 0 ] && [ "$(record branch)" = release/26-10-18 ] && [ "$(git cat-file -t "$(git fetch -q origin refs/clearance/release && git rev-parse FETCH_HEAD^{})")" = blob ]; then
  ok "(24) a checkout behind production still claims and heartbeats; the clearance tag points at a blob, not a commit"
else bad "(24) claim rc=$C_RC: $C_OUT / heartbeat rc=$RC: $OUT"; fi

# (17b) claim --wait rides out a remote that cannot be asked for one poll, then wins
fresh waitdown; held claude:other review release/26-10-18 3981
( sleep 1; mv "$STATE/origin.git" "$STATE/origin.off"; sleep 2; mv "$STATE/origin.off" "$STATE/origin.git"; git push -q origin ":refs/clearance/release" ) &
run claim --wait
wait
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'polling again' && printf '%s' "$OUT" | grep -q '^CLEARED'; then
  ok "(17b) claim --wait: an unreadable ref mid-wait is a progress line, not exit 1; CLEARED once it frees"
else bad "(17b) rc=$RC: $OUT"; fi

# (16i) the verdict is stdout's first line even when no keeper can be started
fresh nokeeper
OUT="$( ( unset CLEARANCE_NO_KEEPER; export CLEARANCE_OWNER_PID=none; bash "$P" claim 2>/dev/null ) )"; RC=$?
if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | head -n 1 | cut -c1-7)" = CLEARED ]; then
  ok "(16i) no keeper (owning process not found) → the note goes to stderr; stdout's first line is still CLEARED"
else bad "(16i) rc=$RC: $OUT"; fi
export CLEARANCE_NO_KEEPER=1; unset CLEARANCE_OWNER_PID


# (25) phaseStartedAt: a claim starts it at takenAt; a heartbeat that CHANGES the phase restamps it;
#      one that repeats the phase (or only names a branch) keeps it; the keeper never touches it
fresh phase; run claim
A="$(record phaseStartedAt)"
export CLEARANCE_NOW=2026-10-18T10:15:00Z; run heartbeat deploy; B="$(record phaseStartedAt)"
export CLEARANCE_NOW=2026-10-18T10:40:00Z; run heartbeat deploy --pr 3990; C="$(record phaseStartedAt):$(record heartbeatAt)"
export CLEARANCE_NOW=2026-10-18T10:05:00Z
if [ "$A" = 2026-10-18T10:05:00Z ] && [ "$B" = 2026-10-18T10:15:00Z ] && [ "$C" = "2026-10-18T10:15:00Z:2026-10-18T10:40:00Z" ]; then
  ok "(25) phaseStartedAt = takenAt on claim, restamped on a phase change, kept on a repeated phase"
else bad "(25) a=$A b=$B c=$C"; fi

# (26) STUCK: alive (fresh heartbeat) but past the phase's budget (deploy 60 by default). status,
#      --short and --json say so and name the holder's session and machine; under budget, or a phase
#      with no budget (review), never STUCK; a record without phaseStartedAt is never STUCK
fresh stuck; held claude:other deploy release/26-10-18 3990 2026-10-18T10:04:00Z 2026-10-18T08:55:00Z
run status; A="$RC:$OUT"; run status --short; B="$OUT"
J="$( bash "$P" status --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["stuck"], d["stale"], d["phaseMinutes"], d["phaseBudgetMinutes"]["deploy"], d["phaseBudgetMinutes"]["pre-ship"], d["phaseBudgetMinutes"]["close-out"], "review" in d["phaseBudgetMinutes"])')"
held claude:other deploy release/26-10-18 3990 2026-10-18T10:04:00Z 2026-10-18T09:20:00Z; run status --short; C="$OUT"
held claude:other review release/26-10-18 3990 2026-10-18T10:04:00Z 2026-10-18T05:00:00Z; run status --short; D="$OUT"
held claude:other deploy release/26-10-18 3990 2026-10-18T10:04:00Z; run status --short; E="$OUT"
if printf '%s' "$A" | grep -q '^0:Clearance: held by bob on m9 .* — STUCK in deploy for 70 min (budget 60 min), session claude:other on m9$' \
   && [ "$B" = "release/26-10-18 · bob · deploy · STUCK" ] && [ "$J" = "True False 70 60 120 45 False" ] \
   && [ "$C" = "release/26-10-18 · bob · deploy" ] && [ "$D" = "release/26-10-18 · bob · review" ] && [ "$E" = "release/26-10-18 · bob · deploy" ]; then
  ok "(26) past budget → STUCK in <phase> for <n> min (budget <b>), session + machine; --short '· STUCK'; --json stuck/phaseMinutes/budgets; under budget, unbudgeted or unstamped → not STUCK"
else bad "(26) a=$A b=$B j=$J c=$C d=$D e=$E"; fi

# (27) release.clearance.phaseBudgetMinutes overrides the defaults per phase; 0 switches one off
fresh budgets; mkdir -p .claude
printf '{"release":{"clearance":{"provider":"github","phaseBudgetMinutes":{"deploy":90,"review":30,"pre-ship":0}}}}' > .claude/ds-config.json
held claude:other deploy release/26-10-18 3990 2026-10-18T10:04:00Z 2026-10-18T08:55:00Z; run status --short; A="$OUT"
held claude:other review release/26-10-18 3990 2026-10-18T10:04:00Z 2026-10-18T09:30:00Z; run status --short; B="$OUT"
held claude:other pre-ship release/26-10-18 3990 2026-10-18T10:04:00Z 2026-10-18T02:00:00Z; run status --short; C="$OUT"
printf '{"release":{"clearance":{"provider":"github","phaseBudgetMinutes":[5]}}}' > .claude/ds-config.json; run status; D="$RC:$OUT"
rm -rf .claude
if [ "$A" = "release/26-10-18 · bob · deploy" ] && [ "$B" = "release/26-10-18 · bob · review · STUCK" ] && [ "$C" = "release/26-10-18 · bob · pre-ship" ] \
   && [ "${D%%:*}" -eq 1 ] && printf '%s' "$D" | grep -q 'phaseBudgetMinutes must be an object'; then
  ok "(27) phaseBudgetMinutes: deploy raised to 90 (70 min not stuck), review given 30 (35 min stuck), pre-ship 0 = off; a non-object is an error"
else bad "(27) a=$A b=$B c=$C d=$D"; fi

# (28) claim --wait ends at the first STUCK poll with exit 5 and a STUCK line, so the waiting session
#      can tell the owner; --ignore-stuck keeps waiting (to waitMinutes here: BUSY, exit 2); a claim
#      without --wait is a plain BUSY carrying the STUCK note; nothing is taken over either way
fresh waitstuck; held claude:other deploy release/26-10-18 3990 2026-10-18T10:04:00Z 2026-10-18T08:55:00Z; BEFORE="$(refsha)"
run claim --wait; A="$RC:$OUT"
run claim; B="$RC:$OUT"
export CLEARANCE_WAIT_MINUTES=0; run claim --wait --ignore-stuck; C="$RC:$OUT"; export CLEARANCE_WAIT_MINUTES=1
if [ "${A%%:*}" -eq 5 ] && printf '%s' "${A#*:}" | head -n 1 | grep -q '^STUCK held by bob .* — STUCK in deploy for 70 min' \
   && [ "${B%%:*}" -eq 2 ] && printf '%s' "$B" | grep -q '^2:BUSY .* — STUCK in deploy' \
   && [ "${C%%:*}" -eq 2 ] && printf '%s' "$C" | grep -q 'BUSY' && [ "$(refsha)" = "$BEFORE" ]; then
  ok "(28) claim --wait on a STUCK holder → STUCK line, exit 5; --ignore-stuck waits on; plain claim → BUSY with the STUCK note; ref untouched"
else bad "(28) a=$A b=$B c=$C"; fi

# (29) adopting: a STUCK clearance that is still alive is refused unless --original-stopped (the
#      owner's word that the original session stopped); then adopted with the phase clock restarted.
#      A fresh, unstuck one is refused even with --original-stopped.
fresh adoptstuck; held claude:other deploy release/26-10-18 3990 2026-10-18T10:04:00Z 2026-10-18T08:55:00Z
run adopt --yes; A="$RC:$OUT"; H1="$(record holder)"
run adopt --yes --original-stopped; B="$RC:$OUT"
fresh adoptfresh; held claude:other deploy release/26-10-18 3990 2026-10-18T10:04:00Z 2026-10-18T09:50:00Z
run adopt --yes --original-stopped; C="$RC:$OUT"; H3="$(record holder)"
fresh adoptstuck2; held claude:other deploy release/26-10-18 3990 2026-10-18T10:04:00Z 2026-10-18T08:55:00Z
run adopt --yes --original-stopped
if [ "${A%%:*}" -eq 2 ] && printf '%s' "$A" | grep -q 'stuck but alive: adopt only on the owner.s yes, once the original session has stopped' && [ "$H1" = claude:other ] \
   && [ "${B%%:*}" -eq 0 ] && printf '%s' "$B" | grep -q '^ADOPTED release/26-10-18 #3990$' \
   && [ "${C%%:*}" -eq 2 ] && printf '%s' "$C" | grep -q 'not stale, nothing to adopt' && [ "$H3" = claude:other ] \
   && [ "$(record holder)" = claude:me-1 ] && [ "$(record phaseStartedAt)" = 2026-10-18T10:05:00Z ] && [ "$(record phase)" = deploy ]; then
  ok "(29) adopt: stuck + alive → refused (exit 2) without --original-stopped; with it → ADOPTED, phase kept, its clock restarted; fresh + unstuck → refused"
else bad "(29) a=$A b=$B c=$C"; fi

# (30) release --owed records the close-out work still owed after the hand-back: RELEASED stays the
#      first line, the owed line follows; the owed file is 0600 beside the record (never the record,
#      which a hook reads as "this session holds clearance"); status, --short and --json show it
fresh owed; run claim; run heartbeat close-out --branch release/26-10-18 --pr 3990
run release --owed docs --owed close-out; A="$RC:$OUT"; F="$WORK/owed.record.owed.json"
export CLEARANCE_NOW=2026-10-18T10:17:00Z
run status; B="$RC:$OUT"; run status --short; C="$OUT"
J="$( bash "$P" status --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); e=d["closeOutOwed"][0]; print(d["state"], e["release"], e["pr"], ",".join(e["owed"]), e["holder"])')"
export CLEARANCE_NOW=2026-10-18T10:05:00Z
if [ "${A%%:*}" -eq 0 ] && [ "$(printf '%s\n' "${A#*:}" | head -n 1)" = "RELEASED release/26-10-18" ] && printf '%s' "$A" | grep -q '^Close-out owed: docs, close-out$' \
   && [ ! -f "$CLEARANCE_RECORD" ] && [ -f "$F" ] && [ "$(stat -c %a "$F" 2>/dev/null || stat -f %Lp "$F")" = 600 ] && [ -z "$(refsha)" ] \
   && printf '%s' "$B" | grep -q '^0:CLEAR' && printf '%s' "$B" | grep -q '^Close-out owed: release/26-10-18 #3990 — docs, close-out (handed back 12 min ago by alice on .*, session claude:me-1)$' \
   && [ "$C" = "close-out owed · release/26-10-18 · docs, close-out" ] && [ "$J" = "clear release/26-10-18 3990 docs,close-out claude:me-1" ]; then
  ok "(30) release --owed → RELEASED first, then Close-out owed; 0600 file beside the record; status / --short / --json show the owed work"
else bad "(30) a=$A b=$B c=$C j=$J"; fi

# (31) owed settles it: --done removes one item (an unknown one is noted, not an error), the last one
#      removes the entry and the file, after which --short prints nothing again; --clear --release
#      drops a named entry whole
run owed; A="$RC:$OUT"
run owed --done docs --done nonsense; B="$RC:$OUT"
run owed --done close-out; C="$RC:$OUT"; [ -f "$F" ] && LEFT=1 || LEFT=0
run status --short; D="$OUT"
run claim; run heartbeat close-out --branch release/26-10-18-2; run release --owed docs; run owed --clear --release release/26-10-18-2; E="$RC:$OUT"
if [ "${A%%:*}" -eq 0 ] && printf '%s' "$A" | grep -q '^0:OWED release/26-10-18 #3990 — docs, close-out' \
   && printf '%s' "$B" | grep -q 'not owed: nonsense' && printf '%s' "$B" | grep -q '^OWED release/26-10-18 #3990 — close-out (' \
   && [ "$C" = "0:NONE" ] && [ "$LEFT" = 0 ] && [ -z "$D" ] && [ "$E" = "0:NONE" ]; then
  ok "(31) owed → OWED lines; --done settles items one by one (unknown ones noted); the last removes the file; --clear --release drops an entry"
else bad "(31) a=$A b=$B c=$C left=$LEFT d=$D e=$E"; fi

exit $FAIL
