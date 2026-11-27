---
load: contract
---
# The release train — where one-offs go when one is configured

**Goal:** one-off items (outside a sequenced plan, even under an Epic) batch on one long-lived branch that ships with
every release, instead of each merging straight into `baseBranch` and paying its own CI and
deploy.

`releaseTrain` below means `releaseTrain`, or `supportTrain` when only that is present; both present
is a config error — STOP and name it.

`releaseTrain.branch` absent → none of this runs: a one-off's working base is `baseBranch` and it
takes the full per-story PR ritual, as before. `releaseTrain.fastMerges` absent or `false` → a
one-off on the train still takes the full per-story PR ritual (the review moment `pr-boundary`),
with the train as the pull request's base.

## Routing (step 0)

- **A train that never ships strands its one-offs.** With `release.mergeTrainBeforeCut` not `true`,
  nothing ever merges the train into `baseBranch`, so route the one-off to `baseBranch` instead and
  announce why ("release train set, but releases do not merge it").
- **One-off AND `releaseTrain.branch` set (and the train ships) → the working base is the train.**
  Resolve it with `git ls-remote --heads origin`: present → reuse; absent → create it from a freshly
  fetched `origin/<baseBranch>` without checking it out (`git push origin
  origin/<baseBranch>:refs/heads/<train>`). Announce "release train <name>: reused" or "created".
- **A renamed train is never created beside the old one.** Configured train absent and exactly one
  other `train/*` branch on origin → that branch IS the train until the rename is cut over: the
  one-off rides it (nothing created), and the announcement names the cutover and its commands, as
  `routing.py`'s reason gives them, for the owner to run. Several other `train/*` branches → ask
  which one is live. An epic's release to the train resolves it the same way.
- **One-offs touching deploy configuration or migrations never ride the train; a reviewed release unit may.** A one-off whose change touches a
  path matching an entry of `release.releaseBranchFixExclusions` (absent → nothing is excluded;
  matching per `${CLAUDE_PLUGIN_ROOT}/skills/release/references/branch-patterns.md`) ships to
  `baseBranch` by the full pull-request ritual instead, announced with the matching paths. Decide it
  at step 0 from the validated spec, and check it again on the real diff (`git diff --name-only
  --no-renames origin/<train>...HEAD`) immediately before anything merges onto the train — the fast
  merge, or the train pull request's merge, both `merge-story`'s — since a review fix can add such a
  path. A story branch that turns out to touch one is moved with `git rebase --onto
  origin/<baseBranch> origin/<train>` (a disposable story branch; this drops the other one-offs the
  train carries), its verification receipt is void (rerun the local gate on the new tree), and it
  continues by the pull-request path into `baseBranch` as a `pr-boundary` review (the loop starts
  its run again: `skills/build-item/SKILL.md`, The run). A reviewed release unit (an epic's pull request, merged onto the train through its own
  review) may carry migrations and infrastructure on the train: `release` checks only work no pull
  request reviewed, and, when `release.devDeployVerification` is set, waits for the development
  deploy before merging production.

`python3 ${CLAUDE_PLUGIN_ROOT}/skills/build-item/scripts/routing.py` implements this routing: `target`
(with `changedFiles` for the exclusion rule) at step 0, `excluded` for the check before a merge.

## Delivery path

- **`releaseTrain.fastMerges` true → fast mode exactly as for an epic branch, with the train in its
  place** (review moment `release-deferred`): the completed risk check, a green local gate, the
  review the fix's size calls for, a `--no-ff` merge onto the train, the push, then the story branch
  deleted. Which review each landing gets (a small fix's skip, LOCAL-FULL for a larger or riskier
  fix, every landing reviewed) and the landing gate are `review-story`'s:
  `${CLAUDE_PLUGIN_ROOT}/skills/review-story/references/review-routes.md`, "The train's landing
  review". The merge and its subject are `merge-story`'s
  (`${CLAUDE_PLUGIN_ROOT}/skills/merge-story/references/merge-paths.md`).
- **Otherwise → the pull-request path with the train as the base** (review moment `pr-boundary`).

## Settings

- `releaseTrain.smallFixes` — `{maxFiles, maxChangedLines}`, both required, each at least 1; lines
  are added plus removed. Absent → no fix counts as small. The high-risk list is
  `release.productionReview.highRiskPaths` plus `release.releaseBranchFixExclusions`.
- `releaseTrain.reviewEveryLanding` — boolean, absent `false`. `true`: every train one-off lands
  with its own review receipt, and `smallFixes` only sizes that review.
- `releaseTrain.lateArrivals` — `"restart"` or `"offer"` (absent: `"offer"`); what `release` does
  with a one-off that lands while the train's review is running
  (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-branch.md`, Late landings).

## After a one-off lands on the train

- Its completion (status, comment, dates: NOT Done yet) is `story-lifecycle`'s complete step
  (`${CLAUDE_PLUGIN_ROOT}/skills/story-lifecycle/references/complete.md`).
- Step 7 terminates as for any one-off; the recap says it is on the release train and becomes Done
  when the next release ships it.
- **Last, after step 7's recap and clean-up:** `release.autoStart.enabled` → its trigger
  (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/auto-start.md`), so nothing of this item's
  close-out waits on, or is overtaken by, the release it may start. The checkout lease is KEPT through it: `return-checkout` waits until the trigger answers SKIP or ERROR, loses the claim, or the release it starts stops, and that release runs in this same leased checkout.

## Why

Every merge into the base branch runs paid CI and, in many repositories, a deploy. One-offs that
batch on the train get one full review and one CI pass at release time — the same reasoning as an
epic release pull request — and the train ships with every release, so nothing waits longer than
the next cut. Deploy configuration and migrations are excluded because the train reaches
production at the next release with little time in between; they deserve their own pull request,
CI and an earlier deploy to a development stage.

## Cited by

- `skills/build-item/SKILL.md` — the working-base precedence, one-off mode and The run.
- `skills/review-story/references/review-routes.md` — the train's landing review.
- `skills/merge-story/references/merge-paths.md` — the exclusion check before a train merge.
- `skills/story-lifecycle/references/complete.md` — a train landing's completion.
