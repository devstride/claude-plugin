---
load: contract
---
# Level the train — it never falls behind the release source

`release-steps`' `train-level@1` step: one step at up to three places (after the train merges,
after the cut under scope `merge-and-deploy`, and at close-out). The rule is
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-branch.md` §1 step 7, and at close-out
its §5 step 3; both cited, not copied.

1. **Where it runs.** The payload's `step` is `train-level-final` (in a copied definition with
   other ids: this run's release has already merged) → the close-out, step 3. Any other → before
   the merge, step 2.
2. **Before the merge.** The train gate
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/train-finish.md` "The train phase")
   applies: not applicable → `NOT APPLICABLE`. With a `claims` block the train is pushed only
   while this run holds the `release-train` claim; not held → `NOT APPLICABLE`, saying so. Then
   step 4.
3. **At close-out**, under every shape
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md` "What each shape
   skips"), so the release's own fixes reach the train too. `releaseTrain.branch` unset, or not
   on origin (a train not yet created, said so) → `NOT APPLICABLE`. With a `claims` block and the
   train claim already handed on, the train is pushed only under that claim again (§5 step 3;
   `${CLAUDE_PLUGIN_ROOT}/skills/release/references/auto-start.md`): ONE claim, no wait, decided
   in mode `select` however the release started. With no `claims` block → step 4.
   - Won, or still held from the start → step 4, then step 5.
   - `takeover` (its holder lapsed) → one immediate takeover claim with that digest, decided the
     same way; never a third.
   - Held by a live session → `NOT APPLICABLE`, saying who: that holder levels the train itself.
     Never a push beside a live holder.
   - A final claim, `stop` or `degrade` → no verdict line: say it and stop.
4. **Level.** `git fetch origin <releaseSource> <train>` first: the merges happened on GitHub, so
   local refs are stale.
   - The train already contains the source → `ALREADY LEVEL`.
   - `git merge-base --is-ancestor origin/<train> origin/<releaseSource>` → fast-forward it:
     `git push origin origin/<releaseSource>:refs/heads/<train>`, never `--force` →
     `FAST-FORWARDED`.
   - Otherwise one-offs landed meanwhile: merge `origin/<releaseSource>` into the train with `git
     merge --no-ff` and push → `MERGED SOURCE`. A conflict → `CONFLICT`, naming the files.
   Say how many unreleased one-offs the train now carries.
5. **At close-out, the next release** (a `claims` block, the claim held, and
   `release.autoStart.enabled`): run `python3
   ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/auto-start.py check` (`auto-start.md` trigger 5).
   `START` → KEEP the claim and record `autoStart` as `START`: the loop that runs the release
   starts the next one from here. Anything else → a claim taken in step 3 is released with outcome
   `handed-on`, never final; `ERROR` is said once.

## Verdict

`TRAIN LEVEL: FAST-FORWARDED | MERGED SOURCE | ALREADY LEVEL | CONFLICT <files> | NOT APPLICABLE`

## Result

`state`: `fast-forwarded`, `merged-source`, `already-level`, `conflict` or `not-applicable`;
`autoStart`: `START` only when step 5 kept the claim for the next release, else absent.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
