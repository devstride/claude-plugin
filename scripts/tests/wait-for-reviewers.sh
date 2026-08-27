#!/bin/bash
# Tests for skills/review/scripts/wait-for-reviewers.sh — all --dry-run, a temp --cache, no network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; W="$ROOT/skills/review/scripts/wait-for-reviewers.sh"; FX="$ROOT/scripts/tests/fixtures/wait"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
A='{"name":"Bot A","graphqlBotId":"BOT_aaaa","reviewsLogin":"bot-a[bot]","registeredAt":"2026-01-01T10:00:00Z"}'
B='{"name":"Bot B","graphqlBotId":"BOT_bbbb","reviewsLogin":"bot-b[bot]","registeredAt":"2026-01-01T10:00:00Z"}'
warm() { python3 -c 'import json,sys
vals=[int(v) for v in sys.argv[2].split(",")]
json.dump({"version":1,"reviewers":{sys.argv[3]:{"samples":[{"at":"2026-01-01T00:00:00Z","latencySeconds":v,"repo":"o/r","pr":1} for v in vals]}}},open(sys.argv[1],"w"))' "$@"; }
run() { # run FIXTURE CACHE REVIEWERS_JSON [extra args...] -> sets OUT RC RESULT
  local fx="$1" cache="$2" rev="$3"; shift 3
  OUT="$(printf '%s' "$rev" | /bin/bash "$W" --dry-run "$FX/$fx" --repo o/r --pr 1 --reviewers-json - --timeout-minutes 20 --cache "$cache" "$@" 2>&1)"; RC=$?
  RESULT="$(printf '%s\n' "$OUT" | sed -n 's/^RESULT //p' | tail -1)"
}
field() { printf '%s' "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1" 2>/dev/null; }

# (1) cold no-show → timeout, 1,200 s, ≤ 16 calls
run no-show-cold.json "$TMP/c1.json" "[$A]" --since-review-id 0
if [ "$RC" -eq 3 ] && [ "$(field 'd["result"]')" = timeout ] && [ "$(field 'd["elapsedSeconds"]')" -eq 1200 ] && [ "$(field 'd["pollCalls"]')" -le 16 ]; then ok "(1) cold no-show → timeout at 1,200 s, $(field 'd["pollCalls"]') calls (≤ 16), exit 3"; else bad "(1) got rc=$RC $RESULT"; fi

# (2) warm no-show (12 samples, p95 180) → proceed-p95, ≤ 300 s, ≤ 7 calls
warm "$TMP/c2.json" 150,160,170,175,180,165,155,178,180,172,168,160,900,100,120,130,140,145,150,175 BOT_aaaa
run no-show-warm.json "$TMP/c2.json" "[$A]" --since-review-id 0
if [ "$RC" -eq 3 ] && [ "$(field 'd["result"]')" = proceed-p95 ] && [ "$(field 'd["elapsedSeconds"]')" -eq 300 ] && [ "$(field 'd["pollCalls"]')" -le 7 ] && [ "$(field 'd["nonResponders"][0]["boundSource"]')" = learned-p95 ]; then ok "(2) warm no-show (20 samples, one 900 s outlier; p95 = 19th = 180, not the max) → proceed-p95 at exactly 300 s, $(field 'd["pollCalls"]') calls"; else bad "(2) got rc=$RC $RESULT"; fi

# (3) responder at 156 s → all-posted within latency + one max tick; sample is exactly 156 (server timestamps)
run responder-156.json "$TMP/c3.json" "[$A]" --since-review-id 0
S3="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["reviewers"]["BOT_aaaa"]["samples"][-1]["latencySeconds"])' "$TMP/c3.json" 2>/dev/null)"
if [ "$RC" -eq 0 ] && [ "$(field 'd["result"]')" = all-posted ] && [ "$(field 'd["elapsedSeconds"]')" -le 246 ] && [ "$S3" = 156 ]; then ok "(3) responder at 156 s → all-posted at $(field 'd["elapsedSeconds"]') s; cached sample 156"; else bad "(3) rc=$RC sample=$S3 $RESULT"; fi

# (4) corrupt cache → behaves cold, cacheState corrupt, no crash
echo '{ not json' > "$TMP/c4.json"
run no-show-cold.json "$TMP/c4.json" "[$A]" --since-review-id 0
if [ "$RC" -eq 3 ] && [ "$(field 'd["result"]')" = timeout ] && [ "$(field 'd["cacheState"]')" = corrupt ]; then ok "(4) corrupt cache → cold behaviour, cacheState corrupt"; else bad "(4) rc=$RC $RESULT"; fi

# (5) unwritable cache directory → still exits normally, cacheState unwritable
if [ "$(id -u)" = 0 ]; then echo "  skip (5) unwritable cache — running as root, chmod cannot block the write"; else
mkdir -p "$TMP/ro" && chmod 555 "$TMP/ro"
run responder-156.json "$TMP/ro/c5.json" "[$A]" --since-review-id 0
if [ "$RC" -eq 0 ] && [ "$(field 'd["cacheState"]')" = unwritable ] && [ ! -e "$TMP/ro/c5.json" ]; then ok "(5) unwritable cache → all-posted still, cacheState unwritable, nothing written"; else bad "(5) rc=$RC $RESULT"; fi
chmod 755 "$TMP/ro"; fi

# (6) two reviewers, one posts at 100 s, the other never → exit when the second passes ITS bound; both named
warm "$TMP/c6.json" 150,160,170,175,180,165,155,178,180,172,168,160 BOT_bbbb
run two-reviewers.json "$TMP/c6.json" "[$A,$B]" --since-review-id 0
if [ "$RC" -eq 3 ] && [ "$(field 'd["responded"][0]["graphqlBotId"]')" = BOT_aaaa ] && [ "$(field 'd["responded"][0]["latencySeconds"]')" = 100 ] && [ "$(field 'd["nonResponders"][0]["graphqlBotId"]')" = BOT_bbbb ] && [ "$(field 'd["elapsedSeconds"]')" -eq 300 ]; then ok "(6) two reviewers → A responded (100 s), the wait ran on to B's own 300 s bound exactly"; else bad "(6) rc=$RC $RESULT"; fi

# (7) --fixed-bound with a warm cache → the full 1,200 s, and a responder's sample is still recorded
warm "$TMP/c7.json" 150,160,170,175,180,165,155,178,180,172,168,160 BOT_aaaa
run no-show-warm.json "$TMP/c7.json" "[$A]" --since-review-id 0 --fixed-bound
run7a="$RESULT"; rc7a=$RC
run responder-156.json "$TMP/c7.json" "[$A]" --since-review-id 0 --fixed-bound
N7="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["reviewers"]["BOT_aaaa"]["samples"]))' "$TMP/c7.json")"
if [ "$rc7a" -eq 3 ] && printf '%s' "$run7a" | grep -q '"elapsedSeconds":1200' && printf '%s' "$run7a" | grep -q '"boundSource":"fixed"' && [ "$N7" = 13 ]; then ok "(7) --fixed-bound → 1,200 s with a warm cache; sample still recorded (12 → 13)"; else bad "(7) rc=$rc7a n=$N7 $run7a"; fi

# (8) window floor: p95 = 40 s → bound = max(40+120, 120) = 160 s ≥ the 2-minute window
warm "$TMP/c8.json" 30,35,40,38,40,36,39,40 BOT_aaaa
run no-show-warm.json "$TMP/c8.json" "[$A]" --since-review-id 0
if [ "$(field 'd["nonResponders"][0]["boundSeconds"]')" = 160 ]; then ok "(8) p95 40 s → bound 160 s (≥ 120 s window)"; else bad "(8) bound=$(field 'd["nonResponders"][0]["boundSeconds"]') $RESULT"; fi
warm "$TMP/c8b.json" 1,1,1,1,1,1 BOT_aaaa
run no-show-warm.json "$TMP/c8b.json" "[$A]" --since-review-id 0 --slack-seconds 0
if [ "$(field 'd["nonResponders"][0]["boundSeconds"]')" = 120 ]; then ok "(8b) p95 1 s, slack 0 → clamped up to the 120 s window"; else bad "(8b) bound=$(field 'd["nonResponders"][0]["boundSeconds"]')"; fi

# (9) a stale review (id ≤ high-water) from the same reviewer is ignored
run stale-review.json "$TMP/c9.json" "[$A]" --since-review-id 45
if [ "$RC" -eq 3 ] && [ "$(field 'd["result"]')" = timeout ] && [ "$(field 'len(d["responded"])')" = 0 ]; then ok "(9) stale review id 40 ≤ mark 45 → not settled on"; else bad "(9) rc=$RC $RESULT"; fi

# (10) registeredAt null → resolved from the timeline (09:58 → latency 180 s); a reviewer with no event → not-registered
run timeline-resolve.json "$TMP/c10.json" '[{"name":"Bot A","graphqlBotId":"BOT_aaaa","registeredAt":null},{"name":"Bot B","graphqlBotId":"BOT_bbbb","registeredAt":null}]' --since-review-id 0
if [ "$RC" -eq 0 ] && [ "$(field 'd["responded"][0]["latencySeconds"]')" = 180 ] && [ "$(field 'd["notRegistered"]')" = "['BOT_bbbb']" ]; then ok "(10) registeredAt resolved from the timeline (latency 180 s); BOT_bbbb not-registered, not waited on"; else bad "(10) rc=$RC $RESULT"; fi

# (11) a review submitted BEFORE the request cannot answer it: not settled on, nothing learned
run negative-latency.json "$TMP/c11.json" "[$A]" --since-review-id 0
if [ "$RC" -eq 3 ] && [ "$(field 'd["result"]')" = timeout ] && [ "$(field 'len(d["responded"])')" = 0 ] && [ ! -e "$TMP/c11.json" ]; then ok "(11) a review predating the request is not this cycle's answer; nothing cached"; else bad "(11) rc=$RC $RESULT"; fi
# (11b) a latency above 24 h is rejected, printed, and not cached
cat > "$TMP/old.json" <<'EOF_FX'
{"now":"2026-01-01T10:00:00Z","reviews":[{"id":95,"user":{"node_id":"BOT_aaaa","login":"bot-a[bot]"},"submitted_at":"2026-01-03T10:00:00Z"}]}
EOF_FX
OUT="$(printf '%s' '[{"name":"Bot A","graphqlBotId":"BOT_aaaa","registeredAt":"2026-01-01T10:00:00Z"}]' | /bin/bash "$W" --dry-run "$TMP/old.json" --repo o/r --pr 1 --reviewers-json - --timeout-minutes 4000 --cache "$TMP/c11b.json" --since-review-id 0 2>&1)"; RC=$?; RESULT="$(printf '%s\n' "$OUT" | sed -n 's/^RESULT //p' | tail -1)"
if [ "$(field 'd["rejectedSamples"][0]["latencySeconds"]')" = 172800 ] && printf '%s' "$OUT" | grep -q "^rejected sample" && [ ! -e "$TMP/c11b.json" ]; then ok "(11b) a 48 h latency is rejected and printed; nothing cached"; else bad "(11b) rc=$RC $RESULT"; fi

# (12) gh unavailable three ticks running → gh-unavailable, every reviewer a non-responder with that boundSource
run gh-down.json "$TMP/c12.json" "[$A]" --since-review-id 0
if [ "$RC" -eq 3 ] && [ "$(field 'd["result"]')" = gh-unavailable ] && [ "$(field 'd["nonResponders"][0]["boundSource"]')" = gh-unavailable ]; then ok "(12) three consecutive gh failures → gh-unavailable, exit 3"; else bad "(12) rc=$RC $RESULT"; fi

# (13) usage: a missing required flag is exit 2, never a hang
OUT="$(/bin/bash "$W" --repo o/r --pr 1 2>&1)"; RC=$?
if [ "$RC" -eq 2 ]; then ok "(13) missing --reviewers-json/--timeout-minutes → exit 2"; else bad "(13) rc=$RC"; fi

# (14) a reviewer past its OWN bound is frozen: a late post is recorded but the result is not all-posted
warm "$TMP/c14.json" 150,160,170,175,180,165,155,178,180,172,168,160 BOT_aaaa
cat > "$TMP/late.json" <<'EOF_FX'
{"now":"2026-01-01T10:00:00Z","reviews":[{"id":90,"user":{"node_id":"BOT_aaaa","login":"bot-a[bot]"},"submitted_at":"2026-01-01T10:06:00Z"}]}
EOF_FX
OUT="$(printf '%s' "[$A,$B]" | /bin/bash "$W" --dry-run "$TMP/late.json" --repo o/r --pr 1 --reviewers-json - --timeout-minutes 20 --cache "$TMP/c14.json" --since-review-id 0 2>&1)"; RC=$?; RESULT="$(printf '%s\n' "$OUT" | sed -n 's/^RESULT //p' | tail -1)"
if [ "$RC" -eq 3 ] && [ "$(field 'd["result"]')" = timeout ] && [ "$(field 'd["nonResponders"][0]["graphqlBotId"]')" = BOT_aaaa ] && [ "$(field 'd["nonResponders"][0]["respondedLate"]["latencySeconds"]')" = 360 ] && [ "$(field 'd["responded"][0]["latencySeconds"]')" = 360 ]; then ok "(14) A froze at its 300 s bound; its 360 s post is recorded as late; B ran to the full bound so the result is timeout"; else bad "(14) rc=$RC $RESULT"; fi

# (15) gh-unavailable after a response keeps the response and learns it
cat > "$TMP/outage.json" <<'EOF_FX'
{"now":"2026-01-01T10:00:00Z","reviews":[{"id":91,"user":{"node_id":"BOT_aaaa","login":"bot-a[bot]"},"submitted_at":"2026-01-01T10:00:10Z"}],"failTicks":[1,2,3]}
EOF_FX
OUT="$(printf '%s' "[$A,$B]" | /bin/bash "$W" --dry-run "$TMP/outage.json" --repo o/r --pr 1 --reviewers-json - --timeout-minutes 20 --cache "$TMP/c15.json" --since-review-id 0 2>&1)"; RC=$?; RESULT="$(printf '%s\n' "$OUT" | sed -n 's/^RESULT //p' | tail -1)"
N15="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["reviewers"]["BOT_aaaa"]["samples"]))' "$TMP/c15.json" 2>/dev/null)"
if [ "$RC" -eq 3 ] && [ "$(field 'd["result"]')" = gh-unavailable ] && [ "$(field 'd["responded"][0]["graphqlBotId"]')" = BOT_aaaa ] && [ "$N15" = 1 ] && [ "$(field 'd["nonResponders"][0]["graphqlBotId"]')" = BOT_bbbb ]; then ok "(15) outage after A responded → gh-unavailable keeps A's response and its sample; B is the non-responder"; else bad "(15) rc=$RC n=$N15 $RESULT"; fi

# (16) the baseline fetch failing three times → gh-unavailable, never since=0
cat > "$TMP/nobase.json" <<'EOF_FX'
{"now":"2026-01-01T10:00:00Z","reviews":[{"id":5,"user":{"node_id":"BOT_aaaa","login":"bot-a[bot]"},"submitted_at":"2025-01-01T10:00:00Z"}],"failTicks":[0,1,2]}
EOF_FX
OUT="$(printf '%s' "[$A]" | /bin/bash "$W" --dry-run "$TMP/nobase.json" --repo o/r --pr 1 --reviewers-json - --timeout-minutes 20 --cache "$TMP/c16.json" 2>&1)"; RC=$?; RESULT="$(printf '%s\n' "$OUT" | sed -n 's/^RESULT //p' | tail -1)"
if [ "$RC" -eq 3 ] && [ "$(field 'd["result"]')" = gh-unavailable ] && [ "$(field 'len(d["responded"])')" = 0 ]; then ok "(16) baseline fetch fails ×3 → gh-unavailable, the historical review is NOT settled on"; else bad "(16) rc=$RC $RESULT"; fi

# (17) the timeline event's own field name, created_at, is accepted as the registration time
run responder-156.json "$TMP/c17.json" '[{"name":"Bot A","graphqlBotId":"BOT_aaaa","created_at":"2026-01-01T10:00:00Z"}]' --since-review-id 0
if [ "$RC" -eq 0 ] && [ "$(field 'd["responded"][0]["latencySeconds"]')" = 156 ]; then ok "(17) created_at accepted as registeredAt"; else bad "(17) rc=$RC $RESULT"; fi

# (18) the default high-water path: no --since-review-id → the baseline fetch is tick 1, and a review already posted BEFORE launch (id ≤ mark) is excluded
cat > "$TMP/hw.json" <<'EOF_FX'
{"now":"2026-01-01T10:00:00Z","reviews":[{"id":40,"user":{"node_id":"BOT_aaaa","login":"bot-a[bot]"},"submitted_at":"2025-12-31T09:00:00Z"}]}
EOF_FX
OUT="$(printf '%s' "[$A]" | /bin/bash "$W" --dry-run "$TMP/hw.json" --repo o/r --pr 1 --reviewers-json - --timeout-minutes 20 --cache "$TMP/c18.json" 2>&1)"; RC=$?; RESULT="$(printf '%s\n' "$OUT" | sed -n 's/^RESULT //p' | tail -1)"
if [ "$(field 'd["sinceReviewId"]')" = 40 ] && [ "$(field 'd["result"]')" = timeout ] && [ "$(field 'd["pollCalls"]')" -le 17 ] && [ "$(field 'd["cacheState"]')" = cold ]; then ok "(18) no --since → mark established at 40 from the baseline fetch, stale review excluded, cacheState cold, $(field 'd["pollCalls"]') calls"; else bad "(18) rc=$RC $RESULT"; fi

# (19) a timeline that cannot be read is an outage, never "not registered"
cat > "$TMP/tlfail.json" <<'EOF_FX'
{"now":"2026-01-01T10:00:00Z","timelineFails":3,"reviews":[]}
EOF_FX
OUT="$(printf '%s' '[{"name":"Bot A","graphqlBotId":"BOT_aaaa","registeredAt":null}]' | /bin/bash "$W" --dry-run "$TMP/tlfail.json" --repo o/r --pr 1 --reviewers-json - --timeout-minutes 20 --cache "$TMP/c19.json" --since-review-id 0 2>&1)"; RC=$?; RESULT="$(printf '%s\n' "$OUT" | sed -n 's/^RESULT //p' | tail -1)"
if [ "$RC" -eq 3 ] && [ "$(field 'd["result"]')" = gh-unavailable ] && [ "$(field 'd["notRegistered"]')" = "['BOT_aaaa']" ]; then ok "(19) timeline unreadable ×3 → gh-unavailable, not a silent not-registered/all-posted"; else bad "(19) rc=$RC $RESULT"; fi

# (20) a failed fetch on the tick that lands at the bound does not freeze the reviewer — the next real look finds the review
warm "$TMP/c20.json" 150,160,170,175,180,165,155,178,180,172,168,160 BOT_aaaa
cat > "$TMP/atbound.json" <<'EOF_FX'
{"now":"2026-01-01T10:00:00Z","failTicks":[5],"reviews":[{"id":96,"user":{"node_id":"BOT_aaaa","login":"bot-a[bot]"},"submitted_at":"2026-01-01T10:04:50Z"}]}
EOF_FX
OUT="$(printf '%s' "[$A]" | /bin/bash "$W" --dry-run "$TMP/atbound.json" --repo o/r --pr 1 --reviewers-json - --timeout-minutes 20 --cache "$TMP/c20.json" --since-review-id 0 2>&1)"; RC=$?; RESULT="$(printf '%s\n' "$OUT" | sed -n 's/^RESULT //p' | tail -1)"
if [ "$RC" -eq 0 ] && [ "$(field 'd["result"]')" = all-posted ] && [ "$(field 'd["responded"][0]["latencySeconds"]')" = 290 ]; then ok "(20) fetch failed on the tick at the bound → not frozen; next look found the 290 s review"; else bad "(20) rc=$RC $RESULT"; fi

# (21) nothing registered → immediate result, no sleep, no fetch
OUT="$(printf '%s' '[{"name":"Bot A","graphqlBotId":"BOT_aaaa","registeredAt":null}]' | /bin/bash "$W" --dry-run "$FX/no-show-cold.json" --repo o/r --pr 1 --reviewers-json - --timeout-minutes 20 --cache "$TMP/c21.json" --since-review-id 0 2>&1)"; RC=$?; RESULT="$(printf '%s\n' "$OUT" | sed -n 's/^RESULT //p' | tail -1)"
if [ "$RC" -eq 3 ] && [ "$(field 'd["result"]')" = nothing-registered ] && [ "$(field 'd["elapsedSeconds"]')" = 0 ] && [ "$(field 'd["pollCalls"]')" = 0 ]; then ok "(21) nobody registered → nothing-registered immediately, 0 s, 0 fetches"; else bad "(21) rc=$RC $RESULT"; fi

# (22) running twice on the same review records ONE sample
run responder-156.json "$TMP/c22.json" "[$A]" --since-review-id 0; run responder-156.json "$TMP/c22.json" "[$A]" --since-review-id 0
N22="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["reviewers"]["BOT_aaaa"]["samples"]))' "$TMP/c22.json")"
if [ "$N22" = 1 ]; then ok "(22) the same review twice → one sample (deduplicated by reviewId)"; else bad "(22) samples=$N22"; fi

# (23) a fractional-seconds timestamp and a +00:00 offset both parse
OUT="$(printf '%s' '[{"name":"Bot A","graphqlBotId":"BOT_aaaa","registeredAt":"2026-01-01T10:00:00.123+00:00"}]' | /bin/bash "$W" --dry-run "$FX/responder-156.json" --repo o/r --pr 1 --reviewers-json - --timeout-minutes 20 --cache "$TMP/c23.json" --since-review-id 0 2>&1)"; RC=$?; RESULT="$(printf '%s\n' "$OUT" | sed -n 's/^RESULT //p' | tail -1)"
if [ "$RC" -eq 0 ] && [ "$(field 'd["result"]')" = all-posted ]; then ok "(23) fractional seconds and a +00:00 offset parse"; else bad "(23) rc=$RC $RESULT"; fi

# (24) a malformed cache entry degrades that reviewer to the full bound with cacheState corrupt — no traceback
echo '{"version":1,"reviewers":{"BOT_aaaa":[1,2,3]}}' > "$TMP/c24.json"
run no-show-cold.json "$TMP/c24.json" "[$A]" --since-review-id 0
if [ "$RC" -eq 3 ] && [ "$(field 'd["result"]')" = timeout ] && [ "$(field 'd["cacheState"]')" = corrupt ] && [ "$(field 'd["nonResponders"][0]["boundSource"]')" = pollTimeoutMinutes ]; then ok "(24) malformed cache entry → corrupt, full bound, RESULT still printed"; else bad "(24) rc=$RC $RESULT"; fi

# (25) a relative --cache path is written where it says
( cd "$TMP" && printf '%s' "[$A]" | /bin/bash "$W" --dry-run "$FX/responder-156.json" --repo o/r --pr 1 --reviewers-json - --timeout-minutes 20 --cache rel-cache.json --since-review-id 0 >/dev/null 2>&1 )
if [ -s "$TMP/rel-cache.json" ]; then ok "(25) relative --cache path written in the working directory"; else bad "(25) relative cache not written"; fi

# (26) usage errors: a non-numeric timeout, a zero first tick, a non-numeric since → exit 2 with a RESULT line, never a traceback
for args in "--timeout-minutes twenty" "--timeout-minutes 20 --first-tick 0" "--timeout-minutes 20 --since-review-id none"; do
  OUT="$(printf '%s' "[$A]" | /bin/bash "$W" --dry-run "$FX/no-show-cold.json" --repo o/r --pr 1 --reviewers-json - --cache "$TMP/c26.json" $args 2>&1)"; RC=$?
  if [ "$RC" -eq 2 ] && ! printf '%s' "$OUT" | grep -q Traceback; then :; else bad "(26) '$args' → rc=$RC: $(printf '%s' "$OUT" | tail -1)"; fi
done; ok "(26) bad numeric options → exit 2, no traceback"

exit $FAIL
