---
load: contract
---
# Delete the release branch — the one place a protected branch is deleted

`release-steps`' `release-branch-delete@1` step (the step `delete-release-branch`), right after
the sync. The rule is `${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-branch.md` §5 step
2, and the name match is `${CLAUDE_PLUGIN_ROOT}/skills/release/references/branch-patterns.md`,
both cited, not copied. This step says, every time, that it is deleting a protected branch.

1. **Config wins.** Load `.claude/ds-config.json`: `release.releaseBranchPattern`,
   `release.productionBranch`, `release.releaseSource`. No pattern set → `NOT APPLICABLE`: the
   release pull request was headed by the source, and there is no release branch.
2. **The branch**: the head of this run's release pull request, from this run's recorded results
   (the runner's `status`, never memory: `production-merge`'s or `merged-release`'s pull request,
   or the payload's `shape` when it carries a `branch`,
   `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`). Already gone from
   origin (a re-run, or deleted by hand) → `DELETED <branch>`, said so.
3. **Both checks**, after `git fetch origin <productionBranch> <releaseSource>`:
   - the name matches the pattern by `branch-patterns.md`'s anchored rule, never by substring;
   - `git merge-base --is-ancestor origin/<name> origin/<productionBranch>` AND `git merge-base
     --is-ancestor origin/<name> origin/<releaseSource>`.
   Either fails → `KEPT <why>`, naming which: a sync that did not finish leaves the source
   without the branch's fixes. The run continues; the recap names the branch left behind.
4. **Never** the release source, the production branch, or any name the pattern does not match,
   whatever a payload says.
5. **Delete**: `git push origin --delete <name>`, then `git branch -D <name>` when a local copy
   exists → `DELETED <branch>`. A push the server refuses → `KEPT`, quoting it.

## Verdict

`RELEASE BRANCH DELETE: DELETED <branch> | KEPT <why> | NOT APPLICABLE`

## Result

`state`: `deleted`, `kept` or `not-applicable`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
