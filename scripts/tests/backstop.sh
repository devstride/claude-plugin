#!/bin/bash
# Tests for skills/release/scripts/backstop.py — the release backstop (release.backstop): a release
# starts on a schedule only when landed work has waited too long. A temporary repository with a bare
# origin carries production (master), the release source (develop) and a train, like auto-start.sh;
# landings get fixed committer times (GIT_COMMITTER_DATE) so the wait is exact. A `gh` on PATH
# answers `pr list` from a file (and logs every call); a clearance `commands` provider whose `status`
# prints a prepared answer stands in for the release tower; a claims store with the server's rules
# (one winner, expiry, takeover by digest, final) and a driver that follows backstop.md's steps with
# the script's own record and story-claim.py decide stand in for the agent. No network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/skills/release/scripts/backstop.py"
DECIDE="$ROOT/skills/build-item/scripts/story-claim.py"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

g() { git -C "$1" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "${@:2}"; }
at() { GIT_COMMITTER_DATE="$1" GIT_AUTHOR_DATE="$1" g "${@:2}"; }
git init -q --bare "$WORK/origin.git"
git init -q -b develop "$WORK/seed"
at 2026-11-09T06:00:00Z "$WORK/seed" commit -q --allow-empty -m base
g "$WORK/seed" remote add origin "$WORK/origin.git"
g "$WORK/seed" push -q origin develop develop:master develop:train/release
git clone -q "$WORK/origin.git" "$WORK/repo" 2>/dev/null
g "$WORK/repo" remote set-url origin "git@github.com:acme/widgets.git"
g "$WORK/repo" config url."$WORK/origin.git".insteadOf "git@github.com:acme/widgets.git"
mkdir -p "$WORK/repo/.claude" "$WORK/bin"
printf '[]\n' > "$WORK/prs.json"
cat > "$WORK/bin/gh" <<SH
#!/bin/bash
echo "gh \$*" >> "$WORK/gh-calls"
if [ "\$1 \$2" = "pr list" ] && [ ! -e "$WORK/gh-fail" ]; then cat "$WORK/prs.json"; exit 0; fi
echo "gh: not available here" >&2; exit 1
SH
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"
cat > "$WORK/tower-status.sh" <<SH
#!/bin/bash
[ "\$1" = "--json" ] || exit 9
[ -f "$WORK/tower.json" ] || { echo '{"state": "unknown", "error": "store unreachable"}'; exit 1; }
cat "$WORK/tower.json"
SH
tower() { printf '%s\n' "$1" > "$WORK/tower.json"; }
CLEAR_TOWER='{"state": "clear", "stale": false, "derived": true, "onFinal": null, "waiting": []}'
tower "$CLEAR_TOWER"
prs() { printf '%s\n' "$1" > "$WORK/prs.json"; }

cfg() { printf '%s\n' "$1" > "$WORK/repo/.claude/ds-config.json"; }
run() { (cd "$WORK/repo" && python3 "$HELPER" "$@" </dev/null 2>&1); }
# expect LABEL EXIT FIRST-LINE-REGEX ARGS...
expect() {
  local label="$1" want="$2" pattern="$3" out code; shift 3
  out="$(run "$@")"; code=$?
  if [ "$code" = "$want" ] && printf '%s\n' "$out" | head -1 | grep -Eq -- "$pattern"; then ok "$label"; else bad "$label  (exit $code) $out"; fi
}
TOWERCFG="\"clearance\": {\"commands\": {\"claim\": \"x\", \"status\": \"bash $WORK/tower-status.sh\", \"heartbeat\": \"x\", \"release\": \"x\", \"adopt\": \"x\"}},"
conf() { # mode, [backstop extra json], [release extra json]; NOTOWER=1 leaves release.clearance out
  local t="$TOWERCFG"; [ "${NOTOWER:-0}" = 1 ] && t=""
  cfg "{\"baseBranch\": \"develop\", \"claims\": {\"provider\": \"devstride\"}, \"releaseTrain\": {\"branch\": \"train/release\"},
        \"release\": {\"productionBranch\": \"master\", \"releaseSource\": \"develop\", \"mergeTrainBeforeCut\": true${3:-}, $t
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
expect "(3a) a wait under 15 minutes → ERROR, exit 1" 1 '^ERROR release.backstop.maxWaitMinutes must be a whole number of minutes from 15 to 1440$' due
conf shadow ', "maxWaitMinutes": 1441'
expect "(3a2) a wait over a day (1441) → ERROR: a claim lives at most 1440 minutes" 1 '^ERROR release.backstop.maxWaitMinutes must be a whole number of minutes from 15 to 1440$' due
conf shadow ', "maxWaitMinutes": 1440'
expect "(3a3) 1440 itself is allowed" 11 '^SKIP the train holds nothing beyond develop$' due --now 2026-11-09T12:00:00Z
conf shadow ', "maxWaitMinutes": "2h"'
expect "(3b) a wait that is not a number → ERROR" 1 '^ERROR release.backstop.maxWaitMinutes' due
conf shadow ', "maxWaitMinutes": 120.5'
expect "(3c) a fractional wait → ERROR" 1 '^ERROR release.backstop.maxWaitMinutes' due
conf sometimes
expect "(3d) a mode outside off|shadow|live → ERROR" 1 "^ERROR release.backstop.mode must be off, shadow or live" due
cfg '{"release": {"backstop": "on"}}'
expect "(3e) a block that is not an object → ERROR" 1 '^ERROR release.backstop must be an object$' due
expect "(3f) usage → exit 2" 2 '' due --bogus
cfg '{"release": {"backstop": {"mode": "live", "maxWaitMinutes": 5}}}'
out="$(run config)"; code=$?
[ "$code" = 1 ] && printf '%s\n' "$out" | grep -q '^ERROR release.backstop: release.backstop.maxWaitMinutes' \
  && printf '%s\n' "$out" | grep -q '^ERROR release.backstop.mode: needs a `claims` block' \
  && printf '%s\n' "$out" | grep -q '^WARN release.backstop.mode: has no effect without a release train' \
  && ok "(3g) config lists every finding, exit 1" || bad "(3g) (exit $code) $out"
cfg '{"releaseTrain": {"branch": "train/release"}, "release": {"mergeTrainBeforeCut": true, "backstop": {"mode": "shadow"}}}'
expect "(4) no claims block → SKIP, never a start" 11 '^SKIP release.backstop needs a claims block' due

VAL="$ROOT/skills/doctor/scripts/validate-config.py"; SCHEMA="$ROOT/schemas/ds-config.schema.json"
doctor() { OUT="$(python3 "$VAL" "$WORK/repo/.claude/ds-config.json" --schema "$SCHEMA" </dev/null 2>&1)"; RC=$?; }
conf shadow ', "maxWaitMinutes": 5'; doctor
[ "$RC" = 1 ] && printf '%s\n' "$OUT" | grep -q '^ERROR release.backstop.maxWaitMinutes' && ok "(5a) doctor: a wait under 15 is an ERROR" || bad "(5a) $OUT"
conf shadow ', "maxWaitMinutes": 1441'; doctor
[ "$RC" = 1 ] && printf '%s\n' "$OUT" | grep -q '^ERROR release.backstop.maxWaitMinutes: 1441 is above the maximum 1440$' && ok "(5a2) doctor: 1441 is above the maximum, as the check says" || bad "(5a2) $OUT"
cfg '{"claims": {"commands": {"claim": "c", "heartbeat": "h", "release": "r"}}, "releaseTrain": {"branch": "train/release"}, "release": {"mergeTrainBeforeCut": true, "backstop": {"mode": "live"}}}'; doctor
[ "$RC" = 1 ] && printf '%s\n' "$OUT" | grep -q '^ERROR release.backstop.mode: needs `claims.commands.get`' && ok "(5a3) doctor: a commands store without get is an ERROR (the claim is read before claiming)" || bad "(5a3) $OUT"
cfg '{"release": {"backstop": {"mode": "live"}}}'; doctor
[ "$RC" = 1 ] && printf '%s\n' "$OUT" | grep -q '^ERROR release.backstop.mode: needs a `claims` block' \
  && printf '%s\n' "$OUT" | grep -q '^WARN release.backstop.mode: has no effect without a release train' && ok "(5b) doctor: live without claims is an ERROR, without a train a WARN" || bad "(5b) $OUT"
cfg '{"release": {"backstop": {"mode": "fast"}}}'; doctor
[ "$RC" = 1 ] && printf '%s\n' "$OUT" | grep -q '^ERROR release.backstop.mode' && ok "(5c) doctor: a mode outside the enum is an ERROR" || bad "(5c) $OUT"
conf live; doctor
[ "$RC" = 0 ] && ok "(5d) doctor: a complete live config is clean" || bad "(5d) $OUT"
conf live ', "maxWaitMinutes": 120.0'; doctor
[ "$RC" = 0 ] && ok "(5e) doctor: 120.0 is a whole number of minutes" || bad "(5e) $OUT"
conf live ', "maxWaitMinutes": 120.5'; doctor
[ "$RC" = 1 ] && printf '%s\n' "$OUT" | grep -q '^ERROR release.backstop.maxWaitMinutes' && ok "(5f) doctor: 120.5 is an ERROR, as the check says" || bad "(5f) $OUT"

# --- no waiting work ---------------------------------------------------------------------------
conf shadow
expect "(6) the train level with the source → SKIP nothing waiting" 11 '^SKIP the train holds nothing beyond develop$' due --now 2026-11-09T12:00:00Z
g "$WORK/seed" checkout -q -b side develop
at 2026-11-09T07:00:00Z "$WORK/seed" commit -q --allow-empty -m "source moves"
g "$WORK/seed" push -q origin side:develop
g "$WORK/seed" fetch -q origin
g "$WORK/seed" checkout -q -b t origin/train/release
at 2026-11-09T07:05:00Z "$WORK/seed" merge -q --no-ff -m "merge develop into train" side
g "$WORK/seed" push -q origin t:train/release
expect "(7) a train holding only a sync merge of the source → SKIP nothing waiting" 11 '^SKIP the train holds nothing beyond develop$' due --now 2026-11-09T12:00:00Z
# a fix on the source alone: never a landing, but in the release delta the holds cover
g "$WORK/seed" checkout -q side
at 2026-11-09T07:10:00Z "$WORK/seed" commit -q --allow-empty -m "fix: source-only [I20104]"
g "$WORK/seed" push -q origin side:develop

land() { # time, branch, item — a --no-ff landing, as the loop makes one
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
python3 - "$WORK" <<'PY'
import json, sys
w = sys.argv[1]
item = lambda n, d="": {"number": n, "description": d}
base = lambda second="": [item("I20101"), item("I20102", second), item("I20104"), item("I20100")]
json.dump({"items": base()}, open(w + "/clear.json", "w"))
json.dump({"items": base("Release hold: not before 2026-11-10")}, open(w + "/held.json", "w"))
json.dump({"items": base("Release hold: when ready")}, open(w + "/garbled.json", "w"))
json.dump({"items": base("Release hold: after I20103 is live")}, open(w + "/after.json", "w"))
json.dump({"items": [item("I20101")]}, open(w + "/short.json", "w"))
PY

# --- the threshold -------------------------------------------------------------------------------
expect "(8) the oldest landing waited 120 of 120 minutes → SKIP, not yet" 11 \
  "^SKIP not waiting long enough: the oldest landing ${OLDEST:0:12} has waited 120 of 120 minutes$" due --now 2026-11-09T10:00:00Z
expect "(9) one minute over → HOLDS for every item in the release delta, the source-only fix included" 13 '^HOLDS I20101 I20102 I20104$' due --now 2026-11-09T10:01:00Z
expect "(9b) --now takes any offset" 13 '^HOLDS ' due --now 2026-11-09T04:01:00-06:00
expect "(10) over the wait, nothing in progress, no hold → SHADOW keyed by the oldest landing, exit 10" 10 \
  "^SHADOW $KEY:shadow would start \(the oldest of 2 landing\(s\), ${OLDEST:0:12}, has waited 121 minutes, over 120; 2 commit\(s\) on train/release not on develop\)$" \
  due --now 2026-11-09T10:01:00Z --holds "$WORK/clear.json"
conf shadow ', "maxWaitMinutes": 30'
expect "(11) maxWaitMinutes 30: due 31 minutes after the oldest landing" 10 '^SHADOW ' due --now 2026-11-09T08:31:00Z --holds "$WORK/clear.json"
expect "(11b) and not at 29" 11 '^SKIP not waiting long enough: .* has waited 29 of 30 minutes$' due --now 2026-11-09T08:29:00Z --holds "$WORK/clear.json"
conf shadow ', "maxWaitMinutes": 120.0'
expect "(11c) maxWaitMinutes 120.0 is 120 (the schema's integer), not an error" 11 '^SKIP not waiting long enough: .* of 120 minutes$' due --now 2026-11-09T10:00:00Z
conf shadow

# --- holds ---------------------------------------------------------------------------------------
expect "(12) a hold not yet lifted → SKIP held" 11 '^SKIP held: I20102: not before 2026-11-10' due --now 2026-11-09T10:01:00Z --holds "$WORK/held.json"
expect "(12b) the same hold once lifted → SHADOW" 10 '^SHADOW ' due --now 2026-11-10T06:01:00Z --holds "$WORK/held.json"
expect "(13) a hold line nobody can parse holds" 11 '^SKIP held: release-holds: I20102: "Release hold: when ready" does not parse' due --now 2026-11-09T10:01:00Z --holds "$WORK/garbled.json"
expect "(14) a holds request leaving out a release item → ERROR" 1 '^ERROR the holds request leaves out I20102 I20104' due --now 2026-11-09T10:01:00Z --holds "$WORK/short.json"
# "after I20103 is live": I20103 reaches origin's master after this checkout last fetched it
expect "(14b) before I20103 reaches production → held" 11 '^SKIP held: I20102: after I20103 is live' due --now 2026-11-09T10:01:00Z --holds "$WORK/after.json"
g "$WORK/seed" checkout -q -b hot origin/master
at 2026-11-09T09:30:00Z "$WORK/seed" commit -q --allow-empty -m "fix: hotfix [I20103]"
g "$WORK/seed" push -q origin hot:master
out="$(cd "$WORK/repo" && AUTO_START_NO_FETCH=1 python3 "$HELPER" due --now 2026-11-09T10:01:00Z --holds "$WORK/after.json" </dev/null 2>&1)"
printf '%s' "$out" | grep -q '^SKIP held: I20102: after I20103 is live' && ok "(14c) a stale production ref still reads it held (no fetch)" || bad "(14c) $out"
expect "(14d) the check fetches production first, so the hold is met → SHADOW" 10 '^SHADOW ' due --now 2026-11-09T10:01:00Z --holds "$WORK/after.json"

# --- a release in progress -----------------------------------------------------------------------
tower '{"state": "held", "stale": false, "derived": true, "record": {"branch": "release/26-11-09", "machine": "m1"}, "onFinal": null}'
expect "(15) clearance held by a live release → SKIP, a release is in progress" 11 '^SKIP a release is in progress: clearance is held for release/26-11-09 by m1$' due --now 2026-11-09T10:01:00Z --holds "$WORK/clear.json"
tower '{"state": "held", "stale": true, "derived": true, "record": {"purpose": "release"}, "onFinal": null}'
expect "(15b) a stale clearance is the owner's to settle → SKIP" 11 '^SKIP a release is in progress: clearance is held for release by another session \(stale' due --now 2026-11-09T10:01:00Z --holds "$WORK/clear.json"
tower '{"state": "clear", "stale": false, "derived": true, "onFinal": {"number": 41, "head": "release/26-11-09"}}'
expect "(16) clearance clear but a release pull request on final → SKIP" 11 '^SKIP a release is in progress: release pull request #41 is on final$' due --now 2026-11-09T10:01:00Z --holds "$WORK/clear.json"
tower '{"state": "clear", "stale": false, "derived": false, "onFinal": null, "waiting": []}'
expect "(16b) clearance clear but its pull requests not derived (a failed or truncated list) → SKIP, never clear" 11 '^SKIP clearance could not be read \(its release pull requests were not derived\)$' due --now 2026-11-09T10:01:00Z --holds "$WORK/clear.json"
rm -f "$WORK/tower.json"
expect "(17) clearance unreadable is never clear → SKIP naming why" 11 '^SKIP clearance could not be read \(store unreachable\)$' due --now 2026-11-09T10:01:00Z --holds "$WORK/clear.json"
tower "$CLEAR_TOWER"
NOTOWER=1 conf shadow ', "maxWaitMinutes": 120' ', "releaseBranchPattern": "release/<YY-MM-DD>[-n]"'
prs '[{"number": 7, "headRefName": "feature/x"}, {"number": 9, "headRefName": "release/26-11-09-2"}]'
expect "(18) no clearance configured, an open release-branch pull request into production → SKIP" 11 '^SKIP a release is in progress: release pull request #9 \(release/26-11-09-2\) is open$' due --now 2026-11-09T10:01:00Z --holds "$WORK/clear.json"
prs '[{"number": 5, "headRefName": "develop"}]'
expect "(18b) ...or one headed by the release source → SKIP" 11 '^SKIP a release is in progress: release pull request #5 \(develop\) is open$' due --now 2026-11-09T10:01:00Z --holds "$WORK/clear.json"
prs '[{"number": 7, "headRefName": "feature/x"}]'
expect "(18c) another pull request into production is not a release → SHADOW" 10 '^SHADOW ' due --now 2026-11-09T10:01:00Z --holds "$WORK/clear.json"
touch "$WORK/gh-fail"
expect "(18d) pull requests unreadable → SKIP, never clear" 11 '^SKIP open release pull requests could not be read' due --now 2026-11-09T10:01:00Z --holds "$WORK/clear.json"
rm -f "$WORK/gh-fail"
python3 -c 'import json; print(json.dumps([{"number": n, "headRefName": "feature/%d" % n} for n in range(200)]))' > "$WORK/prs.json"
expect "(18e) a truncated list (200) → SKIP, never clear" 11 '^SKIP open pull requests into master could not all be read' due --now 2026-11-09T10:01:00Z --holds "$WORK/clear.json"
prs '[{"number": 5, "headRefName": "develop"}]'
expect "(19) in progress is decided before any item is asked for: SKIP, never HOLDS" 11 '^SKIP a release is in progress' due --now 2026-11-09T10:01:00Z
prs '[]'
conf shadow

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
assert d["landings"] == 2 and d["commits"] == 2 and d["items"] == ["I20101", "I20102", "I20104"] and d["holds"] == "no release hold", d
assert d["clearance"] == "clearance is clear" and d["releasePullRequests"] == "no release pull request is open", d
assert d["claim"] == {"kind": "release-train", "key": d["key"], "expiryMinutes": 120, "purpose": "release backstop"}, d
assert d["trainClaim"] == {"kind": "release-train", "key": "acme/widgets"}, d
' "$KEY" && [ "$code" = 10 ] && ok "(20) shadow --json is the record: key, oldest landing and time, wait, items, in-progress checks, the claims to make" || bad "(20) (exit $code) $out"
after="$(snapshot)"
calls="$(sort -u "$WORK/gh-calls" 2>/dev/null)"
[ "$before" = "$after" ] && [ "$calls" = "gh pr list --repo github.com/acme/widgets --base master --state open --json number,headRefName --limit 200" ] \
  && ok "(20b) shadow changed nothing: refs, origin, working tree and config identical; gh only listed pull requests" \
  || bad "(20b) changed: $(diff <(echo "$before") <(echo "$after")) calls: $calls"

conf live
expect "(20c) live → START with the live key (no :shadow), exit 0" 0 "^START $KEY \(the oldest of 2 landing" due --now 2026-11-09T10:01:00Z --holds "$WORK/clear.json"
expect "(20d) live under the wait → SKIP" 11 '^SKIP not waiting long enough' due --now 2026-11-09T09:00:00Z --holds "$WORK/clear.json"
expect "(20e) --recheck with the same key → the same START" 0 "^START $KEY " due --now 2026-11-09T10:01:00Z --holds "$WORK/clear.json" --recheck "$KEY"
expect "(20f) --recheck with another key → SKIP changed since the claim" 11 "^SKIP changed since the claim: START $KEY" due --now 2026-11-09T10:01:00Z --holds "$WORK/clear.json" --recheck "acme/widgets@other"
rm -f "$WORK/gh-calls"
out="$(cd "$WORK/repo" && GH_REPO=elsewhere/other python3 "$HELPER" due --now 2026-11-09T10:01:00Z --holds "$WORK/clear.json" </dev/null 2>&1)"
grep -q -- '--repo github.com/acme/widgets ' "$WORK/gh-calls" && ! grep -q elsewhere "$WORK/gh-calls" && printf '%s' "$out" | grep -q '^START ' \
  && ok "(20g) a github.com origin: pull requests are listed with --repo github.com/acme/widgets, whatever GH_REPO says" || bad "(20g) $out — $(cat "$WORK/gh-calls")"
for url in "git@github.example.com:acme/widgets.git" "https://github.example.com/acme/widgets.git"; do
  g "$WORK/repo" remote set-url origin "$url"; g "$WORK/repo" config url."$WORK/origin.git".insteadOf "$url"; rm -f "$WORK/gh-calls"
  out="$(run due --now 2026-11-09T10:01:00Z --holds "$WORK/clear.json")"
  grep -q -- '--repo github.example.com/acme/widgets ' "$WORK/gh-calls" && printf '%s' "$out" | grep -q "^START $KEY " \
    && ok "(20g2) an enterprise origin ($url) is listed on its own host; the claim key is unchanged" || bad "(20g2) $url: $out — $(cat "$WORK/gh-calls")"
  g "$WORK/repo" config --unset url."$WORK/origin.git".insteadOf "$url"
done
g "$WORK/repo" remote set-url origin "/srv/git/acme/widgets.git"; g "$WORK/repo" config url."$WORK/origin.git".insteadOf "/srv/git/acme/widgets.git"; rm -f "$WORK/gh-calls"
expect "(20g3) an origin with an owner and name but no host → SKIP, and gh is never asked" 11 '^SKIP open release pull requests cannot be read: cannot read the host of the origin remote' due --now 2026-11-09T10:01:00Z --holds "$WORK/clear.json"
[ ! -e "$WORK/gh-calls" ] || bad "(20g3) gh was called: $(cat "$WORK/gh-calls")"
g "$WORK/repo" config --unset url."$WORK/origin.git".insteadOf "/srv/git/acme/widgets.git"
g "$WORK/repo" config url."$WORK/origin.git".insteadOf "git@github.com:acme/widgets.git"   # setting one replaced it
g "$WORK/repo" remote set-url origin "git@github.com:acme/widgets.git"
g "$WORK/repo" remote set-url origin "weird-remote"
g "$WORK/repo" config url."$WORK/origin.git".insteadOf "weird-remote"
expect "(20h) an origin with no <owner>/<repo> to read → SKIP, never a start" 11 '^SKIP open release pull requests cannot be read: cannot read <owner>/<repo>' due --now 2026-11-09T10:01:00Z --holds "$WORK/clear.json"
g "$WORK/repo" config --unset url."$WORK/origin.git".insteadOf "weird-remote" 2>/dev/null || g "$WORK/repo" config --unset-all url."$WORK/origin.git".insteadOf
g "$WORK/repo" config url."$WORK/origin.git".insteadOf "git@github.com:acme/widgets.git"
g "$WORK/repo" remote set-url origin "$WORK/missing/acme/widgets.git"
out="$(run due --now 2026-11-09T10:01:00Z --holds "$WORK/clear.json" --recheck "$KEY" --json)"; code=$?
printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["verdict"] == "SKIP" and d["reason"].startswith("changed since the claim: ERROR listing origin"), d' \
  && [ "$code" = 11 ] && ok "(20i) --recheck when git ls-remote fails → JSON SKIP, exit 11 (never a bare ERROR line)" || bad "(20i) (exit $code) $out"
expect "(20j) and without --recheck it is the documented ERROR, exit 1" 1 '^ERROR listing origin' due --now 2026-11-09T10:01:00Z --holds "$WORK/clear.json"
g "$WORK/repo" remote set-url origin "git@github.com:acme/widgets.git"

# --- the claims, as backstop.md runs them ---------------------------------------------------------
# store.py: the claim server's rules over a locked file. claim → won, or lost with `expired` (no
# heartbeat before expiresAt) or `final`; a takeover wins only with the lapsed row's digest.
cat > "$WORK/store.py" <<'PY'
import datetime, fcntl, hashlib, json, os, sys
path, op, req = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
iso = lambda t: t.strftime("%Y-%m-%dT%H:%M:%SZ")
now = datetime.datetime.fromisoformat(req["now"].replace("Z", "+00:00"))
with open(path, "a+") as f:
    fcntl.flock(f, fcntl.LOCK_EX); f.seek(0); rows = json.loads(f.read() or "{}")
    k = req["kind"] + " " + req["key"]; row = rows.get(k); me = hashlib.sha256(req.get("holder", "").encode()).hexdigest()
    lapsed = row is not None and not row.get("releasedAt") and datetime.datetime.fromisoformat(row["expiresAt"].replace("Z", "+00:00")) <= now
    if op == "get":
        out = {"claim": row, "live": bool(row) and not row.get("releasedAt") and not lapsed}
    elif op == "claim":
        take = (req.get("takeover") or {}).get("expectedHolderDigest")
        if row and row.get("releasedAt") and row.get("final"):
            out = {"won": False, "final": True, "claim": row}
        elif row and not row.get("releasedAt") and row["holderDigest"] != me and not (lapsed and take == row["holderDigest"]):
            out = {"won": False, "expired": lapsed, "claim": row}
        else:
            row = {"kind": req["kind"], "key": req["key"], "holderDigest": me, "machine": req.get("machine"), "claimedAt": iso(now),
                   "expiresAt": iso(now + datetime.timedelta(minutes=req.get("expiryMinutes", 30))), "payload": req.get("payload")}
            renewed = bool(rows.get(k)) and not rows[k].get("releasedAt") and rows[k]["holderDigest"] == me
            rows[k] = row; out = {"won": True, "takenOver": bool(take), "renewed": renewed, "claim": row}
    elif op == "release":
        if row and row["holderDigest"] == me and not row.get("releasedAt"):
            row.update(releasedAt=iso(now), outcome=req.get("outcome"), final=bool(req.get("final")), result=req.get("result"))
        out = {"released": True, "claim": row}
    f.seek(0); f.truncate(); f.write(json.dumps(rows)); print(json.dumps(out))
PY
# drive.py: backstop.md's steps for one check. Prints one word: NOOP <verdict>, SKIP-CLAIM, BUSY,
# CHANGED, START (live, release about to run) or SHADOW (shadow, claim kept).
cat > "$WORK/drive.py" <<'PY'
import hashlib, json, os, subprocess, sys
helper, decide, store, holder, now, holds = sys.argv[1:7]
between = sys.argv[7] if len(sys.argv) > 7 else ""
def due(*extra):
    p = subprocess.run([sys.executable, helper, "due", "--json", "--now", now, "--holds", holds] + list(extra),
                       capture_output=True, text=True, stdin=subprocess.DEVNULL)
    return json.loads(p.stdout)
def call(op, **req):
    req.update(now=now, holder=holder, machine="m-" + holder)
    return json.loads(subprocess.run([sys.executable, os.path.join(os.path.dirname(store), "store.py"), store, op, json.dumps(req)],
                                     capture_output=True, text=True, stdin=subprocess.DEVNULL).stdout)
def bdecide(stage, response, before=None):
    p = subprocess.run([sys.executable, helper, "decide"], input=json.dumps({"stage": stage, "response": response, "now": now, "before": before}),
                       capture_output=True, text=True)
    return json.loads(p.stdout)
def backstop_claim(fields):
    """backstop.md: read the claim, then claim or take over, then read the answer — backstop.py decide."""
    before = bdecide("before", call("get", **fields))
    if before["action"] == "claim":
        answer = call("claim", **fields)
    elif before["action"] == "takeover":
        answer = call("claim", takeover={"expectedHolderDigest": before["takeoverDigest"]}, **fields)
    else:
        return False
    return bdecide("after", answer, before["action"])["action"] == "proceed"
def decided(response):
    me = hashlib.sha256(holder.encode()).hexdigest()
    p = subprocess.run([sys.executable, decide, "decide"], input=json.dumps({"mode": "select", "response": response, "me": me, "now": now, "tz": "UTC"}),
                       capture_output=True, text=True)
    return json.loads(p.stdout)
record = due()
if record["verdict"] not in ("START", "SHADOW"):
    print("NOOP " + record["verdict"]); sys.exit()
if between:
    subprocess.run(["/bin/sh", "-c", between], stdin=subprocess.DEVNULL)
claim = dict(record["claim"], payload={"backstop": record})
def won(fields):
    answer = decided(call("claim", **fields))
    if answer["action"] == "takeover":   # a lapsed holder is taken over by its digest, once
        answer = decided(call("claim", takeover={"expectedHolderDigest": answer["takeoverDigest"]}, **fields))
    return answer["action"] == "proceed"
if not backstop_claim(claim):
    print("SKIP-CLAIM"); sys.exit()
key, train = record["claim"]["key"], record["trainClaim"]
if record["verdict"] == "START":
    if not won(dict(train, expiryMinutes=30)):
        call("release", kind="release-train", key=key, outcome="busy", final=False, result=record); print("BUSY"); sys.exit()
    again = due("--recheck", key)
    if again["verdict"] != "START":
        call("release", outcome="released", final=False, **train)
        call("release", kind="release-train", key=key, outcome="changed", final=False, result=again); print("CHANGED"); sys.exit()
    print("START")
else:
    if call("get", **train)["live"]:
        call("release", kind="release-train", key=key, outcome="busy", final=False, result=dict(record, trainClaim="held")); print("BUSY"); sys.exit()
    again = due("--recheck", key)
    if again["verdict"] != "SHADOW":
        call("release", kind="release-train", key=key, outcome="changed", final=False, result=again); print("CHANGED"); sys.exit()
    print("SHADOW")
PY
drive() { (cd "$WORK/repo" && python3 "$WORK/drive.py" "$HELPER" "$DECIDE" "$WORK/$1" "$2" "$3" "$WORK/clear.json" "${4:-}" </dev/null 2>&1); }
row() { python3 -c 'import json,sys; r=json.load(open(sys.argv[1])).get(sys.argv[2]); print(json.dumps(r) if r else "none")' "$WORK/$1" "$2"; }

conf live
for m in one two; do (drive s21 "$m" 2026-11-09T10:02:00Z > "$WORK/d-$m") & done; wait
land 2026-11-09T10:03:00Z badge I20101
g "$WORK/seed" push -q origin t:train/release
drive s21 three 2026-11-09T10:04:00Z > "$WORK/d-three"
got="$(cat "$WORK/d-one" "$WORK/d-two" "$WORK/d-three" | sort | tr '\n' ' ')"
r="$(row s21 "release-train $KEY")"
printf '%s' "$r" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert not r.get("releasedAt") and r["payload"]["backstop"]["verdict"] == "START", r' \
  && [ "$got" = "SKIP-CLAIM SKIP-CLAIM START " ] && ok "(21) three checks for the same waiting work, a landing between → one START; the claim stays live with the record in its payload" \
  || bad "(21) $got — $r"
printf '%s' "$r" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert (r["claimedAt"], r["expiresAt"]) in (("2026-11-09T10:02:00Z", "2026-11-09T12:02:00Z"),), r' \
  && ok "(21b) the backstop claim lapses after maxWaitMinutes (120), the script's own expiry" || bad "(21b) $r"
W="$(grep -l '^START$' "$WORK/d-one" "$WORK/d-two" | head -1 | sed 's/.*d-//')"
got="$(drive s21 "$W" 2026-11-09T10:12:00Z)"
r2="$(row s21 "release-train $KEY")"
[ "$got" = "SKIP-CLAIM" ] && [ "$r2" = "$r" ] && ok "(21c) the same session checking again (a /loop) starts nothing and never renews or extends its live claim" || bad "(21c) $got — $r2"
got="$(drive s21 four 2026-11-09T12:01:00Z)"
[ "$got" = "SKIP-CLAIM" ] && ok "(22) no retry inside the window: a check before the claim lapses skips" || bad "(22) $got"
got="$(drive s21 "$W" 2026-11-09T12:03:00Z)"
r3="$(row s21 "release-train $KEY")"
printf '%s' "$r3" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["claimedAt"] == "2026-11-09T12:03:00Z", r' \
  && [ -n "$W" ] && [ "$got" = "START" ] && ok "(22b) the session that started at 10:02 checks at 12:03, its own claim lapsed → it takes it back (a renewed win after a takeover) and starts" || bad "(22b) $W $got — $r3"
drive s22 a 2026-11-09T10:02:00Z >/dev/null
got="$(drive s22 b 2026-11-09T12:03:00Z)"
[ "$got" = "START" ] && ok "(22c) another machine after the window → the lapsed claim is taken over by its digest and the release retried" || bad "(22c) $got"
dec() { printf '%s' "$1" | python3 "$HELPER" decide; }
out="$(dec '{"stage": "after", "before": "claim", "response": {"won": true, "renewed": true, "claim": {}}}')"
printf '%s' "$out" | grep -q '"action": "skip"' && ok "(22d) a renewed win the read did not show lapsed → skip (it was live and this session's)" || bad "(22d) $out"
out="$(dec '{"stage": "after", "before": "takeover", "response": {"won": true, "renewed": true, "claim": {}}}')"
printf '%s' "$out" | grep -q '"action": "proceed"' && ok "(22e) a renewed win after a takeover → proceed" || bad "(22e) $out"

# a release holds the train claim (its train phase): live releases the backstop key busy, not final
python3 "$WORK/store.py" "$WORK/s23" claim '{"kind": "release-train", "key": "acme/widgets", "holder": "releaser", "now": "2026-11-09T10:00:00Z", "expiryMinutes": 30}' >/dev/null </dev/null
got="$(drive s23 one 2026-11-09T10:05:00Z)"
r="$(row s23 "release-train $KEY")"
printf '%s' "$r" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["outcome"] == "busy" and r["final"] is False, r' \
  && [ "$got" = "BUSY" ] && ok "(23) live, the train claim held by a release → BUSY, the backstop key released busy, not final" || bad "(23) $got — $r"
python3 "$WORK/store.py" "$WORK/s23" release '{"kind": "release-train", "key": "acme/widgets", "holder": "releaser", "now": "2026-11-09T10:06:00Z", "outcome": "handed-on"}' >/dev/null </dev/null
got="$(drive s23 two 2026-11-09T10:07:00Z)"
[ "$got" = "START" ] && ok "(23b) once that release hands the train on, the next check starts (busy never blocked the key)" || bad "(23b) $got"
conf shadow
python3 "$WORK/store.py" "$WORK/s24" claim '{"kind": "release-train", "key": "acme/widgets", "holder": "releaser", "now": "2026-11-09T10:00:00Z", "expiryMinutes": 30}' >/dev/null </dev/null
got="$(drive s24 one 2026-11-09T10:05:00Z)"
r="$(row s24 "release-train $KEY:shadow")"; t="$(row s24 "release-train acme/widgets")"
printf '%s' "$r" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["outcome"] == "busy" and r["final"] is False and r["result"]["trainClaim"] == "held", r' \
  && printf '%s' "$t" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["claimedAt"] == "2026-11-09T10:00:00Z" and "releasedAt" not in r, r' \
  && [ "$got" = "BUSY" ] \
  && ok "(24) shadow mirrors live: train claim held → busy, not final; the train claim itself untouched" || bad "(24) $got — $r — $t"
got="$(drive s24b one 2026-11-09T10:05:00Z)"
[ "$got" = "SHADOW" ] && [ "$(row s24b "release-train acme/widgets")" = none ] && ok "(24b) shadow, train free → SHADOW, the claim kept, the train never claimed" || bad "(24b) $got"
conf live
prs '[{"number": 5, "headRefName": "develop"}]'
got="$(drive s25 one 2026-11-09T10:05:00Z)"
[ "$got" = "NOOP SKIP" ] && [ ! -e "$WORK/s25" ] && ok "(25) a release in progress is found before any claim: no claim churn" || bad "(25) $got"
prs '[]'
# A sees nothing in progress; B starts a release (its pull request opens); A then wins both claims → the
# recheck under the train claim finds it and backs out
got="$(drive s26 one 2026-11-09T10:05:00Z "printf '[{\"number\": 6, \"headRefName\": \"develop\"}]' > '$WORK/prs.json'")"
t="$(row s26 "release-train acme/widgets")"; r="$(row s26 "release-train $KEY")"
printf '%s' "$t" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["outcome"] == "released" and r["final"] is False, r' \
  && printf '%s' "$r" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["outcome"] == "changed" and r["final"] is False, r' \
  && [ "$got" = "CHANGED" ] && ok "(26) A sees clear, B starts, A wins the claims → the recheck backs out, both claims released not final" || bad "(26) $got — $t — $r"
prs '[]'

# --- shipping moves the key; clock skew -------------------------------------------------------------
g "$WORK/seed" checkout -q -b ship origin/develop
at 2026-11-09T11:00:00Z "$WORK/seed" merge -q --no-ff -m "release: train into develop" "$OLDEST"
g "$WORK/seed" push -q origin ship:develop
NEXT="$(g "$WORK/seed" rev-parse 't~1')"
expect "(27) once the oldest landing is on the source, the next oldest keys the backstop" 0 "^START acme/widgets@$NEXT \(the oldest of 2 landing" due --now 2026-11-09T12:00:00Z --holds "$WORK/clear.json"
at 2026-11-09T11:30:00Z "$WORK/seed" merge -q --no-ff -m "release: train into develop" t
g "$WORK/seed" push -q origin ship:develop
land 2026-11-10T10:00:00Z skew-first I20101
land 2026-11-10T07:00:00Z skew-second I20102
SKEWED="$(g "$WORK/seed" rev-parse HEAD)"
g "$WORK/seed" push -q origin t:train/release
out="$(run due --now 2026-11-10T09:01:00Z --holds "$WORK/clear.json" --json)"
printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["oldestLanding"] == sys.argv[1] and d["landedAt"] == "2026-11-10T07:00:00+00:00" and d["waitedMinutes"] == 121 and d["verdict"] == "START", d
' "$SKEWED" && ok "(28) clock skew: the later merge stamped 07:00 is the oldest by committer time, keyed and aged from 07:00" || bad "(28) $out"

# --- exit codes and the contract -----------------------------------------------------------------
CONTRACT="$ROOT/skills/release/references/backstop.md"; T=0
for pair in "START 0" "SHADOW 10" "SKIP 11" "OFF 12" "HOLDS 13" "ERROR 1"; do
  set -- $pair
  grep -Eq "^\| \`$1\` \| $2 \|" "$CONTRACT" || { bad "(29) the contract's exit table lacks $1 → $2"; T=1; }
  grep -Eq "^ +$1 .*exit $2\$" "$HELPER" || { bad "(29) the script's header lacks $1 → exit $2"; T=1; }
done
[ "$T" = 0 ] && ok "(29) the contract's verdict table and the script's header agree on every exit code"
grep -q 'never release it on a start' "$CONTRACT" && grep -q 'retried once per window' "$CONTRACT" && grep -q -- '--recheck <key>' "$CONTRACT" \
  && grep -q 'only after the shadow results were checked' "$CONTRACT" && grep -q 'smallest committer time' "$CONTRACT" \
  && ok "(30) the contract: the claim lapses instead of being released, the recheck, live only after shadow, the oldest by time" || bad "(30) contract wording"

exit $FAIL
