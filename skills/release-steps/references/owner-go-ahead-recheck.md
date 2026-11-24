---
load: contract
---
# The go-ahead again at the final gate — the standing yes with the tower held, or the earlier yes

`release-steps`' `owner-go-ahead-recheck@1` step: under scope `merge-and-deploy` only, after the
final tower claim and before the merge confirmations. It is its own contract so that a copy of the
workflow cannot drop either go-ahead: it requires the first one (`owner-go-ahead@1`) before it, and
the merge confirmations need a go-ahead given after the tower claim, which only this step is.
The procedure is `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/owner-go-ahead.md`, cited,
not copied: its steps 1, 2, 4, 6, 7 and 9 hold here unchanged, and step 8 is this step.

1. **Shape** (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`): `MERGED`
   → `YES (already merged)`, naming the pull request. Nothing is asked and nothing is merged.
2. **No heartbeat here.** The tower claim right before this step already sent the final one.
3. **Run the standing yes again**, with `--tower` read after the claim (`owner-go-ahead.md` step
   6). `MERGE` → `YES (standing)`, its comment posted once.
4. **Else apply the earlier yes.** The payload's `goAhead` is the first go-ahead's result: when
   it is `yes-owner` at the same `<reviewedHead>` (the payload's `releaseReview`), → `YES (owner)`.
   A yes the owner gives in the payload's `answer` now counts as well (`owner-go-ahead.md` step 7).
5. **Neither** → `NOT YET`, saying what is waited for (`owner-go-ahead.md` step 9). The tower is
   held while this step waits, so say so in the recap.

## Verdict

`GO-AHEAD: YES <source> | NOT YET | NO`

## Result

`state`: `yes-owner`, `yes-standing`, `already-merged`, `not-yet` or `no`; `answer`: the owner's
own words when they gave any, otherwise left out.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/owner-go-ahead.md`
