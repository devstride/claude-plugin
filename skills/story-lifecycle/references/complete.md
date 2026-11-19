---
load: contract
---
# Complete — record on the item what landed, where and when

`story-lifecycle`'s `complete@1` step, run once the merge step answered `LANDED`. Every part
skips what is already done, so a re-run after a stop finishes only what is missing; a `FAILED`
stops the run.

1. **Status and comment.** `item-status.py decide`, `event: landed`, sets status and comment (never
   `mark_done`) through `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/item-status.md` steps 1
   to 3. The `target` is `{kind, branch, sha, pullRequest?, releaseUnit?, releaseTarget?}`: `kind`
   exactly as item-status.md step 2 defines it (`routing.py target`'s kind for the working base),
   `branch` the merge's `target`, `sha` its `sha`, `releaseUnit` the payload's.
   - A base landing is **Done** (`COMPLETE: DONE`); the plan's **Closing** that may follow is the
     loop's.
   - An epic-branch landing is LANDED (`COMPLETE: LANDED`;
     `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/next-unblocked.md`, Landed leaves), closed
     when its release unit's release reaches its target.
   - A one-off on the release train is **NOT Done yet** (`COMPLETE: LANDED`): `target.kind: train`
     gives the merged status and the comment "merged to the release train <name> (<pull request
     link, or merge SHA>); ships with the next release". `release` marks it Done when the train's
     pull request reaches `baseBranch`.
   - Exit 2 or 1 → move nothing, post nothing, `COMPLETE: FAILED` with its `item-status:` line.
2. **Dates, only with the auto-scheduler OFF.** Apply
   `${CLAUDE_PLUGIN_ROOT}/skills/rationalize-gantt/references/auto-scheduler-off.md` before the date
   write. `startDate`/`dueDate` = branch creation → merge; a train landing sets `startDate` and no
   `dueDate`.
3. **Quote.** A train or base landing is then quoted once the merge is pushed (item-status.md
   step 4: `${CLAUDE_PLUGIN_ROOT}/skills/release/references/estimates.md`, Quoting at landing).
4. **The item points at its code**: pull-request path: confirm the pull request auto-linked, else
   `link_pull_request` with the review's `pullRequest`. Fast path: the landed comment, which names
   the merge SHA. Never invent a PR number: one the merge or review result does not carry does not
   exist.
5. **Reconcile as-built** on a material deviation (the `deviations` of the build, the risk check
   and the review, all three read): read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/as-built.md` in full before
   acting on it. None → report "shipped as specified" and write nothing. The dismissed-findings
   list never goes here: it lives in the pull request or merge-commit body.
6. **Release the claim** (`claims` set): `release_claim` with outcome `done`
   (`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/story-claims.md`, Completion), and the
   ship-intent declaration with outcome `landed`
   (`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/ship-intent.md`). Not configured, off or
   degraded → `claimReleased` / `shipIntentReleased` false, said once; never a failure.
7. **Report** item + `[N]`, status, dates, PR link or SHA + branch, profile + source, reconciled
   (the profile is the payload's `profile`, its source the payload's `profileSource`).

## Cited by

- `skills/story-lifecycle/SKILL.md` — the `complete@1` dispatch ("Read … in full before acting on
  the completion").
- `skills/build-item/SKILL.md` — the dates floor ("the completion step's date write").
