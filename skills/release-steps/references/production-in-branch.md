---
load: contract
---
# Bring production into the release branch — prepared on top of what is ahead

`release-steps`' `production-in-branch@1` step: right after the cut under scope
`merge-and-deploy`, and again whenever production moved (the release ahead merged, a hotfix
landed, a stamp went stale). The merge is
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-branch.md` §4, cited, not copied.

1. **Config wins.** Load `.claude/ds-config.json`. No `release.releaseBranchPattern` (there is no
   branch to merge into), or a `MERGED` shape
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`) → `NOT APPLICABLE`.
   An `ADOPTED` release still runs this step.
2. `git fetch origin <productionBranch> <release branch>`, then `python3
   ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/release_checks.py contains --head <the branch's
   head>`:
   - `CONTAINS` (exit 0) → `CONTAINS`: the branch holds everything production holds.
   - `BEHIND` (exit 3) → merge production in now, step 3.
   - `ERROR` (exit 1) → no verdict line: say why and stop. It is never read as `CONTAINS`.
3. **The merge.** On a pull request that is no longer a draft, `gh pr ready --undo` BEFORE the
   push, so CI never runs on an unreviewed head. Then `git switch <release branch> && git merge
   --no-ff origin/<productionBranch>`. A conflict → `CONFLICT`, naming the files, with the merge
   aborted and nothing pushed. Never rebase. This merge is exempt from the fix-exclusion check
   (what it brings is already in production).
4. Push the branch (a new commit only) → `MERGED`, naming the new head. The evidence says
   whether the tree changed or only the history did (`git diff --quiet <old head> <new head>`):
   `release-branch.md` §4 gives a same-tree merge no fresh review.
5. **What follows is the run's, not this step's.** Before the pull request is open the merge is
   simply pushed with the branch, and the first review reads it with everything else. After it,
   the review follows up over the merge's range and the checks run again on the new head; any
   owner yes already given is void.

## Verdict

`PRODUCTION IN BRANCH: CONTAINS | MERGED <sha> | CONFLICT <files> | NOT APPLICABLE`

## Result

`state`: `contains`, `merged`, `conflict` or `not-applicable`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-stamp.md`
