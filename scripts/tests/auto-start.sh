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
cfg '{"baseBranch": "main", "claims": {"provider": "devstride"}, "releaseTrain": {"branch": "train/release"}, "release": {"mergeTrainBeforeCut": true, "autoStart": {"enabled": true}}}'
expect "(4b) releaseSource absent → develop, never baseBranch (main, which does not exist here)" 0 '^SKIP the train holds nothing beyond develop$'
cfg "$ON"

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
# whose claim is an atomic mkdir; each starter writes WON or LOST. The mkdir is Python's os.mkdir
# (one mkdir(2) system call), never the mkdir command: uutils coreutils (Ubuntu 25.10 onward, the
# CI image) reports success to both of two racing `mkdir` runs on one path about 1 time in 12,
# which made both starters win here while the real claim path was never at fault.
cfg "$ON"
STORE="$WORK/claims"; mkdir -p "$STORE"
starter() {
  local line; line="$(run check | head -1)"
  case "$line" in START*) ;; *) echo "SKIPPED" > "$WORK/starter-$1"; return;; esac
  local key; key="$(run key)" || { echo "KEYFAIL $key" > "$WORK/starter-$1"; return; }
  if python3 -c 'import os, sys; os.mkdir(sys.argv[1])' "$STORE/release-train:$(printf '%s' "$key" | tr / _)" 2>/dev/null; then echo "WON $key" > "$WORK/starter-$1"; else echo "LOST $key" > "$WORK/starter-$1"; fi
}
starter one & starter two & wait
got="$(cut -d' ' -f1 "$WORK/starter-one" "$WORK/starter-two" | sort | tr '\n' ' ')"
[ "$got" = "LOST WON " ] && ok "(12) two starters at one trigger → exactly one wins the release-train claim" \
  || bad "(12) $got — $(cat "$WORK/starter-one" "$WORK/starter-two" | tr '\n' '|')"

# (13)-(15) the claim is released NON-final at the cut. The contract's release call (outcome and
# final flag) is read from auto-start.md and run through a stand-in store with the server's rule —
# only `final: true` blocks a key for good, the outcome is a free string — and story-claim.py decide
# then judges the next claim.
BULLET="$(awk '/Release it NON-final/{f=1} f&&/^- \*\*/&&!/NON-final/{exit} f{print}' "$ROOT/skills/release/references/auto-start.md" | tr '\n' ' ')"
OUTCOME="$(printf '%s' "$BULLET" | grep -o 'with outcome `[a-z-]*`' | head -1 | sed 's/.*`\(.*\)`/\1/')"
FINAL=true; printf '%s' "$BULLET" | grep -q 'never final' && ! printf '%s' "$BULLET" | grep -Eq 'with `?final: true|`--final` set' && FINAL=false
[ "$OUTCOME" = handed-on ] && [ "$FINAL" = false ] && ok "(13) the contract releases with outcome $OUTCOME and never final" || bad "(13) outcome '$OUTCOME' final '$FINAL'"
OUT="$(python3 - "$ROOT/skills/build-item/scripts/story-claim.py" "$OUTCOME" "$FINAL" <<'PY'
import json, subprocess, sys
helper, outcome, final = sys.argv[1], sys.argv[2], sys.argv[3] == "true"
rows = {}
def claim(key, me):
    row = rows.get(key)
    if row and row["releasedAt"] and row["final"]:
        return {"won": False, "final": True, "claim": row}
    if row and not row["releasedAt"] and row["holderDigest"] != me:
        return {"won": False, "claim": row}
    rows[key] = {"kind": "release-train", "key": key, "holderDigest": me, "machine": "m", "sessionName": "s",
                 "claimedAt": "2026-01-15T18:00:00Z", "heartbeatAt": "2026-01-15T18:00:00Z",
                 "expiresAt": "2026-01-15T18:30:00Z", "releasedAt": None, "outcome": None, "final": False}
    return {"won": True, "claim": rows[key]}
def release(key, outcome, final=False):
    rows[key].update(releasedAt="2026-01-15T18:10:00Z", outcome=outcome, final=final)
def decide(resp, me):
    req = {"mode": "select", "item": "the release train", "response": resp, "me": me, "now": "2026-01-15T18:11:00Z", "tz": "America/Chicago"}
    return json.loads(subprocess.run([sys.executable, helper, "decide"], input=json.dumps(req), capture_output=True, text=True).stdout)["action"]
k = "acme/widgets"
first = decide(claim(k, "aa"), "aa")
held = decide(claim(k, "bb"), "bb")
release(k, outcome, final)
second = decide(claim(k, "bb"), "bb")
rows.clear(); claim(k, "aa"); release(k, outcome, True)
blocked = decide(claim(k, "bb"), "bb")
print(first, held, second, blocked)
PY
)"
set -- $OUT
[ "$1 $2" = "proceed skip" ] && ok "(14) the first claim proceeds and a second session is held off" || bad "(14) $OUT"
[ "$3" = proceed ] && [ "$4" = skip ] && ok "(15) released as the contract says the next cycle claims again; released final it never could" || bad "(15) $OUT"

# (16) both build-item trigger sites fire LAST, after the caller's own recap and close-out
order_ok() { # file, a phrase that must come before the trigger
  awk -v p="$2" 'index($0, p) {seen=NR} /autoStart.enabled/ {t=NR} END {exit !(seen && t && t > seen)}' "$ROOT/skills/build-item/references/$1"
}
lease_kept() { awk '/autoStart.enabled/{f=1} f' "$ROOT/skills/build-item/references/$1" | tr '\n' ' ' | tr -s ' ' | grep -q 'checkout lease is KEPT through it: `return-checkout` waits'; }
order_ok release-train.md "Step 7 terminates" && order_ok epic-release-steps.md "Human recap" \
  && lease_kept release-train.md && lease_kept epic-release-steps.md \
  && grep -q 'The caller keeps its checkout lease until then' "$ROOT/skills/release/references/auto-start.md" \
  && ok "(16) both triggers come after the recap and keep the checkout lease through the release they start" || bad "(16) a trigger precedes its caller's close-out, or the lease is returned before it"

# (17) one lock order for every run: release step 0 takes the train claim before adopting a release
# pull request and before 0a's tower claim, and the contract says so for hand and auto starts alike
SK="$ROOT/skills/release/SKILL.md"
flat() { tr '\n' ' ' < "$1" | tr -s ' '; }   # wrapped prose read as one line
line_of() { grep -n -F -- "$2" "$1" | head -1 | cut -d: -f1; }
T="$(line_of "$SK" 'the train claim first**')"; S="$(line_of "$SK" '**Confirm the shape**')"; C="$(line_of "$SK" '**0a. Clearance**')"
[ -n "$T" ] && [ -n "$S" ] && [ -n "$C" ] && [ "$T" -lt "$S" ] && [ "$S" -lt "$C" ] \
  && grep -q 'One lock order, train then' "$ROOT/skills/release/references/auto-start.md" \
  && grep -q "auto-start.md\`'s lock order" "$ROOT/skills/release/references/clearance.md" \
  && ! flat "$SK" | grep -q 'claims it before anything else' \
  && ! flat "$ROOT/skills/release/references/clearance.md" | grep -q 'purpose release` before anything else,' \
  && ok "(17) the train claim precedes release adoption and the tower claim, for every run" || bad "(17) lock order: train $T shape $S clearance $C"

# (18) after the hand-on, a release pushes the train only under the train claim again; every train
# pull request opened with a claims block carries the holder marker, and an absent one is never
# adopted silently
RB="$ROOT/skills/release/references/release-branch.md"; AS="$ROOT/skills/release/references/auto-start.md"
flat "$RB" | grep -q 'it pushes the train only under that claim again: one claim, no wait, decided in mode `select` however the release started' \
  && flat "$RB" | grep -q 'held by a live session → SKIP the leveling' \
  && flat "$ROOT/skills/release/references/clearance.md" | grep -q 'also re-level the train by `release-branch.md` §1 step 7' \
  && flat "$RB" | grep -q '(scope `cut-to-deploy` or a `claims` block: and the holder marker)' \
  && flat "$AS" | grep -q 'an ABSENT marker is ambiguous' \
  && ! flat "$AS" | grep -q "this session's, absent, or names" \
  && ok "(18) 5b levels the train only under a re-won claim; the holder marker is always written with claims and an absent one stops" \
  || bad "(18) the post-hand-on train push, the holder marker, or the absent-marker rule regressed"

# (20) a lapsed successor at 5b: select answers takeover, and the takeover claim then proceeds
T="$(python3 - "$ROOT/skills/build-item/scripts/story-claim.py" <<'PY3'
import json, subprocess, sys
lapsed = {"won": False, "claim": {"kind": "release-train", "key": "acme/widgets", "holderDigest": "bb", "machine": "m2",
          "sessionName": "next", "claimedAt": "2026-01-15T17:00:00Z", "heartbeatAt": "2026-01-15T17:05:00Z",
          "expiresAt": "2026-01-15T17:35:00Z", "releasedAt": None, "outcome": None, "final": False}}
won = {"won": True, "claim": dict(lapsed["claim"], holderDigest="aa", expiresAt="2026-01-15T18:40:00Z")}
def decide(resp):
    req = {"mode": "select", "item": "the release train", "response": resp, "me": "aa", "now": "2026-01-15T18:10:00Z", "tz": "America/Chicago"}
    return json.loads(subprocess.run([sys.executable, sys.argv[1], "decide"], input=json.dumps(req), capture_output=True, text=True).stdout)
first = decide(lapsed)
print(first["action"], first.get("takeoverDigest"), decide(won)["action"])
PY3
)"
[ "$T" = "takeover bb proceed" ] && ok "(20) a lapsed successor at 5b: takeover with its digest, then the won takeover proceeds" || bad "(20) decide answered '$T'"

# (19) the decision itself: 5b's re-claim of a train another live session holds is decided in mode
# select, which skips; mode named would stop while this release still holds the tower
D="$(python3 - "$ROOT/skills/build-item/scripts/story-claim.py" <<'PY2'
import json, subprocess, sys
held = {"won": False, "claim": {"kind": "release-train", "key": "acme/widgets", "holderDigest": "bb", "machine": "m2",
        "sessionName": "next", "claimedAt": "2026-01-15T18:00:00Z", "heartbeatAt": "2026-01-15T18:09:00Z",
        "expiresAt": "2026-01-15T18:39:00Z", "releasedAt": None, "outcome": None, "final": False}}
out = []
for mode in ("select", "named"):
    req = {"mode": mode, "item": "the release train", "response": held, "me": "aa", "now": "2026-01-15T18:10:00Z", "tz": "America/Chicago"}
    out.append(json.loads(subprocess.run([sys.executable, sys.argv[1], "decide"], input=json.dumps(req), capture_output=True, text=True).stdout)["action"])
print(" ".join(out))
PY2
)"
[ "$D" = "skip stop" ] && flat "$RB" | grep -q '`takeover` (its holder lapsed) → ONE immediate takeover claim with that digest, decided the same way, never a third' \
  && flat "$ROOT/skills/release/references/auto-start.md" | grep -q 'on the owner.s answer, heartbeat it before anything else; NOT HOLDER or LOST → with the tower held, carry on under the tower' && ok "(19) a live holder at 5b: select skips (the contract's mode), named would stop" || bad "(19) decide answered '$D'"

# (21)-(24) the configured train looked up on origin first, with routing.py's rule. Renamed and not
# yet cut over: origin has train/support, not train/release.
cfg "$ON"
g "$WORK/seed" push -q origin t:train/support
g "$WORK/seed" push -q origin :train/release
expect "(21) configured train missing, exactly one other train/* → ERROR naming the rename and its commands, no fetch of the missing branch" 1 \
  '^ERROR a release reads only train/release, so none can start until the rename is cut over; .*train/support → train/release .*--force-with-lease'
out="$(run check)"; printf '%s\n' "$out" | grep -q "couldn't find remote ref" && bad "(21b) still fetched the missing train: $out" || ok "(21b) the missing train is never fetched"
g "$WORK/seed" push -q origin t:train/other
expect "(22) several other train/* branches → ERROR asking which one is live" 1 '^ERROR the release train train/release is not on origin and several other train branches are'
g "$WORK/seed" push -q origin :train/support :train/other
expect "(23) no train on origin at all → SKIP, nothing has landed yet" 0 '^SKIP the release train train/release is not on origin yet'
g "$WORK/repo" fetch -q --prune origin
g "$WORK/repo" update-ref refs/remotes/origin/train/support refs/remotes/origin/develop
out="$(cd "$WORK/repo" && AUTO_START_NO_FETCH=1 python3 "$HELPER" check 2>&1)"; code=$?
[ "$code" = 1 ] && printf '%s\n' "$out" | grep -q '^ERROR a release reads only train/release' \
  && ok "(24) offline (AUTO_START_NO_FETCH=1) the heads come from the remote-tracking refs, same rule" || bad "(24) (exit $code) $out"
g "$WORK/seed" push -q origin t:train/release
mkdir -p "$WORK/nogit/.claude"; printf '%s\n' "$ON" > "$WORK/nogit/.claude/ds-config.json"
out="$(cd "$WORK/nogit" && GIT_CEILING_DIRECTORIES="$WORK" AUTO_START_NO_FETCH=1 python3 "$HELPER" check 2>&1)"; code=$?
[ "$code" = 1 ] && printf '%s\n' "$out" | grep -q "^ERROR listing origin's branches failed" \
  && ok "(25) branches that cannot be listed → ERROR, never a quiet SKIP" || bad "(25) (exit $code) $out"
NAME="$(printf 'train/release\302\240candidate')"
g "$WORK/seed" push -q origin "t:refs/heads/$NAME"
g "$WORK/repo" fetch -q --prune origin
out="$(cd "$WORK/repo" && AUTO_START_NO_FETCH=1 python3 -c 'import importlib.util,sys;s=importlib.util.spec_from_file_location("a",sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);print(chr(10).join(sorted(m.origin_heads("."))))' "$HELPER")"
on="$(cd "$WORK/repo" && python3 -c 'import importlib.util,sys;s=importlib.util.spec_from_file_location("a",sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);print(chr(10).join(sorted(m.origin_heads("."))))' "$HELPER")"
[ "$out" = "$on" ] && printf "%s\n" "$out" | grep -qxF "$NAME" \
  && ok "(26) a branch name holding a no-break space is one name, online and offline" || bad "(26) offline $out online $on"
g "$WORK/seed" push -q origin ":refs/heads/$NAME"

exit "$FAIL"
