#!/bin/bash
# Tests for skills/release/scripts/auto-start.py — the precondition half of release.autoStart.
# A temporary repository with a bare origin carries a release source and a train; a `gh` on PATH
# that always fails proves the check never calls it. Each switch that is off answers SKIP; a train
# holding real work answers START with the lower-cased claim key; two starters racing for a
# stand-in claims store (an atomic mkdir) produce one winner; and story-claim.py decide shows why
# the release-train claim is released non-final. No network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/skills/release/scripts/auto-start.py"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

g() { git -C "$1" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "${@:2}"; }
git init -q --bare "$WORK/origin.git"
git init -q -b develop "$WORK/seed"
g "$WORK/seed" commit -q --allow-empty -m base
g "$WORK/seed" remote add origin "$WORK/origin.git"
g "$WORK/seed" push -q origin develop
g "$WORK/seed" push -q origin develop:train/release
git clone -q "$WORK/origin.git" "$WORK/repo" 2>/dev/null
g "$WORK/repo" remote set-url origin "git@github.com:acme/widgets.git"
g "$WORK/repo" config remote.origin.pushurl "$WORK/origin.git"
g "$WORK/repo" config url."$WORK/origin.git".insteadOf "git@github.com:acme/widgets.git"
mkdir -p "$WORK/repo/.claude" "$WORK/bin"

# a gh that fails: the check must not need it
cat > "$WORK/bin/gh" <<'SH'
#!/bin/bash
echo "gh: must not be called" >&2; exit 1
SH
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

cfg() { printf '%s\n' "$1" > "$WORK/repo/.claude/ds-config.json"; }
run() { (cd "$WORK/repo" && python3 "$HELPER" "$@" 2>&1); }
expect() { # label, expected exit, first-line regex
  local out code; out="$(run check)"; code=$?
  if [ "$code" = "$2" ] && printf '%s\n' "$out" | head -1 | grep -Eq "$3"; then ok "$1"; else bad "$1  (exit $code) $out"; fi
}

ON='{"baseBranch": "develop", "claims": {"provider": "devstride"}, "releaseTrain": {"branch": "train/release"}, "release": {"releaseSource": "develop", "mergeTrainBeforeCut": true, "autoStart": {"enabled": true}}}'

cfg '{"release": {"mergeTrainBeforeCut": true}, "releaseTrain": {"branch": "train/release"}, "claims": {"provider": "devstride"}}'
expect "(1) autoStart absent → SKIP" 0 '^SKIP release.autoStart.enabled is not true$'
cfg '{"release": {"autoStart": {"enabled": true}, "mergeTrainBeforeCut": true}, "releaseTrain": {"branch": "train/release"}}'
expect "(2) no claims block → SKIP, never a start" 0 '^SKIP release.autoStart needs a claims block'
cfg '{"claims": {"provider": "devstride"}, "release": {"autoStart": {"enabled": true}}}'
expect "(3) no release train → SKIP" 0 '^SKIP no release train'

cfg "$ON"
expect "(4) a train level with the source → SKIP, no claim" 0 '^SKIP the train holds nothing beyond develop$'

# a merge of the source alone is not work
g "$WORK/seed" checkout -q -b side develop
g "$WORK/seed" commit -q --allow-empty -m "source moves"
g "$WORK/seed" push -q origin side:develop
g "$WORK/seed" checkout -q -b t origin/train/release 2>/dev/null || { g "$WORK/seed" fetch -q origin; g "$WORK/seed" checkout -q -b t origin/train/release; }
g "$WORK/seed" merge -q --no-ff -m "merge develop into train" side
g "$WORK/seed" push -q origin t:train/release
expect "(5) a train holding only a merge of the source → SKIP" 0 '^SKIP the train holds nothing beyond develop$'

g "$WORK/seed" commit -q --allow-empty -m "one-off A"
g "$WORK/seed" commit -q --allow-empty -m "one-off B"
g "$WORK/seed" push -q origin t:train/release
expect "(6) two one-offs on the train → START with the key and the count, gh never called" 0 \
  '^START acme/widgets \(2 commit\(s\) on train/release not on develop\)$'

cfg '{"baseBranch": "develop", "claims": {"provider": "devstride"}, "supportTrain": {"branch": "train/release"}, "release": {"releaseSource": "develop", "mergeTrainBeforeCut": true, "autoStart": {"enabled": true}}}'
expect "(7) the old name supportTrain is honoured" 0 '^START acme/widgets '
cfg '{"claims": {"provider": "devstride"}, "releaseTrain": {"branch": "train/release"}, "supportTrain": {"branch": "train/release"}, "release": {"mergeTrainBeforeCut": true, "autoStart": {"enabled": true}}}'
expect "(7b) both releaseTrain and supportTrain → ERROR, exit 1" 1 '^ERROR both releaseTrain and supportTrain are set'
cfg "$ON"

out="$(run key)"; [ "$out" = "acme/widgets" ] && ok "(8) key reads <owner>/<repo> from origin" || bad "(8) $out"
out="$(AUTO_START_REPO=other/thing run key)"; [ "$out" = "other/thing" ] && ok "(9) AUTO_START_REPO overrides the key" || bad "(9) $out"
g "$WORK/repo" config remote.origin.url "https://github.com/Acme/Widgets.git"
out="$(run key)"; [ "$out" = "acme/widgets" ] && ok "(9b) another spelling of the same remote claims the same lower-cased key" || bad "(9b) $out"
g "$WORK/repo" config remote.origin.url "git@github.com:acme/widgets.git"

printf '{not json' > "$WORK/repo/.claude/ds-config.json"
out="$(run check)"; code=$?
[ "$code" = 1 ] && printf '%s\n' "$out" | grep -q '^ERROR .*cannot be read as JSON' && ok "(10) an unreadable config → ERROR, exit 1" || bad "(10) (exit $code) $out"

out="$(cd "$WORK/repo" && python3 "$HELPER" 2>&1)"; code=$?
[ "$code" = 2 ] && ok "(11) no verb → usage, exit 2" || bad "(11) (exit $code) $out"

# (12) two sessions reach a trigger at once: both see START, the claim decides. A stand-in store
# whose claim is an atomic mkdir; each starter writes WON or LOST.
cfg "$ON"
STORE="$WORK/claims"; mkdir -p "$STORE"
starter() {
  local line; line="$(run check | head -1)"
  case "$line" in START*) ;; *) echo "SKIPPED" > "$WORK/starter-$1"; return;; esac
  if mkdir "$STORE/release-train:$(run key | tr / _)" 2>/dev/null; then echo WON > "$WORK/starter-$1"; else echo LOST > "$WORK/starter-$1"; fi
}
starter one & starter two & wait
got="$(cat "$WORK/starter-one" "$WORK/starter-two" | sort | tr '\n' ' ')"
[ "$got" = "LOST WON " ] && ok "(12) two starters at one trigger → exactly one wins the release-train claim" || bad "(12) $got"

# (13)-(14) why the claim is released NON-final at the cut: through story-claim.py decide, a
# release-train claim released with outcome done answers every later claim with "already finished"
# (skip: no release could ever start again), while a released non-final claim is won again.
DECIDE="$ROOT/skills/build-item/scripts/story-claim.py"
ask() { printf '{"mode":"select","item":"the release train","response":%s,"me":"bb","now":"2026-01-15T18:00:00Z","tz":"America/Chicago"}' "$1" | python3 "$DECIDE" decide; }
final='{"won": false, "final": true, "claim": {"kind": "release-train", "key": "acme/widgets", "holderDigest": "aa", "machine": "m", "sessionName": "s", "releasedAt": "x", "outcome": "done"}}'
again='{"won": true, "claim": {"kind": "release-train", "key": "acme/widgets", "holderDigest": "bb"}}'
ask "$final" | grep -q '"action": "skip"' && ok "(13) a final release-train claim would block every later release (so it is never released final)" || bad "(13) $(ask "$final")"
ask "$again" | grep -q '"action": "proceed"' && ok "(14) after a non-final release the next cycle wins the claim again" || bad "(14) $(ask "$again")"
grep -q 'NON-final' "$ROOT/skills/release/references/auto-start.md" && ! grep -Eq 'release-train.*outcome `?done' "$ROOT/skills/release/references/auto-start.md" \
  && ok "(15) the contract releases the train claim non-final, never done" || bad "(15) auto-start.md"

exit "$FAIL"
