---
load: contract
---
# Hand on the train claim — the next train phase may start

`release-steps`' `train-claim-hand-on@1` step. The rule is
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/auto-start.md` "The train claim" ("Release it
NON-final"), cited, not copied; the call is
`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/story-claims.md`'s.

1. **Config wins.** Load `.claude/ds-config.json`. No `claims` block, a `MERGED` shape
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`), or a train claim
   this session does not hold (read it, never assume) → `NOT APPLICABLE`: there is nothing to
   hand on.
2. **Both `release.clearance` and `release.releaseBranchPattern` set?** Without either the
   release pull request has no tower, or no branch of its own, to protect it → `HELD`, saying
   which is missing: the claim is held until the run ends.
3. **Is the release far enough?**
   - Scopes `release` and `cut-to-deploy`: the release branch exists on origin and this session
     holds the tower (its local clearance record).
   - Scope `merge-and-deploy` (no tower is held before the final gate): the release pull request
     is open AND the train is level with the source (`git fetch`, then `git merge-base
     --is-ancestor origin/<releaseSource> origin/<train>`), since that open pull request is what
     queues every later release behind this one.
   - Not yet → `HELD`, saying what is missing. A train with nothing to ship changes neither
     point. An `ADOPTED` release already has its branch and pull request.
4. **Release the claim NON-final**: kind `release-train`, the key from `python3
   ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/auto-start.py key`, outcome `handed-on`. Never
   `done`, never final (`final: true`, `--final`): the next cycle must be able to claim it. A
   release call that fails → `HELD`, naming the failure: the claim lapses by itself.
5. `HANDED ON`. From here this run does not hold the train claim and sends it no heartbeat; the
   next train phase runs while this release is reviewed and deployed, and the close-out's train
   levelling claims it again
   (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-branch.md` §5 step 3).

## Verdict

`TRAIN CLAIM: HANDED ON | HELD <why> | NOT APPLICABLE`

## Result

`state`: `handed-on`, `held` or `not-applicable`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
