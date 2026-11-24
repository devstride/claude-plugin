---
load: contract
---
# Finish the earlier train — and the gate every train mode checks first

`release-steps`' `train-finish@1` step, the first of the train phase: an earlier run that merged
its train pull request and then stopped is finished before anything new is cut. The procedure it
belongs to is `${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-branch.md` §1, cited, not
copied.

## The train phase

Every train mode (`train-finish`, `ship-plan`, `train-snapshot`, `train-pr`, `train-review`,
`train-merge`, `train-close-out`, and `train-level` at its place in this phase) checks this first.

- **Config wins.** Load `.claude/ds-config.json`. `releaseTrain` is read as `release-branch.md`'s
  opening says, its older name included; the config error it names there → no verdict line: name
  it, and stop.
- **`NOT APPLICABLE`**, with one line saying why ("release train: not configured", or "skipped:
  adopted release"), when `release.mergeTrainBeforeCut` is not `true`, when `releaseTrain.branch`
  is absent from the config or from origin, or when the payload's `shape` is `ADOPTED` or `MERGED`
  or its `tower` says `adopted: true`
  (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md` "What each shape skips").
- **A renamed train stops the release.** `releaseTrain.branch` absent from origin while another
  `train/*` branch is there: no verdict line; name the cutover and stop. One-offs ride that branch
  until it is renamed, and a release never goes around it.
- **Only under the train claim.** With a `claims` block, no train pull request is opened, adopted
  or pushed to, and the train is never pushed, unless this run holds the `release-train` claim
  (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/auto-start.md` "The train claim"); it is
  heartbeated through every wait (`resume-rules.md` "Heartbeats"). With no `claims` block the
  holder marker alone decides (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/clearance.md`).
- **This run's train pull request** is the OPEN one that `release-branch.md` §1 "Finding
  release-train pull requests" finds (both title spellings, the complete range marker, never a
  substring) and that the snapshot step adopted or this run opened. Its range, `<sourceBefore>`
  and `<trainSnapshot>`, is read from its marker and never from the live train. None open, and no
  snapshot branch of this run waiting for its pull request → nothing is in flight, and
  `train-pr`, `train-review` and `train-merge` answer `NOT APPLICABLE`.

## Procedure

1. **The gate above.** Not applicable → `NOT APPLICABLE`.
2. **The tower heartbeat `train`**, at this step's first mutation and only when this session's
   local clearance record shows it holds the tower (scope `release`; `resume-rules.md`
   "Heartbeats"). Exit 4 is a stop.
3. **Find the latest merged release-train pull request** by the finding rule above (the latest
   `mergedAt`). None → `NONE`.
4. **Close what it carried**, over its marker's range, exactly as
   `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/train-close-out.md` steps 3 to 5 say.
   Items already Done, or already carrying that pull request's "reached" comment, are skipped,
   so a finished run is a no-op and a re-opened item is never closed again.
5. **Answer.** At least one item closed → `FINISHED`, naming the pull request and the count, with
   every candidate that could not be marked listed as "not marked Done: <subject>". Nothing left
   to close → `NONE`.

## Verdict

`EARLIER TRAIN: FINISHED <pr> | NONE | NOT APPLICABLE`

## Result

`state`: `finished`, `none` or `not-applicable`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
- every train-phase reference of `release-steps` ("The train phase")
