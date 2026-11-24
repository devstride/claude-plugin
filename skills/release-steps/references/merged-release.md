---
load: contract
---
# Find the merged release — the start of a post-deploy, docs or notes run

`release-steps`' `merged-release@1` step, the first step of the three partial entries (post-deploy
only, docs only, release-notes only). It reads only: it claims nothing, opens no pull request and
merges nothing, and any session may run it.

1. **Config wins.** Load `.claude/ds-config.json`: `release.productionBranch` (shipped default
   `master`), `release.releaseSource` (`develop`), `release.releaseBranchPattern`.
2. `git fetch origin <productionBranch>`. Find the newest merged pull request into the production
   branch whose head is a release branch: a name matching `release.releaseBranchPattern`,
   anchored as `${CLAUDE_PLUGIN_ROOT}/skills/release/references/branch-patterns.md` says and never
   by substring; with no pattern, a head that is the release source. A hotfix head never counts.
   None → `NONE`.
3. **Take its merge commit and recompute the delta** over the range that merge brought
   (`<merge>^1..<merge>`), then build the `production-release` payload of
   `${CLAUDE_PLUGIN_ROOT}/skills/release/references/docs-hooks.md` "The delta payload" with that
   merge commit, its merge time and `live: true`. The deploy confirmation still runs next, and
   nothing is published before it.
4. `FOUND <pr>`, naming the pull request, its merge commit and when it merged.

## Verdict

`MERGED RELEASE: FOUND <pr> | NONE`

## Result

`sha`: the merge commit; `pullRequest`: its number. Both absent on `NONE`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
