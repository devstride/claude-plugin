---
load: contract
---
# The go-ahead, the production merge and the deploy (the `go-ahead` and `deploy` phases)

The Release definitions keep the order of these steps; this file holds what the recap carries,
what is confirmed on the yes, and how the merge and the deploy are confirmed. Read it in full
before `go-ahead`, or before `approve-deploy` when `go-ahead` did not run.

## `go-ahead` — the human recap

Lead with `READY` or `BLOCKED`, then every included change in plain English, where it deploys, and
what "yes" versus "no" does. Then:

- the PR (green + settled), the review tally, the delta and `classify-at-pre-ship`'s release class;
- the pre-merge verdict;
- **each `pre-ship-release` result (or its waiver)** — each pre-ship entry reported as passed at the
  train on <sha>, at `pre-ship-release`, skipped by path, or waived, never "covered by CI";
- the documentation plan (the hooks `update-docs` will call / "none registered" / "suppressed");
- the release-notes decision (default: none written);
- the consequence notices
  (`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/consequence-notices.md`);
- what merging triggers, quoted from `release.autoDeployOnMerge`;
- **the deploy stage**: `stage.resolve` set → quote "this merge deploys to `<stage>`" beside
  `autoDeployOnMerge`; no `stage` block or empty result → nothing, never a guess (nor
  `localEnvironment.instanceName`);
- with `release.clearance` set, the provider's `status`
  (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/clearance.md`, "Where the release skill calls
  it"); under scope `merge-and-deploy` also the check stamp (the tree, the production tip and when
  the `checks` phase ran), the release it was prepared on top of (the production tip in the stamp) and
  whether it waits outside the tower;
- with `release.devDeployVerification` set and a delta touching a fix-exclusion path, the dev
  deploy wait (run after the yes — a standing yes: before it — and before the checks below, per
  `${CLAUDE_PLUGIN_ROOT}/skills/release/references/docs-hooks.md`).

## `go-ahead` — on the yes

In this order, after the yes and before the merge:

1. **Scope `cut-to-deploy`**: the previous-release gate again
   (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/clearance.md`, § Scope `cut-to-deploy`).
   **Scope `merge-and-deploy`** instead: the queue and the claim, this release's first
   (`--branch --pr`; BUSY while the release ahead still merges or deploys), then `heartbeat
   final`, the previous-release gate once more (one read; pending steps aside again, a failure
   STOPs, and no yes lifts either), the stamp verify (`CHANGED` or `BEHIND`: rebuilt on what is
   now ahead, back to `release-review`), the pre-merge check, every `rerunAtMerge` entry and the standing
   yes again, in that order (§ Scope `merge-and-deploy`); the `checks` phase already ran the dev deploy wait.
2. **The dev deploy wait**, when it applies (a standing yes ran it before the decision instead).

Then confirm:

1. The head equals `<reviewedHead>` (the only tolerated advance is `review` 7.3's same-tree empty
   re-trigger commit; anything else → back to `release-review`).
2. The PR is non-draft (a draft-hold PR still draft never ran CI) and green at that head (the
   merge gate proves both).
3. Every `pre-ship-release` check passed or was waived.
4. The paginated **zero-unresolved-threads** check still reads zero (a late comment is replied-to
   AND resolved via `review` step 6 first, never merged over).
5. With `release.clearance` set, this pull request is the one `On final` in the provider's
   `status`, else STOP.

Then `production-merge` runs the `MERGE` line of `merge-gate.py <n> <reviewedHead> --all-green`; else STOP.

## `production-merge` to `confirm-deploy` — the merge and the deploy

- **Merge**: the PR reads `MERGED`; the merge commit and timestamp go into the payload; `live`
  stays `false` until the deploy is confirmed, then `true`. Scope `merge-and-deploy`: post the
  `pending` post-deploy status on the merge commit at once, and hand the tower back as soon as the
  deploy is confirmed (`clearance.md`).
- **Approve**: `release.deployApproval` set (an adopted merged release too) → the owner's yes
  approves the deploy: run it with `RELEASE_COMMIT=<merge sha>`; 0 = approved and read back, 2 =
  retry (bounded), else STOP; never send the owner to approve.
- **Deploy**: `release.deployVerification` set → run it with `RELEASE_COMMIT=<merge sha>`; exit 0
  confirms; non-zero → retry on an interval suited to the deploy; still failing → report it
  unconfirmed and STOP (no `update-docs` to `write-release-notes`). Unset → ask the owner to confirm
  (a legitimate pause). Nothing from `update-docs` to `write-release-notes` would run and no `release.postDeployCheckSkill` → skip the confirmation, said so.
- **Score the estimates** (`score-estimates`): deploy confirmed, or its confirmation skipped → score every quote the
  shipped items carry and post each score
  (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/estimates.md`, Scoring at the release); it never
  blocks or delays the release.

## Cited by

- `skills/release-steps/references/owner-go-ahead.md`, `merge-confirmations.md`,
  `production-merge.md`, `dev-deploy-wait.md` and `release-recap.md`;
  `skills/hotfix-steps/references/deploy-approval.md`.
- `skills/release/references/estimates.md` — the score after the production merge.
