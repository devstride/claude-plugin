---
load: contract
---
# The go-ahead, the production merge and the deploy (steps 4 and 5a)

The `release` body keeps the order of steps 4 and 5a, their verdict lines and the hard floors; this
file holds what the recap carries, what is confirmed on the yes, and how the merge and the deploy
are confirmed. Read it in full before step 4, or before 5a when step 4 did not run.

## Step 4 — the human recap

Lead with `READY` or `BLOCKED`, then every included change in plain English, where it deploys, and
what "yes" versus "no" does. Then:

- the PR (green + settled), the review tally, the delta and 2b's release class;
- the pre-merge verdict;
- **each 2b result (or its waiver)** — each pre-ship entry reported as passed at the train on
  <sha>, at 2b, skipped by path, or waived, never "covered by CI";
- the documentation plan (the steps 5c will call / "none registered" / "suppressed");
- the release-notes decision (default: none written);
- the consequence notices
  (`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/consequence-notices.md`);
- what merging triggers, quoted from `release.autoDeployOnMerge`;
- **the deploy stage**: `stage.resolve` set → quote "this merge deploys to `<stage>`" beside
  `autoDeployOnMerge`; no `stage` block or empty result → nothing, never a guess (nor
  `localEnvironment.instanceName`);
- with `release.clearance` set, the provider's `status`
  (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/clearance.md`, "Where the release skill calls
  it");
- with `release.devDeployVerification` set and a delta touching a fix-exclusion path, the dev
  deploy wait (run after the yes — a standing yes: before it — and before the checks below, per
  `${CLAUDE_PLUGIN_ROOT}/skills/release/references/docs-hooks.md`).

## Step 4 — on the yes

In this order, after the yes and before the merge:

1. **Scope `cut-to-deploy`**: the previous-release gate again
   (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/clearance.md`, § Scope `cut-to-deploy`).
2. **The dev deploy wait**, when it applies (a standing yes ran it before the decision instead).

Then confirm:

1. The head equals `<reviewedHead>` (the only tolerated advance is `review` 7.3's same-tree empty
   re-trigger commit; anything else → back to step 2).
2. The PR is non-draft (a draft-hold PR still draft never ran CI) and green at that head (the
   merge gate proves both).
3. Every 2b check passed or was waived.
4. The paginated **zero-unresolved-threads** check still reads zero (a late comment is replied-to
   AND resolved via `review` step 6 first, never merged over).
5. With `release.clearance` set, this pull request is the one `On final` in the provider's
   `status`, else STOP.

Then run the `MERGE` line of `merge-gate.py <n> <reviewedHead> --all-green` (step 4); else STOP.

## Step 5a — the merge and the deploy

- **Merge**: the PR reads `MERGED`; the merge commit and timestamp go into the payload; `live`
  stays `false` until the deploy is confirmed, then `true`.
- **Approve**: `release.deployApproval` set (an adopted merged release too) → the owner's yes
  approves the deploy: run it with `RELEASE_COMMIT=<merge sha>`; 0 = approved and read back, 2 =
  retry (bounded), else STOP; never send the owner to approve.
- **Deploy**: `release.deployVerification` set → run it with `RELEASE_COMMIT=<merge sha>`; exit 0
  confirms; non-zero → retry on an interval suited to the deploy; still failing → report it
  unconfirmed and STOP (no 5c–5e). Unset → ask the owner to confirm (a legitimate pause). Nothing
  in 5c–5e would run and no `release.postDeployCheckSkill` → skip the confirmation, said so.

## Cited by

- `skills/release/SKILL.md` — step 4's pointer ("Read … in full before step 4"), and step 5a's
  ("read it first when step 4 did not run this session").
