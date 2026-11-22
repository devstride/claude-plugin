---
load: contract
---
# Close out the hotfix

`hotfix-steps`' `hotfix-close@1` step. A recap and a read-only note: once it merges, an open release
branch (`release.releaseBranchPattern`) must take it too: `release` merges the production branch
into that branch and re-reviews it — never a rebase. Read `gh pr list --base <hotfixBaseBranch>
--state open` and match each head with `python3 ${CLAUDE_PLUGIN_ROOT}/skills/build-item/scripts/routing.py match`
(never by substring): one matches → `OPEN RELEASE <branch>`, said in plain words; none →
`CLOSED <sha>`. The merge-in and re-review are the release's job; this step does none of it.

## Verdict

`HOTFIX CLOSED: CLOSED <sha> | OPEN RELEASE <branch>`

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/hotfix-steps/SKILL.md`
