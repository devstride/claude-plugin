---
load: contract
---
# Discharge the pre-ship hold — the ready flip, once, after the checks

`release-steps`' `pre-ship-resume@1` step, run after the release's pre-ship checks passed. What
the resume does is `${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-pr.md` "Step 2c",
cited, not copied.

1. **Config wins.** Load `.claude/ds-config.json`: `preShipChecks`, `release.productionReview`.
2. **Shape** (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`): `MERGED`
   → `NO HOLD`.
3. **Was a hold declared?** Yes when `pre-ship release select` prints `PRE-SHIP SELECTED` (the
   review declared one whenever it does), and yes on the identical-tree path of
   `${CLAUDE_PLUGIN_ROOT}/skills/release/references/review-once.md`, which leaves the ready flip
   to this step. Neither → `NO HOLD`: the review marked the pull request ready itself.
4. **Never discharge over a red or unrun check.** The pre-ship step answered `PRE-SHIP: PASS`
   (each entry passed, or was waived on the owner's own words) at the head the review settled.
   Otherwise → `STILL HELD`, naming the entry; never "covered by CI". Under scope
   `merge-and-deploy` a settled head whose tree equals the checks stamp's tree counts the checks'
   own `PRE-SHIP` line ("passed at <sha>"); any other tree needs that pre-ship step at the settled
   head first (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/clearance.md` "Scope
   `merge-and-deploy`").
5. **Re-invoke `review` in PRE-SHIP RESUME mode, naming that mode** — a plain re-invocation
   wrongly restarts cycle 1 — with the same ledger, target and safety triggers. It re-enters at
   its 7.1, re-checks the unresolved threads, marks the pull request ready and settles CI, once.
   Heartbeat the train claim through the CI wait (`resume-rules.md` "Heartbeats").
6. **Answer.** Ready and CI settled green → `DISCHARGED`. A suite or a check that cannot go green
   → `STILL HELD`, saying why: that is the owner's decision (a waiver at the pre-ship step), never
   this step's. A declared hold is never left undischarged without saying so: the pull request
   would stay a draft and CI would never run.

## Verdict

`PRE-SHIP HOLD: DISCHARGED | NO HOLD | STILL HELD <why>`

## Result

`state`: `discharged`, `no-hold` or `still-held`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
