#!/bin/bash
# Contract test for the ordinary two-cycle target and P1/serious-P2 safety continuation.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; FAIL=0
ok() { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; FAIL=1; }
has() { grep -qF -- "$2" "$ROOT/$1"; }

if has skills/plan/references/delivery-profiles.md '| `targetAdversarialCycles` — fixed, non-overrideable target across every reviewer/recheck | **2** | **2** | **2** |'; then
  ok "(1) every profile targets two adversarial cycles"
else bad "(1) profile target drifted"; fi

if has skills/review/SKILL.md 'Repeat until a cycle finds none, without numeric or' &&
   has skills/review/SKILL.md 'any P1/serious P2 verified against'; then
  ok "(2) P1/serious-P2 findings extend review past the target"
else bad "(2) severity continuation missing"; fi

if has skills/ultracode-build/references/review-fanout.md 'likelihood = likely **and** impact = material' &&
   has skills/review/references/review-ledger.md 'safety trigger: <open|consumed in cycle N|none>'; then
  ok "(3) serious P2 is defined and its trigger is ledgered"
else bad "(3) severity or ledger contract missing"; fi

if has skills/review/scripts/rereview-scope.sh '--reviewed-head <sha>' &&
   ! grep -qF -- '--round1' "$ROOT/skills/review/scripts/rereview-scope.sh"; then
  ok "(4) cycle N scopes from the prior cycle anchor"
else bad "(4) follow-up scope regressed to round 1"; fi

if grep -R -qF 'maxAdversarialCycles' "$ROOT/skills" "$ROOT/README.md"; then
  bad "(5) stale hard-cap key remains"
else ok "(5) no stale hard-cap key remains"; fi

if has skills/review/SKILL.md 'cycleAnchor = HEAD' &&
   has skills/review/references/review-ledger.md 'Imported ids are aliases (`story:<item>:F1`'; then
  ok "(6) every cycle has one common anchor and imported ids cannot collide"
else bad "(6) anchor or id-namespace contract missing"; fi

if has skills/review/SKILL.md 'gh pr ready --undo' &&
   has skills/review/SKILL.md 'Findings return through steps 3–6.5 and'; then
  ok "(7) post-ready fixes re-hold CI and settle late threads"
else bad "(7) post-ready settlement contract missing"; fi

exit "$FAIL"
