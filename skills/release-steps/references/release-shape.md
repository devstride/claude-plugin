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
   - Scope `merge-and-deploy`: it is this run's when its `devstride:release-holder` marker is
     this session's, or when the provider's local record names it (adopted on the owner's yes).
     Another session's is theirs, simply ahead in the queue: say whose and leave it alone.
   - Scope `cut-to-deploy` (no marker; the tower's `status` decides, as `clearance.md` "Scope
     `cut-to-deploy`" says): this session's local record names it, or the tower is clear → this
     run's. A live holder keeps it. A stale clearance still naming it is never adopted here or
     silently. For both, and for a `status` that cannot be read, this run's shape is `NEW`, with
     that pull request and its holder named in the evidence: the tower claim waits behind the
     live one, and asks the owner about the stale one (`STALE`; a yes there makes every later
     step take the adopted path, `resume-rules.md`).
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
