---
load: contract
---
# Merge to production on the person's yes

`hotfix-steps`' `hotfix-merge@1` step, after the review settled.

**No PR here** before the fix — a new branch has nothing ahead of production. When the fix is ready
open it to the production branch with **`/devstride:pr`** for the draft-first, review-before-CI
treatment (a review-fix push on a non-draft PR restarts CI). By hand: `gh pr create --base
<hotfixBaseBranch>` with `--draft` iff the repo holds CI on drafts (`review.openPullRequestsAsDraft`,
default true), never `--fill`.

Merging: run `python3 ${CLAUDE_PLUGIN_ROOT}/skills/pr/scripts/merge-gate.py <pr> <head> --all-green` and act only on
its `MERGE` line (`MERGE <cmd> | REFUSE <reason> | ERROR <reason>`; a hotfix is never held by its
migration or train rules), and only when the payload's `answer` carries the person's explicit yes to
merging THIS pull request at THIS head; otherwise `WAITING FOR YES`. `REFUSE` → `REFUSED`; `ERROR` →
`ERROR`. The merge guard recognises the hotfix by its branch name (the hotfix pattern, default
`*/hotfix/**`) and lets it through.

## Verdict

`HOTFIX MERGE: MERGED <sha> | WAITING FOR YES | REFUSED <reason> | ERROR <reason>`

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/hotfix-steps/SKILL.md`
