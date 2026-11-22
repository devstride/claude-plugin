---
load: contract
---
# Read the release shape — new, an open release to adopt, or a merged one to close out

`release-steps`' `release-shape@1` step. It reads only, and every later step is handed its result
as `shape` (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`).

1. **Config wins.** Load `.claude/ds-config.json`: the release goes from `release.releaseSource`
   (shipped default `develop`) to `release.productionBranch` (`master`), whatever branch the
   checkout is on. Also `release.releaseBranchPattern`, `release.releaseBranchFixExclusions` and
   `release.clearance`.
2. **Look for a release already in flight.** List the open pull requests into the production
   branch whose head is a release branch: a name matching `release.releaseBranchPattern`,
   anchored as `${CLAUDE_PLUGIN_ROOT}/skills/release/references/branch-patterns.md` says and never
   by substring; with no pattern, a head that is the release source. A hotfix head never counts.
3. **Whose is it?** (`resume-rules.md` "Whose release it is".)
   - No `release.clearance` block, or scope `release` (the tower claim has already settled who
     runs): the open one is this run's. More than one → `CONFLICT`, naming them: one release at a
     time, and the owner says which.
   - Scopes `cut-to-deploy` and `merge-and-deploy`: it is this run's when its
     `devstride:release-holder` marker is this session's, or when the tower claim adopted it on
     the owner's yes (the provider's local record names its branch and pull request). Another
     session's is theirs: say whose it is and leave it alone. Under `merge-and-deploy` it is
     simply ahead in the queue. Under `cut-to-deploy` a live holder keeps it, this run waits at
     the tower claim, and the shape is read again once cleared; with NO live holder it is never
     adopted silently → `CONFLICT`, naming it, for the owner to decide.
4. **This run's open release → the fix-exclusion check, then adopt.** Every commit on the branch
   since its cut is checked against `release.releaseBranchFixExclusions` (the anchored rule of
   `branch-patterns.md`). A match → `REFUSED`, naming the files: abandon that branch and cut
   again. Clean → `ADOPTED`: it is never duplicated.
5. **None open that is this run's.** A merged release pull request that was never closed out —
   the one the provider's local record names after an adoption, or the one the tower's `status`
   shows a stale clearance still holding — → `MERGED`: the run carries on at the deploy
   confirmation and the close-out. Otherwise `NEW`.

## Verdict

`RELEASE SHAPE: NEW | ADOPTED <pr> | MERGED <pr> | CONFLICT <prs> | REFUSED <files>`

## Result

`shape`: `NEW`, `ADOPTED` or `MERGED` (absent on a stop); `pullRequest`: its number, or null;
`branch`: its head branch, or null.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
