---
load: contract
---
# Approve the production deploy on the person's yes

`hotfix-steps`' `deploy-approval@1` step, shared by every workflow that merges to production. Its
procedure is `${CLAUDE_PLUGIN_ROOT}/skills/release/references/merge-and-deploy.md` section "`production-merge` to `confirm-deploy`", cited, not copied.

- `release.deployApproval` null or absent → `NOT CONFIGURED`.
- Only when the payload's `answer` carries the person's yes for THIS deploy (the merge SHA in
  `mergeSha`), run the command with `RELEASE_COMMIT=<mergeSha>` in the environment: exit 0 is
  approved and read back (`APPROVED`); exit 2 is "the deploy is not waiting yet": re-run it every 30
  seconds for at most 10 minutes, then `RETRY` (the runner re-issues the step as its next attempt
  and stops it at its 50th, `attempts-exhausted`); any other exit → `STOPPED <why>`, its output
  summarised, never pasted.
- **In a release, the release's yes is this yes** (the owner's or the standing yes approves the
  merge and its deploy alike): when the runner's `status` for this run (`evidence` `true`, and
  `runId` the run that issued this step, from its `run` answer: two release runs may be open at
  once) shows a
  `GO-AHEAD: YES` verdict before the merge that made `mergeSha`, run the command as above.
- No yes, or a yes for a different SHA → `WAITING FOR YES`. A yes is never carried over to a newer
  merge.

## Verdict

`DEPLOY APPROVAL: APPROVED | WAITING FOR YES | RETRY | NOT CONFIGURED | STOPPED <why>`

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/hotfix-steps/SKILL.md`
