---
load: contract
---
# Resume, adoption and heartbeats — the rules every release step shares

Read once per run by `release-steps`. Each mode's reference cites a line here instead of
restating it. The clearance contract itself is
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/clearance.md`, cited, not copied.

## What the payload carries

- **`shape`** — the result of `release-shape@1`: `{ shape, pullRequest, branch }`, `shape` being
  `NEW`, `ADOPTED` or `MERGED`. Null means the step runs before the shape is read (the train
  claim, and the tower claim under scope `release`): it does its own work and no shape rule applies.
- **`tower`** — the result of `tower-claim@1`: `{ state, adopted }`. `adopted: true` means the
  owner said yes to adopting a stale or stuck release at the tower claim, so every later step takes
  the adopted path: the branch and pull request are the ones the provider's local record names
  (`clearance.md` "The local record"); an open pull request reads as `ADOPTED`, a merged one as
  `MERGED`, whatever `shape` said before the claim.
- A step never works the shape out again from memory or from the conversation. Only
  `release-shape` reads it, and it is safe to re-run.

## What each shape skips

- **`NEW`** — every step runs.
- **`ADOPTED`** — an open release pull request, this session's own or one adopted on the owner's
  yes. The train is not merged again and nothing is cut: every train mode answers
  `NOT APPLICABLE`, `release-branch` and `release-pr` answer `ADOPTED`, and `release-review`
  reviews the open pull request. `production-in-branch` still runs (scope `merge-and-deploy`),
  and so does the train levelling at close-out (the step `train-level-final`), under every shape.
  The train modes:
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/train-finish.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/ship-plan.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/train-snapshot.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/train-pr.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/train-review.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/train-merge.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/train-close-out.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/train-level.md`, and the train's pre-ship
  step (`${CLAUDE_PLUGIN_ROOT}/skills/pre-ship/SKILL.md`, handed the shape)
- **`MERGED`** — a release that merged but was never closed out. Nothing is cut, reviewed or
  merged again: the run carries on at the pending status (scope `merge-and-deploy`), the deploy
  approval and the deploy confirmation, then the close-out, and an adopted merged release is
  approved too. Every train mode above and every mode below answers `NOT APPLICABLE` where its
  verdict has that value; one that has none changes nothing and answers the value its own
  reference gives for a release already merged:
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-delta.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/tower-queue.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-branch.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/production-in-branch.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-pr.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/train-claim-hand-on.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-tip.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/dev-deploy-wait.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-stamp.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-stamp-verify.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-review.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/pre-ship-resume.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-docs-plan.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/hotfix-catch-up.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/previous-release.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/owner-go-ahead.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/owner-go-ahead-recheck.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/merge-confirmations.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/production-merge.md`, and the three
  steps other skills serve, each handed the shape: the pre-ship checks (all four places,
  `${CLAUDE_PLUGIN_ROOT}/skills/pre-ship/SKILL.md`), the pre-merge check
  (`${CLAUDE_PLUGIN_ROOT}/skills/pre-merge-check/SKILL.md`) and the release class
  (`${CLAUDE_PLUGIN_ROOT}/skills/classify-release/SKILL.md`), which answer `NOT APPLICABLE`
  without running anything.
- **Always run**, whatever the shape (each settles only what is still owed):
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/train-claim.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/tower-claim.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/ground-truth.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-shape.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/ci-hold-proof.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/merged-release.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/post-deploy-pending.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/estimates-score.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/tower-hand-back.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/post-deploy-result.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-sync.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-branch-delete.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-docs.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-kb-sync.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-close-out.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-notes.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-recap.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/auto-start.md`

## Whose release it is

A release pull request whose holder marker names another session (scope `merge-and-deploy`, the
only one that writes it) is never adopted silently, even with the tower clear: stop, name it, and adopt only on the owner's yes (`clearance.md`; with a
`claims` block the train claim decides which markers are adoptable,
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/auto-start.md`). The same holds for a train pull
request. A stopped release is adopted, never resumed or messaged so that a second copy starts.

## Heartbeats

Two different things are heartbeated, and a step sends both itself.

- **The tower** (`heartbeat <phase>` through the clearance provider). The step that opens a
  phase sends it at its first mutation, and ONLY when this session's local clearance record shows
  it holds the tower. No record means nothing is held (scope `merge-and-deploy` before the final
  claim) and nothing is sent, so a heartbeat with nothing to prove never provokes an exit 4. Exit 4
  anywhere is a stop: another session owns this release now. Phases come only from this map:
  `train` in `train-finish` (scope `release`); `cut --branch <b>` in `release-branch` (`release`,
  `cut-to-deploy`); `pr --pr <n>` after `release-pr` opens it (`release`, `cut-to-deploy`); `review`
  in `release-review`; `pre-ship` in the release's pre-ship step; `final` in `owner-go-ahead`, and
  right after the final claim under `merge-and-deploy`; `merging` after `merge-confirmations`;
  `deploy` after `production-merge` merges; `close-out` in `release-sync` (`release`, `cut-to-deploy`).
- **The train claim** (kind `release-train`, `auto-start.md`). The loop that runs the workflow
  heartbeats it at every step transition while the run holds it, with the phase the runner
  returns. A step heartbeats it itself through every wait — the queue, the ship plan, the tower
  claim, review, CI, the train's pre-ship suites — at least every `min(10, expiry ÷ 3)` minutes.
  After a wait for a person, heartbeat it before anything else. `NOT HOLDER` or `LOST`: with the
  tower held, carry on under the tower; otherwise stop before merging. A heartbeat that degrades
  proves nothing: stop.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- every reference of `release-steps` that has a shape or heartbeat rule
