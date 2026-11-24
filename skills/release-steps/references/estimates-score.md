---
load: contract
---
# Score the estimates — every quote the shipped items carried, measured against the release

`release-steps`' `estimates-score@1` step (the step `score-estimates`), right after the deploy
confirmation. The rule is `${CLAUDE_PLUGIN_ROOT}/skills/release/references/estimates.md`
"Scoring at the release", cited, not copied: its tokens, its comment and its `live` time. Scoring
never blocks or delays a release: every answer continues.

1. **The merge commit**, from this run's recorded results (the runner's `status`, never memory):
   `production-merge`'s `sha`, else `merged-release`'s. Under every shape
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`) the step runs, and an
   already-scored quote is never scored twice.
2. **Only after the deploy confirmation**: `confirm-deploy` answered `CONFIRMED` or
   `NOT CONFIGURED` (its confirmation skipped). Unconfirmed never reaches here: the run stopped.
3. **List what shipped**: `python3 ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/estimate.py
   shipped --merge <sha> --json` — the landings that merge brought, each with the items its commit
   message names.
4. **Score each open quote.** For each `[estimate v1 sha=<landing>…]` token a listed item carries
   with no `[estimate-score v1 …]` token for the same `sha` and `quoted`: `python3
   ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/estimate.py score --sha <sha> --quoted <quoted>
   --low <low> --high <high>`, then `add_comment` on that item: "Estimate scored: <line>" and its
   token, exactly as `estimates.md` gives them.
5. **Answer.** At least one quote scored → `SCORED <count>`. No open quote (none carried, or every
   one already scored) → `NONE`. A `PENDING` or `ERROR` from either command, or a comment that
   could not be written → no comment for that quote, said once on the evidence line →
   `NOTED FAILURE` (when nothing else was scored).

## Verdict

`ESTIMATES: SCORED <count> | NONE | NOTED FAILURE`

## Result

`state`: `scored`, `none` or `noted-failure`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
