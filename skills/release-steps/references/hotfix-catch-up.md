---
load: contract
---
# Catch up with a hotfix — production merged into the release branch, never a rebase

`release-steps`' `hotfix-catch-up@1` step, run before the recap and the yes. The rule is
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-branch.md` §4 "A hotfix lands while the
release is open", cited, not copied.

1. **Config wins.** Load `.claude/ds-config.json`: `release.productionBranch`,
   `release.releaseBranchPattern`, `release.clearance`. No release branch pattern → `NONE`: there
   is no release branch to bring production into.
2. **Which release, and its shape**
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`): the payload's `shape`
   pull request and branch when `ADOPTED`; when `NEW`, this run's own open release pull request
   and its head branch. `MERGED` → `NONE`.
3. `git fetch origin <productionBranch> <release branch>`. With `release.clearance` set, the
   provider's `status` names each hotfix landed since the claim (`Hotfix landed: #<n>`). The
   production branch is an ancestor of the release branch → `NONE`.
4. **Otherwise bring it in.** On a non-draft pull request run `gh pr ready --undo` BEFORE the
   push, so CI never runs on an unreviewed head. Then `git switch <release branch> && git merge
   --no-ff origin/<productionBranch>` and push. Never rebase, never force-push. A conflict → no
   verdict line: abort the merge, push nothing, name the files and stop.
5. **The merge left the tree unchanged** (history only: `git rev-parse <old>^{tree}` equals
   `<new>^{tree}`) → `SAME TREE <sha>`. No review is needed: say so, the new head stands in for
   `<reviewedHead>`, and invoke `review` in PRE-SHIP RESUME mode so it marks the pull request ready
   and settles CI there with no review cycle.
6. **The tree changed** → `MERGED <pr>`, naming the hotfix pull request (the production commit
   when it has none). The runner sends the run back to the review because the review must run
   again: `review` driven as a contextual follow-up over the merge's range, carrying the ledger,
   the counters and the same pre-ship hold declaration, never a fresh cycle 1; then the pre-ship
   checks, the discharge and this step once more, which finds production already in (`NONE`).
   Any owner yes already given is void, and the go-ahead asks again.

## Verdict

`HOTFIX CATCH-UP: NONE | MERGED <pr> | SAME TREE <sha>`

## Result

`state`: `none`, `merged` or `same-tree`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
