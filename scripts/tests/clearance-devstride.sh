#!/bin/bash
# Tests for skills/release/scripts/clearance-devstride.sh — the release clearance provider backed by
# a DevStride claim. The claim tools are a fake MCP server on 127.0.0.1
# (scripts/tests/fixtures/clearance/fake-devstride.py, one per case, its claims in a JSON file the
# cases also seed); a fake `gh` (fake-gh.py) serves pull-request facts and the user name. The
# contract is the github provider's, so most cases mirror scripts/tests/clearance-github.sh.
# No network; nothing outside a private TMPDIR; no keeper process unless a case starts one.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; P="$ROOT/skills/release/scripts/clearance-devstride.sh"
G="$ROOT/skills/release/scripts/clearance-github.sh"; FX="$ROOT/scripts/tests/fixtures/clearance"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; SRV=""; stopsrv() { [ -n "$SRV" ] && { kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; }; SRV=""; }
trap 'stopsrv; rm -rf "$WORK"' EXIT
LOG="$WORK/all-output.log"; : > "$LOG"
mkdir -p "$WORK/bin"; printf '#!/bin/bash\nexec python3 "%s/fake-gh.py" "$@"\n' "$FX" > "$WORK/bin/gh"; chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH" HOME="$WORK/home" GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1; mkdir -p "$HOME"
printf '[user]\n\tname = t\n\temail = t@t\n' > "$GIT_CONFIG_GLOBAL"
export CLEARANCE_NO_KEEPER=1

# fresh NAME — a fake DevStride server with an empty claims file, a fake-gh state directory, a local
# record path and a working directory; the provider then runs as session me-1.
fresh() {
  stopsrv
  STATE="$WORK/$1"; rm -rf "$STATE"; DS="$STATE/ds"; mkdir -p "$DS" "$STATE/work"
  python3 "$FX/fake-devstride.py" "$DS" & SRV=$!
  local n=0; until [ -s "$DS/port" ] || [ $n -gt 100 ]; do sleep 0.05; n=$((n + 1)); done
  cd "$STATE/work" || exit 1
  export FAKE_GH_STATE="$STATE" CLEARANCE_RECORD="$WORK/$1.record.json" CLEARANCE_REPO=o/r \
         CLEARANCE_PRODUCTION_BRANCH=master CLEARANCE_RELEASE_PATTERN='release/<YY-MM-DD>[-n]' \
         CLEARANCE_POLL_SECONDS=1 CLEARANCE_WAIT_MINUTES=1 CLEARANCE_STALE_MINUTES=20 \
         CLEARANCE_NOW=2026-10-18T10:05:00Z CLAUDE_CODE_SESSION_ID=me-1 \
         DEVSTRIDE_MACHINE_NAME=M9-Dan DEVSTRIDE_SESSION=rel-1 \
         CLEARANCE_DEVSTRIDE_TEST_URL="http://127.0.0.1:$(cat "$DS/port")" \
         DEVSTRIDE_API_KEY=test-key DEVSTRIDE_API_SECRET=test-secret DEVSTRIDE_ORG_ID=org-1
  unset CLEARANCE_HOLDER_TOKEN DEVSTRIDE_LEASE_TOKEN CODEX_THREAD_ID CLEARANCE_PHASE_BUDGETS
  rm -f "$CLEARANCE_RECORD" "$WORK/$1.record.owed.json"
  printf '%s' "$CLEARANCE_NOW" > "$DS/now"
}
# held HOLDER PHASE BRANCH PR [HEARTBEAT] [PHASE_STARTED] — a claim held by someone else (its holder
# is stored the way the server does: as a digest), expiring 20 minutes after its heartbeat
held() {
  python3 - "$DS/claims.json" "$@" <<'PY'
import hashlib, json, sys
from datetime import datetime, timedelta
path, holder, phase, branch, pr = sys.argv[1:6]
beat = sys.argv[6] if len(sys.argv) > 6 else "2026-10-18T10:00:00Z"
started = sys.argv[7] if len(sys.argv) > 7 else None
digest = hashlib.sha256(holder.encode()).hexdigest()
expires = (datetime.fromisoformat(beat.replace("Z", "+00:00")) + timedelta(minutes=20)).isoformat().replace("+00:00", "Z")
payload = {"v": 1, "repo": "o/r", "holder": digest, "user": "bob", "machine": "m9", "purpose": "release", "phase": phase,
           "branch": None if branch == "-" else branch, "pr": None if pr == "-" else int(pr),
           "takenAt": "2026-10-18T09:50:00Z", "heartbeatAt": beat}
if started:
    payload["phaseStartedAt"] = started
row = {"kind": "release-tower", "key": "o/r", "holderDigest": digest, "machine": "m9", "purpose": "release", "phase": phase,
       "payload": payload, "claimedAt": "2026-10-18T09:50:00Z", "heartbeatAt": beat, "phaseStartedAt": started or "2026-10-18T09:50:00Z",
       "expiresAt": expires, "releasedAt": None, "outcome": None}
json.dump({"release-tower|o/r": row}, open(path, "w"))
PY
}
digest() { printf '%s' "$1" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.read().encode()).hexdigest())'; }
claimfile() { python3 -c 'import json,sys; r=json.load(open(sys.argv[1])).get("release-tower|o/r"); print(eval(sys.argv[2], {"r": r}) if r else "<no claim>")' "$DS/claims.json" "$1" 2>/dev/null; }
field() { claimfile "r['payload'].get('$1')"; }   # field NAME — from the stored record
holderd() { claimfile "r['holderDigest']"; }
released() { claimfile "bool(r['releasedAt'])"; }
run() { OUT="$(bash "$P" "$@" 2>&1)"; RC=$?; printf '%s\n' "$OUT" >> "$LOG"; }
keys() { python3 -c 'import json,sys; d=json.load(sys.stdin); r=d.get("record"); print(",".join(sorted(d)), "|", ",".join(sorted(r)) if r else "-")'; }
# ghheld — the same situation under the github provider (a real bare origin; ref seeded by hand)
ghfresh() {
  local g="$STATE/gh"; rm -rf "$g"; mkdir -p "$g"; git init -q --bare "$g/origin.git"
  git init -q -b master "$g/work" 2>/dev/null || { git init -q "$g/work"; git -C "$g/work" checkout -q -b master; }
  git -C "$g/work" commit -q --allow-empty -m init; git -C "$g/work" remote add origin "$g/origin.git"
}
ghseed() { # ghseed JSON
  local head sha; head="$(git -C "$STATE/gh/work" rev-parse HEAD)"
  sha="$(printf 'object %s\ntype commit\ntag release-clearance\ntagger t <t@t> 1 +0000\n\n%s\n' "$head" "$1" | git -C "$STATE/gh/work" hash-object -t tag -w --stdin)"
  git -C "$STATE/gh/work" push -q origin "${sha}:refs/clearance/release"
}

# (1) a claim on a clear server wins; a live holder makes it BUSY; a stuck one exits 5; a stale one
#     with an open pull request is STALE (3); with a closed one it is taken over with the digest
fresh one
run claim --purpose release
J="$(grep -c '"tool": "claim_work"' "$DS/calls.log")"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "^CLEARED $(digest claude:me-1 | cut -c1-12) 2026-10-18T10:05:00Z\$" \
   && [ "$(holderd)" = "$(digest claude:me-1)" ] && [ "$(claimfile "r['expiresAt']")" = 2026-10-18T10:25:00Z ] \
   && [ "$(claimfile "r['kind'] + ' ' + r['key']")" = "release-tower o/r" ] && [ "$(field phase)" = claimed ] && [ "$(field user)" = alice ] \
   && ! grep -q 'claude:me-1' "$DS/claims.json" \
   && [ "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["repo"], d["holder"])' "$CLEARANCE_RECORD")" = "o/r claude:me-1" ] \
   && [ "$(stat -c %a "$CLEARANCE_RECORD" 2>/dev/null || stat -f %Lp "$CLEARANCE_RECORD")" = 600 ] && [ "$J" = 1 ] \
   && grep '"tool": "claim_work"' "$DS/calls.log" | grep -q '"machine": "m9-dan", "sessionName": "rel-1"' \
   && [ "$(field machine)" = m9-dan ]; then
  ok "(1n) the claim and the record name the machine and session the one shared way (m9-dan, rel-1)"
  ok "(1) claim wins → CLEARED <holder digest> <takenAt>; claim release-tower/o/r, expiry = staleMinutes, record in the payload without the raw holder; local record names the real holder, mode 0600"
else bad "(1) rc=$RC: $OUT"; fi
run claim
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'already held by this session; heartbeat renewed'; then ok "(1a) claiming again from the holder session is CLEARED, renewed"; else bad "(1a) rc=$RC: $OUT"; fi

fresh two; held claude:other review release/26-10-18 3981; BEFORE="$(claimfile "r['heartbeatAt']")"
run claim
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q '^BUSY held by bob on m9 since 2026-10-18T09:50:00Z, phase review, heartbeat 5 min ago — release/26-10-18 #3981$' \
   && [ "$(claimfile "r['heartbeatAt']")" = "$BEFORE" ] && [ ! -f "$CLEARANCE_RECORD" ]; then
  ok "(1b) a live holder → BUSY held by <user> on <machine> since …, exit 2; claim untouched"
else bad "(1b) rc=$RC: $OUT"; fi

fresh stuck; held claude:other deploy release/26-10-18 3990 2026-10-18T10:04:00Z 2026-10-18T08:55:00Z
export CLEARANCE_WAIT_MINUTES=0; run claim --wait; A="$RC:$OUT"; export CLEARANCE_WAIT_MINUTES=1
run claim; B="$RC:$OUT"; run status --short; C="$OUT"
if [ "${A%%:*}" -eq 5 ] && printf '%s' "${A#*:}" | head -n 1 | grep -q '^STUCK held by bob .* — STUCK in deploy for 70 min (budget 60 min), session [0-9a-f]\{12\} on m9$' \
   && [ "${B%%:*}" -eq 2 ] && printf '%s' "$B" | grep -q '^2:BUSY .* — STUCK in deploy' && [ "$C" = "release/26-10-18 · bob · deploy · STUCK" ]; then
  ok "(1c) a holder past its phase budget → claim --wait: STUCK, exit 5; plain claim: BUSY with the STUCK note; --short says STUCK"
else bad "(1c) a=$A b=$B c=$C"; fi

fresh stale-open; held claude:other review release/26-10-17 3970 2026-10-18T09:30:00Z
printf '[{"number":3970,"headRefName":"release/26-10-17","state":"OPEN","isDraft":true,"createdAt":"2026-10-18T09:35:00Z"}]' > "$STATE/prs.json"
run claim
if [ "$RC" -eq 3 ] && printf '%s' "$OUT" | grep -q '^STALE held by bob .* — STALE — pull request #3970 still open — adopt or wait$' && [ "$(holderd)" = "$(digest claude:other)" ]; then
  ok "(1d) lapsed claim + open pull request → STALE … adopt or wait; exit 3; untouched"
else bad "(1d) rc=$RC: $OUT"; fi

fresh stale-closed; held claude:other pr release/26-10-17 3970 2026-10-18T09:30:00Z
printf '[{"number":3970,"headRefName":"release/26-10-17","state":"CLOSED"}]' > "$STATE/prs.json"
run claim; OLD="$(digest claude:other)"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'stale clearance taken over' && printf '%s' "$OUT" | grep -q '^CLEARED ' && [ "$(holderd)" = "$(digest claude:me-1)" ] \
   && grep -q "\"takeover\": \"$OLD\"" "$DS/calls.log"; then
  ok "(1e) lapsed claim + closed pull request → claim_work with takeover.expectedHolderDigest = the lapsed row's digest → CLEARED"
else bad "(1e) rc=$RC: $OUT"; fi
fresh stale-none; held claude:other cut release/26-10-17 - 2026-10-18T09:30:00Z
run claim
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'never opened' && [ "$(holderd)" = "$(digest claude:me-1)" ]; then ok "(1f) lapsed claim, no pull request ever opened → taken over"; else bad "(1f) rc=$RC: $OUT"; fi

# a payload heartbeat past staleMinutes is stale even though the server has not lapsed the claim yet
fresh payload-stale; held claude:other cut release/26-10-17 - 2026-10-18T09:30:00Z
python3 - "$DS/claims.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["release-tower|o/r"]["expiresAt"] = "2026-10-18T11:00:00Z"; json.dump(d, open(sys.argv[1], "w"))
PY
run status --short
if [ "$RC" -eq 0 ] && [ "$OUT" = "release/26-10-17 · bob · cut · STALE" ]; then ok "(1g) a record whose heartbeat is older than staleMinutes reads STALE whatever the server's expiry says"; else bad "(1g) rc=$RC: $OUT"; fi

# the same holder, lapsed: its re-claim renews through claim_work (a lapsed claim takes no heartbeat)
fresh own-lapsed; held claude:me-1 review release/26-10-18 3981 2026-10-18T09:30:00Z
run claim
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'heartbeat renewed' && [ "$(claimfile "r['heartbeatAt']")" = 2026-10-18T10:05:00Z ]; then
  ok "(1h) re-claim by the holder of a lapsed claim → CLEARED and the claim is renewed"
else bad "(1h) rc=$RC: $OUT / $(claimfile "r['heartbeatAt']")"; fi

# (2) heartbeat by a non-holder exits 4 and changes nothing; by the holder it updates phase/branch/pr
fresh beat; held claude:other review release/26-10-18 3981
printf '{"repo":"o/r","holder":"claude:me-1"}' > "$CLEARANCE_RECORD"
run heartbeat cut --branch release/26-10-18; A="$RC"
[ "$(field phase)" = review ] && SAME=1 || SAME=0; [ -f "$CLEARANCE_RECORD" ] && LEFT=1 || LEFT=0
fresh beat2; run claim; run heartbeat pr --branch release/26-10-18 --pr '#3990'
if [ "$A" -eq 4 ] && [ "$SAME" = 1 ] && [ "$LEFT" = 0 ] && [ "$RC" -eq 0 ] && [ "$(field phase)" = pr ] && [ "$(field branch)" = release/26-10-18 ] && [ "$(field pr)" = 3990 ] \
   && printf '%s' "$OUT" | grep -q '^HEARTBEAT pr 2026-10-18T10:05:00Z$' \
   && [ "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["branch"], d["pr"])' "$CLEARANCE_RECORD")" = "release/26-10-18 3990" ]; then
  ok "(2) heartbeat: non-holder → NOT HOLDER exit 4, claim untouched, stale local record removed; holder → phase/branch/pr in the payload and locally"
else bad "(2) a=$A same=$SAME left=$LEFT rc=$RC: $OUT"; fi
fresh beat3; run heartbeat claimed
if [ "$RC" -eq 4 ] && printf '%s' "$OUT" | grep -q '^NOT HOLDER: no clearance is held'; then ok "(2b) heartbeat with nothing held → NOT HOLDER, exit 4"; else bad "(2b) rc=$RC: $OUT"; fi

# (3) release by a non-holder exits 4; --force releases; the holder's release; --owed records the work
fresh rel; held claude:other review release/26-10-18 3981
run release; A="$RC"; [ "$(released)" = False ] && KEPT=1 || KEPT=0
run release --force; B="$RC:$OUT"; [ "$(released)" = True ] && GONE=1 || GONE=0
run status; S="$OUT"
if [ "$A" -eq 4 ] && [ "$KEPT" = 1 ] && [ "${B%%:*}" -eq 0 ] && printf '%s' "$B" | grep -q 'forcing release of a clearance held by bob' && [ "$GONE" = 1 ] && printf '%s' "$S" | grep -q '^CLEAR'; then
  ok "(3) release: non-holder → exit 4; --force → released, naming the holder; the claim reads as clear afterwards"
else bad "(3) a=$A kept=$KEPT b=$B gone=$GONE s=$S"; fi
fresh owed; run claim; run heartbeat close-out --branch release/26-10-18 --pr 3990
run release --owed docs --owed close-out; A="$RC:$OUT"; F="$WORK/owed.record.owed.json"
export CLEARANCE_NOW=2026-10-18T10:17:00Z; run status; B="$RC:$OUT"; run status --short; C="$OUT"; run status --json; export CLEARANCE_NOW=2026-10-18T10:05:00Z
if [ "${A%%:*}" -eq 0 ] && [ "$(printf '%s\n' "${A#*:}" | head -n 1)" = "RELEASED release/26-10-18" ] && printf '%s' "$A" | grep -q '^Close-out owed: docs, close-out$' \
   && [ ! -f "$CLEARANCE_RECORD" ] && [ -f "$F" ] && [ "$(released)" = True ] \
   && printf '%s' "$B" | grep -q "^Close-out owed: release/26-10-18 #3990 — docs, close-out (handed back 12 min ago by alice on .*, session $(digest claude:me-1 | cut -c1-12))\$" \
   && [ "$C" = "close-out owed · release/26-10-18 · docs, close-out" ]; then
  ok "(3a) release --owed → RELEASED first, then Close-out owed; the owed work shows in status and --short (and --json, swept by 12)"
else bad "(3a) a=$A b=$B c=$C"; fi
run owed --done docs --done close-out; if [ "$RC" -eq 0 ] && [ "$OUT" = NONE ] && [ ! -f "$F" ]; then ok "(3b) owed --done settles it; NONE"; else bad "(3b) rc=$RC: $OUT"; fi
fresh owed-legacy; F="$WORK/owed-legacy.record.owed.json"
# this session's entry is the OLDER one and both owe the same work, so only a holder match settles it
printf '{"entries": [{"repo": "o/r", "release": "release/26-10-17", "pr": 3980, "holder": "claude:me-1", "user": "alice", "machine": "m1", "handedBackAt": "2026-10-18T09:00:00Z", "owed": ["notes"]}, {"repo": "o/r", "release": "release/26-10-18", "pr": 3990, "holder": "claude:other", "user": "bob", "machine": "m9", "handedBackAt": "2026-10-18T10:00:00Z", "owed": ["notes"]}]}' > "$F"; chmod 600 "$F"
run status; A="$OUT"; run status --json; B="$OUT"; run owed --done notes; C="$RC:$OUT"; run status --json; D="$OUT"
if ! printf '%s%s%s' "$A" "$B" "$D" | grep -qF 'claude:' && printf '%s' "$D" | grep -q 'release/26-10-18' && ! printf '%s' "$D" | grep -q 'release/26-10-17' && [ "${C%%:*}" -eq 0 ]; then
  ok "(3b2) an owed file from before holders were digests: no raw holder printed (status, --json); --done settles this session's own entry"
else bad "(3b2) a=$A b=$B c=$C d=$D"; fi
fresh rel-own; run claim; run release; A="$RC:$OUT"
if [ "${A%%:*}" -eq 0 ] && printf '%s' "$A" | grep -q 'RELEASED' && [ "$(released)" = True ] && [ ! -f "$CLEARANCE_RECORD" ]; then ok "(3c) release by the holder → claim released, local record removed"; else bad "(3c) $A"; fi
run claim
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^CLEARED'; then ok "(3d) a released claim reads as clear: the next claim wins"; else bad "(3d) rc=$RC: $OUT"; fi

# (4) adopt --yes: a lapsed claim, the digest of the claim read goes with the call
fresh adopt; held claude:other review release/26-10-17 3970 2026-10-18T09:30:00Z
run adopt --yes
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^ADOPTED release/26-10-17 #3970$' && printf '%s' "$OUT" | grep -q '^Resume: branch release/26-10-17, pull request #3970, phase review$' \
   && [ "$(holderd)" = "$(digest claude:me-1)" ] && [ "$(field takenAt)" = 2026-10-18T09:50:00Z ] && [ "$(field heartbeatAt)" = 2026-10-18T10:05:00Z ] \
   && grep -q "\"expectedHolderDigest\": \"$(digest claude:other)\"" "$DS/calls.log" \
   && grep '"tool": "adopt_claim"' "$DS/calls.log" | grep -q '"machine": "m9-dan", "sessionName": "rel-1"' \
   && [ "$(field machine)" = m9-dan ]; then
  ok "(4n) adopt names the machine and session the one shared way"
  ok "(4) adopt --yes → adopt_claim with the expected digest; holder rewritten, heartbeat now, takenAt kept; Resume line"
else bad "(4) rc=$RC: $OUT"; fi
fresh adopt-fresh; held claude:other review release/26-10-18 3981
run adopt --yes; A="$RC:$OUT"; run adopt; B="$RC"
if [ "${A%%:*}" -eq 2 ] && printf '%s' "$A" | grep -q 'not stale, nothing to adopt' && [ "$B" -eq 1 ] && [ "$(holderd)" = "$(digest claude:other)" ]; then
  ok "(4a) adopt on a live claim → BUSY … not stale (exit 2); adopt without --yes → error"
else bad "(4a) $A / $B"; fi
fresh adopt-stuck; held claude:other deploy release/26-10-18 3990 2026-10-18T10:04:00Z 2026-10-18T08:55:00Z
run adopt --yes; A="$RC:$OUT"; H1="$(holderd)"
run adopt --yes --original-stopped; B="$RC:$OUT"
if [ "${A%%:*}" -eq 2 ] && printf '%s' "$A" | grep -q 'stuck but alive: adopt only on the owner.s yes, once the original session has stopped' && [ "$H1" = "$(digest claude:other)" ] \
   && [ "${B%%:*}" -eq 0 ] && printf '%s' "$B" | grep -q '^ADOPTED release/26-10-18 #3990$' && [ "$(holderd)" = "$(digest claude:me-1)" ] \
   && [ "$(field phaseStartedAt)" = 2026-10-18T10:05:00Z ] && [ "$(field phase)" = deploy ]; then
  ok "(4b) adopt a stuck, live claim: refused (exit 2) without --original-stopped; with it → ADOPTED, phase kept, its clock restarted"
else bad "(4b) a=$A b=$B"; fi
fresh adopt-none; run adopt --yes
if [ "$RC" -eq 4 ] && printf '%s' "$OUT" | grep -q '^NOT HOLDER: no clearance to adopt'; then ok "(4c) adopt with nothing held → NOT HOLDER, exit 4"; else bad "(4c) rc=$RC: $OUT"; fi

# (5) status --json carries exactly the github provider's keys, held, clear and unknown; --short is silent on failure
fresh keys; held claude:other ci release/26-10-18 3981 2026-10-18T10:00:00Z 2026-10-18T09:50:00Z
RECORD='{"v":1,"repo":"o/r","holder":"claude:other","user":"bob","machine":"m9","purpose":"release","phase":"ci","branch":"release/26-10-18","pr":3981,"takenAt":"2026-10-18T09:50:00Z","heartbeatAt":"2026-10-18T10:00:00Z","phaseStartedAt":"2026-10-18T09:50:00Z"}'
printf '[{"number":3981,"headRefName":"release/26-10-18","state":"OPEN","isDraft":false,"createdAt":"2026-10-18T09:52:00Z"}]' > "$STATE/prs.json"
ghfresh; ghseed "$RECORD"
A="$(bash "$P" status --json 2>/dev/null | keys)"; B="$(cd "$STATE/gh/work" && CLEARANCE_REF= bash "$G" status --json 2>/dev/null | keys)"
fresh keys2; ghfresh
C="$(bash "$P" status --json 2>/dev/null | keys)"; D="$(cd "$STATE/gh/work" && bash "$G" status --json 2>/dev/null | keys)"
printf '' > "$DS/mode"; printf 'http403' > "$DS/mode"
E="$(bash "$P" status --json 2>/dev/null | keys)"; git -C "$STATE/gh/work" remote set-url origin "$WORK/no-such-origin.git"
F="$(cd "$STATE/gh/work" && bash "$G" status --json 2>/dev/null | keys)"
if [ -n "$A" ] && [ "$A" = "$B" ] && [ -n "$C" ] && [ "$C" = "$D" ] && [ -n "$E" ] && [ "$E" = "$F" ]; then
  ok "(5) status --json: the same top-level and record keys as the github provider when held, when clear and when unreadable"
else bad "(5) held: $A vs $B / clear: $C vs $D / unknown: $E vs $F"; fi
run status --short; S="$RC:$OUT"; run status; T="$RC:$OUT"; run status --json; U="$RC:$OUT"
if [ "$S" = "1:" ] && [ "${T%%:*}" -eq 1 ] && printf '%s' "$T" | grep -q '^1:UNKNOWN (DevStride refused the request (HTTP 403)' && printf '%s' "$U" | grep -q '"state": "unknown"'; then
  ok "(5a) a refused server → UNKNOWN (…) exit 1, --json state unknown; --short prints nothing at all"
else bad "(5a) short=$S status=$T json=$U"; fi
fresh clear2; run status; A="$RC:$OUT"; run status --short; B="$RC:$OUT"
if [ "$A" = "0:CLEAR" ] && [ "$B" = "0:" ]; then ok "(5b) clear → CLEAR; --short prints nothing"; else bad "(5b) $A / $B"; fi
fresh statusfacts; held claude:other ci release/26-10-18 3981
cat > "$STATE/prs.json" <<'J'
[{"number":3985,"headRefName":"release/26-10-18-2","state":"OPEN","isDraft":true,"createdAt":"2026-10-18T09:58:00Z"},
 {"number":3981,"headRefName":"release/26-10-18","state":"OPEN","isDraft":false,"createdAt":"2026-10-18T09:52:00Z"},
 {"number":3983,"headRefName":"phil/hotfix/26-10-18/I1-fix","state":"MERGED","mergedAt":"2026-10-18T10:01:00Z"}]
J
run status
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^Clearance: held by bob on m9 since 2026-10-18T09:50:00Z, phase ci, heartbeat 5 min ago — release/26-10-18 #3981$' \
   && printf '%s' "$OUT" | grep -q '^On final: #3981 release/26-10-18$' && printf '%s' "$OUT" | grep -q '^Waiting: #3985 release/26-10-18-2 (draft)$' \
   && printf '%s' "$OUT" | grep -q '^Hotfix landed: #3983 phil/hotfix/26-10-18/I1-fix 2026-10-18T10:01:00Z$'; then
  ok "(5c) status: Clearance line, On final / Waiting / Hotfix landed still come from gh"
else bad "(5c) rc=$RC: $OUT"; fi

# (6) a server without the claim tools: exit 1 with the version message
fresh absent; printf 'unknown-tool' > "$DS/mode"
run claim; A="$RC:$OUT"; printf '9.9.9' > "$DS/version"; run claim; B="$RC:$OUT"; run status --short; C="$RC:$OUT"
if [ "${A%%:*}" -eq 1 ] && printf '%s' "$A" | grep -q 'ERROR: this DevStride server has no claim tools (claim_work); it needs a release with agent claims (server version unknown)' \
   && [ "${B%%:*}" -eq 1 ] && printf '%s' "$B" | grep -q '(server version 9.9.9)' && [ "$C" = "1:" ]; then
  ok "(6) unknown tool → exit 1 naming claim_work and the server version (or 'unknown'); --short silent"
else bad "(6) a=$A b=$B c=$C"; fi

# (7) a refused key and a missing permission both name MANAGE_AGENT_CLAIMS
fresh refused; printf 'http403' > "$DS/mode"; run claim; A="$RC:$OUT"
printf 'forbidden' > "$DS/mode"; run claim; B="$RC:$OUT"
printf '' > "$DS/mode"; DEVSTRIDE_API_SECRET=wrong-secret-xyz run claim; C="$RC:$OUT"
if [ "${A%%:*}" -eq 1 ] && printf '%s' "$A" | grep -q 'MANAGE_AGENT_CLAIMS' && [ "${B%%:*}" -eq 1 ] && printf '%s' "$B" | grep -q 'MANAGE_AGENT_CLAIMS' \
   && [ "${C%%:*}" -eq 1 ] && ! printf '%s' "$C" | grep -q 'wrong-secret-xyz'; then
  ok "(7) HTTP 403 and a tool error naming MANAGE_AGENT_CLAIMS → exit 1 naming the permission; a rejected secret is never echoed"
else bad "(7) a=$A b=$B c=$C"; fi
echo wrong-secret-xyz >> "$WORK/secrets-to-find"

# (7a) transport: one 500 is retried; SSE answers are read; a base URL off the allowed hosts is refused; no redirects
fresh transport; : > "$DS/fail-once"; run claim; A="$RC:$OUT"
fresh sse; : > "$DS/sse"; run claim; B="$RC:$OUT"; run status --json; J="$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])')"
fresh badurl; unset CLEARANCE_DEVSTRIDE_TEST_URL; DEVSTRIDE_BASE_URL=http://evil.example run claim; C="$RC:$OUT"
DEVSTRIDE_BASE_URL=https://api.devstride.com.evil.example run claim; D="$RC:$OUT"
if [ "${A%%:*}" -eq 0 ] && [ "${B%%:*}" -eq 0 ] && [ "$J" = held ] && [ "${C%%:*}" -eq 1 ] && printf '%s' "$C" | grep -q 'DEVSTRIDE_BASE_URL must be' && [ "${D%%:*}" -eq 1 ]; then
  ok "(7a) a 500 is retried once; a text/event-stream answer is read; a base URL off api(-x).devstride.com/.dev is refused"
else bad "(7a) a=$A b=$B j=$J c=$C d=$D"; fi

# (7b) a redirect is never followed (credentials never travel to where it points); a trailing newline cannot pass the allow-list
fresh redirect; printf 'redirect' > "$DS/mode"; run claim; A="$RC:$OUT"
printf '' > "$DS/mode"
B="$( ( unset CLEARANCE_DEVSTRIDE_TEST_URL; DEVSTRIDE_BASE_URL='https://api.devstride.com
' bash "$P" claim 2>&1 ); echo "rc=$?")"; printf '%s\n' "$B" >> "$LOG"
if [ "${A%%:*}" -eq 1 ] && [ ! -e "$DS/followed" ] && printf '%s' "$A" | grep -q 'HTTP 307' \
   && printf '%s' "$B" | grep -q 'DEVSTRIDE_BASE_URL must be' && printf '%s' "$B" | grep -q 'rc=1$' && ! printf '%s' "$B" | grep -q Traceback; then
  ok "(7b) a 307 from the server is reported, never followed; a base URL with a trailing newline is refused"
else bad "(7b) a=$A followed=$([ -e "$DS/followed" ] && echo yes || echo no) b=$B"; fi

# (8) credentialsFile: used for what the environment leaves unset; a file open to group or other is refused
fresh creds; unset DEVSTRIDE_API_KEY DEVSTRIDE_API_SECRET DEVSTRIDE_ORG_ID
mkdir -p .claude; printf '{"release":{"clearance":{"provider":"devstride","credentialsFile":"creds.env"}}}' > .claude/ds-config.json
printf '# DevStride\nDEVSTRIDE_API_KEY=test-key\nexport DEVSTRIDE_API_SECRET="test-secret"\nDEVSTRIDE_ORG_ID=org-1\n' > creds.env
chmod 644 creds.env; run claim; A="$RC:$OUT"
chmod 600 creds.env; run claim; B="$RC:$OUT"
mkdir -p "$HOME"; cp creds.env "$HOME/ds.env"; chmod 600 "$HOME/ds.env"; rm creds.env
printf '{"release":{"clearance":{"provider":"devstride","credentialsFile":"~/ds.env"}}}' > .claude/ds-config.json; run status --short; C="$RC:$OUT"
printf '{"release":{"clearance":{"provider":"devstride"}}}' > .claude/ds-config.json; run claim; D="$RC:$OUT"
export DEVSTRIDE_API_KEY=test-key DEVSTRIDE_API_SECRET=test-secret DEVSTRIDE_ORG_ID=org-1
if [ "${A%%:*}" -eq 1 ] && printf '%s' "$A" | grep -q 'creds.env is readable by others — chmod 600' && ! printf '%s' "$A" | grep -q 'test-secret' \
   && [ "${B%%:*}" -eq 0 ] && printf '%s' "$B" | grep -q '^0:CLEARED' && [ "$C" = "0:$(printf 'release · alice · claimed')" ] \
   && [ "${D%%:*}" -eq 1 ] && printf '%s' "$D" | grep -q 'DevStride credentials missing (DEVSTRIDE_API_KEY, DEVSTRIDE_API_SECRET, DEVSTRIDE_ORG_ID)'; then
  ok "(8) credentialsFile: mode 0644 refused (names the file, chmod 600); 0600 accepted (relative to the repository root, and with ~/); no file and no environment → missing, naming the variables"
else bad "(8) a=$A b=$B c=$C d=$D"; fi

# (9) identity: the holder rule is one rule — both providers print the same string; none → exit 1
fresh ident; A="$(bash "$P" identity)"; B="$(bash "$G" identity)"
export CLEARANCE_HOLDER_TOKEN=tok-1; C="$(bash "$P" identity)"; D="$(bash "$G" identity)"; unset CLEARANCE_HOLDER_TOKEN
export CODEX_THREAD_ID=c-9; E="$(bash "$P" identity)"; F="$(bash "$G" identity)"; unset CODEX_THREAD_ID
export DEVSTRIDE_LEASE_TOKEN=old-1; G1="$(bash "$P" identity)"; unset DEVSTRIDE_LEASE_TOKEN
unset CLAUDE_CODE_SESSION_ID; bash "$P" identity >/dev/null 2>"$WORK/id.err"; X1=$?; bash "$G" identity >/dev/null 2>&1; X2=$?; export CLAUDE_CODE_SESSION_ID=me-1
NOGH="$WORK/nogh"; mkdir -p "$NOGH"; for t in python3 bash dirname basename; do ln -sf "$(command -v $t)" "$NOGH/$t"; done
H="$(PATH="$NOGH" bash "$P" identity 2>&1)"; H2="$(PATH="$NOGH" bash "$G" identity 2>&1)"
if [ "$A" = claude:me-1 ] && [ "$A" = "$B" ] && [ "$C" = tok-1 ] && [ "$C" = "$D" ] && [ "$E" = "codex:c-9+claude:me-1" ] && [ "$E" = "$F" ] && [ "$G1" = old-1 ] \
   && [ "$X1" -eq 1 ] && [ "$X2" -eq 1 ] && grep -q '^ERROR: no identity' "$WORK/id.err" && [ "$H" = claude:me-1 ] && [ "$H2" = claude:me-1 ]; then
  ok "(9) identity prints the holder (token, codex+claude, session) identically in both providers, exits 1 with no source, and needs neither gh nor git"
else bad "(9) a=$A b=$B c=$C d=$D e=$E f=$F g=$G1 x=$X1/$X2 h=$H h2=$H2"; fi

# (10) the keeper re-stamps the claim through heartbeat_claim, tied to the owning process
fresh keeper; unset CLEARANCE_NO_KEEPER CLEARANCE_NOW; rm -f "$DS/now"
sleep 300 & OWNER=$!
export CLEARANCE_OWNER_PID=$OWNER CLEARANCE_KEEPER_SECONDS=1
run claim; KPID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["keeperPid"])' "$CLEARANCE_RECORD" 2>/dev/null)"
T0="$(claimfile "r['heartbeatAt']")"; sleep 3; T1="$(claimfile "r['heartbeatAt']")"; P1="$(field phaseStartedAt)"; PS="$(claimfile "r['payload']['takenAt']")"
kill "$OWNER" 2>/dev/null; wait "$OWNER" 2>/dev/null; sleep 3; kill -0 "$KPID" 2>/dev/null && KALIVE=1 || KALIVE=0
if [ "$RC" -eq 0 ] && [ -n "$KPID" ] && [ "$T1" \> "$T0" ] && [ "$KALIVE" = 0 ] && grep -q '"tool": "heartbeat_claim"' "$DS/calls.log"; then
  ok "(10) a claim starts a keeper (pid $KPID) that heartbeats the DevStride claim and exits with its owning process"
else bad "(10) rc=$RC keeper=$KPID t0=$T0 t1=$T1 alive=$KALIVE"; fi
export CLEARANCE_NO_KEEPER=1 CLEARANCE_NOW=2026-10-18T10:05:00Z; unset CLEARANCE_OWNER_PID CLEARANCE_KEEPER_SECONDS

# (11) a claim lost to a concurrent taker: two sessions take over one lapsed claim; exactly one wins
fresh two-takers; held claude:other cut release/26-10-17 - 2026-10-18T09:30:00Z
# Both takers run from THIS shell, each writing its own file, and the wait names the one pid it
# started: a bare `wait` inside a command substitution can spin forever on Linux bash ("pid N is
# not a child of this shell"), which hung the whole release-guard job.
CLAUDE_CODE_SESSION_ID=me-1 bash "$P" claim > "$WORK/taker1.out" 2>&1 & TAKER1=$!
CLAUDE_CODE_SESSION_ID=me-2 CLEARANCE_RECORD="$WORK/two-takers.record2.json" bash "$P" claim > "$WORK/taker2.out" 2>&1
wait "$TAKER1"
OUT1="$(cat "$WORK/taker1.out" "$WORK/taker2.out")"
printf '%s\n' "$OUT1" >> "$LOG"
WINS="$(printf '%s\n' "$OUT1" | grep -c '^CLEARED')"; BUSY="$(printf '%s\n' "$OUT1" | grep -c '^BUSY')"
if [ "$WINS" -eq 1 ] && [ "$BUSY" -eq 1 ]; then ok "(11) two concurrent takeovers of one lapsed claim → one CLEARED, one BUSY (the server decides)"; else bad "(11) wins=$WINS busy=$BUSY: $OUT1"; fi

# (13) the session's display name travels as the claim's own sessionName, never as the payload key
#      `session` (the server reserves it and refuses the whole call); status reads it back from
#      sessionName; a heartbeat keeps it; an adopter's own name replaces it
fresh sessname
CLEARANCE_SESSION_NAME="wt2-9f" run claim --purpose release; A="$RC"
P1="$(claimfile "'session' in (r['payload'] or {})")"; N1="$(claimfile "r['sessionName']")"
J="$(bash "$P" status --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["record"].get("session"))')"
LINE="$(bash "$P" status 2>/dev/null | head -1)"
CLEARANCE_SESSION_NAME="" DEVSTRIDE_SESSION="" run heartbeat cut --branch release/26-10-18; B="$RC"
P2="$(claimfile "'session' in (r['payload'] or {})")"; N2="$(claimfile "r['sessionName']")"
fresh sessadopt; held claude:other review release/26-10-18 3981 2026-10-18T09:00:00Z
CLEARANCE_SESSION_NAME="adopter" run adopt --yes; C="$RC"
P3="$(claimfile "'session' in (r['payload'] or {})")"; N3="$(claimfile "r['sessionName']")"
if [ "$A" -eq 0 ] && [ "$P1" = False ] && [ "$N1" = wt2-9f ] && [ "$J" = wt2-9f ] \
   && printf '%s' "$LINE" | grep -q '^Clearance: held by alice on m9-dan (session wt2-9f) since ' \
   && [ "$B" -eq 0 ] && [ "$P2" = False ] && [ "$N2" = wt2-9f ] \
   && [ "$C" -eq 0 ] && [ "$P3" = False ] && [ "$N3" = adopter ]; then
  ok "(13) session name: sent as sessionName, never the reserved payload key; status shows it; a heartbeat keeps it; an adopter's name replaces it"
else bad "(13) a=$A p1=$P1 n1=$N1 j=$J line=$LINE b=$B p2=$P2 n2=$N2 c=$C p3=$P3 n3=$N3"; fi

# (12) nothing a script printed, in any case above, contains the key, the secret or a holder
LEAK=""
for needle in test-key test-secret wrong-secret-xyz claude:me-1 claude:other claude:me-2 codex:c-9 tok-1 old-1; do
  if grep -qF -- "$needle" "$LOG"; then LEAK="$LEAK $needle"; fi
done
if [ -z "$LEAK" ] && [ -s "$LOG" ]; then ok "(12) across every captured output: no key, no secret, no holder string"; else bad "(12) leaked:$LEAK"; fi

exit $FAIL
