---
load: contract
---
# Approve the production deploy on the person's yes

`hotfix-steps`' `deploy-approval@1` step, shared by every workflow that merges to production. Its
procedure is `${CLAUDE_PLUGIN_ROOT}/skills/release/references/merge-and-deploy.md` section "Step 5a", cited, not copied.

- `release.deployApproval` null or absent → `NOT CONFIGURED`.
- Only when the payload's `answer` carries the person's yes for THIS deploy (the merge SHA in
  `mergeSha`), run the command with `RELEASE_COMMIT=<mergeSha>` in the environment: exit 0 is
  approved and read back (`APPROVED`); exit 2 is "the deploy is not waiting yet": re-run it every 30
  seconds for at most 10 minutes, then `RETRY` (the runner re-issues the step as its next attempt;
  on its third attempt the step answers `STOPPED deploy not waiting` instead, so the wait is
  bounded); any other exit → `STOPPED <why>`, its output summarised, never pasted.
- No yes, or a yes for a different SHA → `WAITING FOR YES`. A yes is never carried over to a newer
  merge.

## Verdict

`DEPLOY APPROVAL: APPROVED | WAITING FOR YES | RETRY | NOT CONFIGURED | STOPPED <why>`

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/hotfix-steps/SKILL.md`
