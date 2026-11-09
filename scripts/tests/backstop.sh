#!/bin/bash
# Tests for skills/release/scripts/backstop.py — the release backstop (release.backstop): a release
# starts on a schedule only when landed work has waited too long. A temporary repository with a bare
# origin carries a release source and a train, like auto-start.sh; landings get fixed committer
# times (GIT_COMMITTER_DATE) so the wait is exact; a `gh` on PATH that fails and logs proves the
# check never calls it; a clearance `commands` provider whose `status` prints a prepared answer
# stands in for the release tower. Covers due and not due around the threshold, no waiting work,
# a release in progress, holds, two machines racing for one backstop, shadow changing nothing, off
# doing nothing and bad configs rejected (here and by doctor's validator). No network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/skills/release/scripts/backstop.py"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

g() { git -C "$1" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "${@:2}"; }
at() { GIT_COMMITTER_DATE="$1" GIT_AUTHOR_DATE="$1" g "${@:2}"; }
git init -q --bare "$WORK/origin.git"
git init -q -b develop "$WORK/seed"
at 2026-11-09T06:00:00Z "$WORK/seed" commit -q --allow-empty -m base
g "$WORK/seed" remote add origin "$WORK/origin.git"
g "$WORK/seed" push -q origin develop
g "$WORK/seed" push -q origin develop:train/release
git clone -q "$WORK/origin.git" "$WORK/repo" 2>/dev/null
g "$WORK/repo" remote set-url origin "git@github.com:acme/widgets.git"
g "$WORK/repo" config url."$WORK/origin.git".insteadOf "git@github.com:acme/widgets.git"
mkdir -p "$WORK/repo/.claude" "$WORK/bin"
cat > "$WORK/bin/gh" <<SH
#!/bin/bash
echo "gh \$*" >> "$WORK/gh-calls"; echo "gh: must not be called" >&2; exit 1
SH
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"
# the release tower stand-in: `status --json` prints $WORK/tower.json, or fails when it is absent
cat > "$WORK/tower-status.sh" <<SH
#!/bin/bash
[ "\$1" = "--json" ] || exit 9
[ -f "$WORK/tower.json" ] || { echo '{"state": "unknown", "error": "store unreachable"}'; exit 1; }
cat "$WORK/tower.json"
SH
tower() { printf '%s\n' "$1" > "$WORK/tower.json"; }
tower '{"state": "clear", "stale": false, "onFinal": null, "waiting": []}'

cfg() { printf '%s\n' "$1" > "$WORK/repo/.claude/ds-config.json"; }
run() { (cd "$WORK/repo" && python3 "$HELPER" "$@" </dev/null 2>&1); }
# expect LABEL EXIT FIRST-LINE-REGEX ARGS...
expect() {
  local label="$1" want="$2" pattern="$3" out code; shift 3
  out="$(run "$@")"; code=$?
  if [ "$code" = "$want" ] && printf '%s\n' "$out" | head -1 | grep -Eq -- "$pattern"; then ok "$label"; else bad "$label  (exit $code) $out"; fi
}
conf() { # mode, [backstop extra json], [release extra json]
  cfg "{\"baseBranch\": \"develop\", \"claims\": {\"provider\": \"devstride\"}, \"releaseTrain\": {\"branch\": \"train/release\"},
        \"release\": {\"releaseSource\": \"develop\", \"mergeTrainBeforeCut\": true${3:-},
                      \"clearance\": {\"commands\": {\"claim\": \"x\", \"status\": \"bash $WORK/tower-status.sh\", \"heartbeat\": \"x\", \"release\": \"x\", \"adopt\": \"x\"}},
                      \"backstop\": {\"mode\": \"$1\"${2:-}}}}"
}

# --- off does nothing --------------------------------------------------------------------------
cfg '{"release": {"mergeTrainBeforeCut": true}}'
expect "(1) no backstop block → OFF, exit 12" 12 '^OFF release.backstop is not configured$' due
conf off
g "$WORK/repo" remote set-url origin "not a remote"
expect "(2) mode off → OFF, exit 12, before any git (a broken origin is never read)" 12 '^OFF release.backstop.mode is off$' due
cfg '{"release": {"backstop": {}}}'
expect "(2b) a block without a mode is off (the default)" 12 '^OFF release.backstop.mode is off$' due
g "$WORK/repo" remote set-url origin "git@github.com:acme/widgets.git"

# --- bad config rejected -----------------------------------------------------------------------
conf shadow ', "maxWaitMinutes": 5'
expect "(3a) a wait under 15 minutes → ERROR, exit 1" 1 '^ERROR release.backstop.maxWaitMinutes must be a whole number of minutes, at least 15$' due
conf shadow ', "maxWaitMinutes": "2h"'
expect "(3b) a wait that is not a number → ERROR" 1 '^ERROR release.backstop.maxWaitMinutes' due
conf sometimes
expect "(3c) a mode outside off|shadow|live → ERROR" 1 "^ERROR release.backstop.mode must be off, shadow or live" due
cfg '{"release": {"backstop": "on"}}'
expect "(3d) a block that is not an object → ERROR" 1 '^ERROR release.backstop must be an object$' due
expect "(3e) usage → exit 2" 2 '' due --bogus
cfg '{"release": {"backstop": {"mode": "live", "maxWaitMinutes": 5}}}'
out="$(run config)"; code=$?
[ "$code" = 1 ] && printf '%s\n' "$out" | grep -q '^ERROR release.backstop: release.backstop.maxWaitMinutes' \
  && printf '%s\n' "$out" | grep -q '^ERROR release.backstop.mode: needs a `claims` block' \
  && printf '%s\n' "$out" | grep -q '^WARN release.backstop.mode: has no effect without a release train' \
  && ok "(3f) config lists every finding, exit 1" || bad "(3f) (exit $code) $out"
cfg '{"releaseTrain": {"branch": "train/release"}, "release": {"mergeTrainBeforeCut": true, "backstop": {"mode": "shadow"}}}'
expect "(4) no claims block → SKIP, never a start" 11 '^SKIP release.backstop needs a claims block' due

VAL="$ROOT/skills/doctor/scripts/validate-config.py"; SCHEMA="$ROOT/schemas/ds-config.schema.json"
doctor() { OUT="$(python3 "$VAL" "$WORK/repo/.claude/ds-config.json" --schema "$SCHEMA" 2>&1)"; RC=$?; }
conf shadow ', "maxWaitMinutes": 5'; doctor
[ "$RC" = 1 ] && printf '%s\n' "$OUT" | grep -q '^ERROR release.backstop.maxWaitMinutes' && ok "(5a) doctor: a wait under 15 is an ERROR" || bad "(5a) $OUT"
cfg '{"release": {"backstop": {"mode": "live"}}}'; doctor
[ "$RC" = 1 ] && printf '%s\n' "$OUT" | grep -q '^ERROR release.backstop.mode: needs a `claims` block' \
  && printf '%s\n' "$OUT" | grep -q '^WARN release.backstop.mode: has no effect without a release train' && ok "(5b) doctor: live without claims is an ERROR, without a train a WARN" || bad "(5b) $OUT"
cfg '{"release": {"backstop": {"mode": "fast"}}}'; doctor
[ "$RC" = 1 ] && printf '%s\n' "$OUT" | grep -q '^ERROR release.backstop.mode' && ok "(5c) doctor: a mode outside the enum is an ERROR" || bad "(5c) $OUT"
conf live; doctor
[ "$RC" = 0 ] && ok "(5d) doctor: a complete live config is clean" || bad "(5d) $OUT"

# --- no waiting work ---------------------------------------------------------------------------
conf shadow
expect "(6) the train level with the source → SKIP nothing waiting" 11 '^SKIP the train holds nothing beyond develop$' due --now 2026-11-09T12:00:00Z
# a sync merge of the source carries nothing and starts no wait
g "$WORK/seed" checkout -q -b side develop
at 2026-11-09T07:00:00Z "$WORK/seed" commit -q --allow-empty -m "source moves"
g "$WORK/seed" push -q origin side:develop
g "$WORK/seed" fetch -q origin
g "$WORK/seed" checkout -q -b t origin/train/release
at 2026-11-09T07:05:00Z "$WORK/seed" merge -q --no-ff -m "merge develop into train" side
g "$WORK/seed" push -q origin t:train/release
expect "(7) a train holding only a sync merge of the source → SKIP nothing waiting" 11 '^SKIP the train holds nothing beyond develop$' due --now 2026-11-09T12:00:00Z

# two landings, --no-ff merges as the loop makes them: 08:00 (the oldest) and 09:00
land() { # time, branch, item
  g "$WORK/seed" checkout -q -b "$2" t
  at "$1" "$WORK/seed" commit -q --allow-empty -m "feat: $2 [$3]"
  g "$WORK/seed" checkout -q t
  at "$1" "$WORK/seed" merge -q --no-ff -m "merge: $3 $2 into train/release" "$2"
}
land 2026-11-09T08:00:00Z export I20101
OLDEST="$(g "$WORK/seed" rev-parse HEAD)"
land 2026-11-09T09:00:00Z totals I20102
g "$WORK/seed" push -q origin t:train/release
KEY="acme/widgets@$OLDEST"

# --- the threshold -------------------------------------------------------------------------------
expect "(8) the oldest landing waited 120 of 120 minutes → SKIP, not yet" 11 \
  "^SKIP not waiting long enough: the oldest landing ${OLDEST:0:12} has waited 120 of 120 minutes$" due --now 2026-11-09T10:00:00Z
expect "(9) one minute over → HOLDS for the items the waiting work names" 13 '^HOLDS I20101 I20102$' due --now 2026-11-09T10:01:00Z
expect "(9b) the threshold follows maxWaitMinutes, and --now takes any offset" 13 '^HOLDS ' due --now 2026-11-09T04:01:00-06:00
python3 - "$WORK" <<'PY'
import json, sys
w = sys.argv[1]
item = lambda n, d="": {"number": n, "description": d}
json.dump({"items": [item("I20101"), item("I20102"), item("I20100")]}, open(w + "/clear.json", "w"))
json.dump({"items": [item("I20101"), item("I20102", "Release hold: not before 2026-11-10"), item("I20100")]}, open(w + "/held.json", "w"))
json.dump({"items": [item("I20101"), item("I20102", "Release hold: when ready"), item("I20100")]}, open(w + "/garbled.json", "w"))
json.dump({"items": [item("I20101")]}, open(w + "/short.json", "w"))
PY
expect "(10) over the wait, clear, no hold → SHADOW keyed by the oldest landing, exit 10" 10 \
  "^SHADOW $KEY:shadow would start \(the oldest of 2 landing\(s\), ${OLDEST:0:12}, has waited 121 minutes, over 120; 2 commit\(s\) on train/release not on develop\)$" \
  due --now 2026-11-09T10:01:00Z --holds "$WORK/clear.json"
conf shadow ', "maxWaitMinutes": 30'
expect "(11) maxWaitMinutes 30: due 31 minutes after the oldest landing" 10 '^SHADOW ' due --now 2026-11-09T08:31:00Z --holds "$WORK/clear.json"
expect "(11b) and not at 29" 11 '^SKIP not waiting long enough: .* has waited 29 of 30 minutes$' due --now 2026-11-09T08:29:00Z --holds "$WORK/clear.json"
conf shadow

# --- holds ---------------------------------------------------------------------------------------
expect "(12) a hold not yet lifted → SKIP held" 11 '^SKIP held: I20102: not before 2026-11-10' due --now 2026-11-09T10:01:00Z --holds "$WORK/held.json"
expect "(12b) the same hold once lifted → SHADOW" 10 '^SHADOW ' due --now 2026-11-10T06:01:00Z --holds "$WORK/held.json"
expect "(13) a hold line nobody can parse holds" 11 '^SKIP held: release-holds: I20102: "Release hold: when ready" does not parse' due --now 2026-11-09T10:01:00Z --holds "$WORK/garbled.json"
expect "(14) a holds request leaving out a waiting item → ERROR" 1 '^ERROR the holds request leaves out I20102' due --now 2026-11-09T10:01:00Z --holds "$WORK/short.json"

# --- a release in progress -----------------------------------------------------------------------
tower '{"state": "held", "stale": false, "record": {"branch": "release/26-11-09", "machine": "m1"}, "onFinal": null}'
expect "(15) clearance held by a live release → SKIP, a release is in progress" 11 '^SKIP a release is in progress: clearance is held for release/26-11-09 by m1$' due --now 2026-11-09T10:01:00Z --holds "$WORK/clear.json"
tower '{"state": "held", "stale": true, "record": {"purpose": "release"}, "onFinal": null}'
expect "(15b) a stale clearance is the owner's to settle → SKIP" 11 '^SKIP a release is in progress: clearance is held for release by another session \(stale' due --now 2026-11-09T10:01:00Z --holds "$WORK/clear.json"
tower '{"state": "clear", "stale": false, "onFinal": {"number": 41, "head": "release/26-11-09"}}'
expect "(16) clearance clear but a release pull request open on final → SKIP" 11 '^SKIP a release is in progress: release pull request #41 is open$' due --now 2026-11-09T10:01:00Z --holds "$WORK/clear.json"
rm -f "$WORK/tower.json"
expect "(17) clearance unreadable is never clear → SKIP naming why" 11 '^SKIP clearance could not be read \(store unreachable\)$' due --now 2026-11-09T10:01:00Z --holds "$WORK/clear.json"
tower '{"state": "clear", "stale": false, "onFinal": null, "waiting": []}'
expect "(17b) a release in progress is found before any item is asked for (no HOLDS while busy)" 13 '^HOLDS' due --now 2026-11-09T10:01:00Z
tower '{"state": "held", "stale": false, "record": {}, "onFinal": null}'
expect "(17c) ...and with the tower held, no HOLDS: SKIP first" 11 '^SKIP a release is in progress' due --now 2026-11-09T10:01:00Z
tower '{"state": "clear", "stale": false, "onFinal": null, "waiting": []}'

# --- shadow changes nothing ------------------------------------------------------------------------
snapshot() { (cd "$WORK/repo" && git for-each-ref --format='%(refname) %(objectname)' && git status --porcelain && find .claude -type f | sort; \
              git -C "$WORK/origin.git" for-each-ref --format='%(refname) %(objectname)'); }
run due --now 2026-11-09T10:01:00Z >/dev/null   # the first run fetches; compare what any later run changes
before="$(snapshot)"; rm -f "$WORK/gh-calls"
out="$(run due --now 2026-11-09T10:01:00Z --holds "$WORK/clear.json" --json)"; code=$?
printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["verdict"] == "SHADOW" and d["mode"] == "shadow" and d["key"] == sys.argv[1] + ":shadow", d
assert d["oldestLanding"] == sys.argv[1].split("@")[1] and d["landedAt"] == "2026-11-09T08:00:00+00:00" and d["waitedMinutes"] == 121, d
assert d["landings"] == 2 and d["commits"] == 2 and d["items"] == ["I20101", "I20102"] and d["holds"] == "no release hold", d
assert d["clearance"] == "clearance is clear" and d["maxWaitMinutes"] == 120 and d["reason"].endswith("not on develop)"), d
' "$KEY" && [ "$code" = 10 ] && ok "(18) shadow --json is the durable record: key, oldest landing and its time, wait, work, items, holds, clearance" || bad "(18) (exit $code) $out"
after="$(snapshot)"
[ "$before" = "$after" ] && [ ! -e "$WORK/gh-calls" ] && ok "(19) shadow changed nothing: refs, origin, working tree and config identical; gh never called" \
  || bad "(19) changed: $(diff <(echo "$before") <(echo "$after")) $(cat "$WORK/gh-calls" 2>/dev/null)"

conf live
expect "(20) live → START with the live key (no :shadow), exit 0" 0 "^START $KEY \(the oldest of 2 landing" due --now 2026-11-09T10:01:00Z --holds "$WORK/clear.json"
expect "(20b) live under the wait → SKIP" 11 '^SKIP not waiting long enough' due --now 2026-11-09T09:00:00Z --holds "$WORK/clear.json"

# --- one starter per waiting work --------------------------------------------------------------------
# Two machines check minutes apart while the same work waits: one key, and a stand-in store whose
# claim is an atomic mkdir (os.mkdir, one system call; auto-start.sh test 12 says why never the
# mkdir command) lets exactly one win. A third landing in between does not change the key.
STORE="$WORK/claims"; mkdir -p "$STORE"
starter() {
  local line key; line="$(run due --now "$2" --holds "$WORK/clear.json" | head -1)"
  case "$line" in START*) ;; *) echo "NOT-DUE $line" > "$WORK/starter-$1"; return;; esac
  key="$(printf '%s' "$line" | cut -d' ' -f2)"
  if python3 -c 'import os, sys; os.mkdir(sys.argv[1])' "$STORE/release-train:$(printf '%s' "$key" | tr '/:@' '___')" 2>/dev/null
  then echo "WON $key" > "$WORK/starter-$1"; else echo "LOST $key" > "$WORK/starter-$1"; fi
}
starter one 2026-11-09T10:02:00Z & starter two 2026-11-09T05:07:00-05:00 & wait
land 2026-11-09T10:03:00Z badge I20101
g "$WORK/seed" push -q origin t:train/release
starter three 2026-11-09T10:04:00Z
got="$(cut -d' ' -f1 "$WORK/starter-one" "$WORK/starter-two" "$WORK/starter-three" | sort | tr '\n' ' ')"
keys="$(cut -d' ' -f2 "$WORK/starter-one" "$WORK/starter-two" "$WORK/starter-three" | sort -u)"
[ "$got" = "LOST LOST WON " ] && [ "$keys" = "$KEY" ] && ok "(21) three checks for the same waiting work, two clocks, a new landing between → one key, exactly one wins" \
  || bad "(21) $got keys=$keys — $(cat "$WORK"/starter-* | tr '\n' '|')"
# The winner releases the backstop claim FINAL; a later check while the same work waits is told it is done.
OUT="$(printf '%s' '{"mode": "select", "item": "the backstop", "me": "bb", "now": "2026-11-09T11:00:00Z",
  "response": {"won": false, "final": true, "claim": {"holderDigest": "aa", "machine": "m1", "claimedAt": "2026-11-09T10:02:00Z", "releasedAt": "2026-11-09T10:03:00Z", "outcome": "started"}}}' \
  | python3 "$ROOT/skills/build-item/scripts/story-claim.py" decide)"
printf '%s' "$OUT" | grep -q '"action": "skip"' && ok "(22) a backstop claim released final → a later check skips (select mode)" || bad "(22) $OUT"
# Once the oldest landing ships (the train merged into the source), the key moves to the next one.
g "$WORK/seed" checkout -q -b ship origin/develop
at 2026-11-09T11:00:00Z "$WORK/seed" merge -q --no-ff -m "release: train into develop" "$(g "$WORK/seed" rev-parse "$OLDEST")"
g "$WORK/seed" push -q origin ship:develop
line="$(run due --now 2026-11-09T12:00:00Z --holds "$WORK/clear.json")"
NEXT="$(g "$WORK/seed" rev-parse 't~1')"
printf '%s' "$line" | grep -q "^START acme/widgets@$NEXT (the oldest of 2 landing" && ok "(23) once the oldest landing is on the source, the next oldest keys the backstop" || bad "(23) $line (want $NEXT)"

# --- exit codes and the contract -----------------------------------------------------------------
CONTRACT="$ROOT/skills/release/references/backstop.md"; T=0
for pair in "START 0" "SHADOW 10" "SKIP 11" "OFF 12" "HOLDS 13" "ERROR 1"; do
  set -- $pair
  grep -Eq "^\| \`$1\` \| $2 \|" "$CONTRACT" || { bad "(24) the contract's exit table lacks $1 → $2"; T=1; }
  grep -Eq "^ +$1 .*exit $2\$" "$HELPER" || { bad "(24) the script's header lacks $1 → exit $2"; T=1; }
done
[ "$T" = 0 ] && ok "(24) the contract's verdict table and the script's header agree on every exit code"
grep -q 'outcome `shadow`' "$CONTRACT" && grep -q '`final: true`' "$CONTRACT" && grep -q 'only after the shadow' "$CONTRACT" \
  && ok "(25) the contract: claims released final, outcome shadow in shadow mode, live only after the shadow results" || bad "(25) contract wording"

exit $FAIL
