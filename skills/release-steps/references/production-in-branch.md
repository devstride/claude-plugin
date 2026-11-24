---
load: contract
---
# Bring production into the release branch — prepared on top of what is ahead

`release-steps`' `production-in-branch@1` step: in the cut under scope `merge-and-deploy`, right
after the cut and before the pull request opens, and again whenever the checks find production has
moved. The merge is `${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-branch.md` §4, cited,
not copied; why the release is prepared on top of the release ahead is
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/clearance.md` "Scope `merge-and-deploy`".

1. **Config wins.** Load `.claude/ds-config.json`. No `release.releaseBranchPattern` →
   `NOT APPLICABLE` (no release branch to bring production into). The payload's `shape` is
   `MERGED` → `NOT APPLICABLE`. `ADOPTED` still runs
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`).
2. **The branch**: this run's release branch (`cut-branch`'s recorded verdict, or the shape's
   `branch`). `git fetch origin <productionBranch> <branch>`.
3. **Look**: `python3 ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/release_checks.py contains
   --head <origin/<branch> sha>`.
   - Exit `0` (`CONTAINS master <m>`) → `CONTAINS`: nothing to bring in.
   - Exit `3` (`BEHIND master <m>`: the release ahead merged, or a hotfix landed, and the source
     does not hold it yet) → step 4.
   - Exit `1` → no verdict line, naming the error: the runner stops, never `CONTAINS`.
4. **Merge production in**, never a rebase: `git switch <branch> && git merge --no-ff
   origin/<productionBranch>`. A conflict → `git merge --abort` and `CONFLICT <files>`: never
   resolved here. The merge of the production branch is exempt from the fix-exclusion check
   (`release-branch.md` §3).
   - **The pull request is not open yet** (right after the cut): push the branch. There is no
     review to re-enter; the first review reads it with everything else.
   - **It is open**: when it is no longer a draft, `gh pr ready --undo` BEFORE the push, so CI never
     runs on an unreviewed head; then push. The review follows up over the merge's range as
     `release-branch.md` §4 says (a tree left unchanged needs no review cycle).
   - Never force-push. Answer `MERGED <sha>`, the merge commit.

## Verdict

`PRODUCTION IN BRANCH: CONTAINS | MERGED <sha> | CONFLICT <files> | NOT APPLICABLE`

## Result

`state`: `contains`, `merged`, `conflict` or `not-applicable`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-stamp.md` — the round after
  `CHANGED`
