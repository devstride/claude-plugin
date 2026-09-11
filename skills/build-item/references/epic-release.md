---
load: rationale
---
# The epic release, and the one-off bypass — why they are shaped this way

The rules live in the body (step 8, and the one-off mode section); this file holds the
reasoning, read before cutting a release PR or changing the one-off classification.

## Why the epic release PR reviews the FULL diff under fast mode

Fast-mode stories were settled entirely locally — local engines, local suites, no PR — so the
epic release PR is the FIRST pass by the cloud roster or CI over ANY of that code. The stories
were locally reviewed, so expect fewer findings than a cold diff would draw, but the cloud gate
has genuinely not run yet, and treating the release as a re-review would let an entire epic
reach develop having never been cloud-reviewed. That is the one way fast mode could actually
cost quality, and the full-diff scope at step 8 is where it is prevented — nowhere else. When
the stories took the full 4b ritual instead, each was already cloud-reviewed at its own PR, so
the release review points at what per-story review could not see: the cross-story integration
surface and the develop-merge conflict resolutions.

## Why stories merge into the integration branch, and why `--no-ff`

A story that merged straight to the base branch would put half a release unit on the shared dev
stage; batching onto the release unit's integration branch leaves that stage untouched until the
unit is complete and reviewed as one PR. Each story goes in with `--no-ff` because the merge
commit is the legible first-parent unit the release PR body and the close-out counts are read
off — a fast-forward would dissolve the batch into indistinguishable commits.

## Why the story branch is deleted only after the epic push succeeds

A rejected push of the integration branch means the story's merge exists only locally. Deleting
the remote story branch at that moment destroys the sole remote copy of the work, so the deletion
waits on a push that actually succeeded — local and remote together, never the remote first.

## Why deferred defects live beside the plan, not inside its chain

An out-of-scope or below-floor finding that lives only in a PR body is invisible to every later
selection, so it has to become a tracked item. But WHERE it is tracked decides whether it is also
execution order. A below-floor defect spliced into the dependency chain with `blocked_by` edges is
work the loop must build before the plan can reach zero: the plan never finishes, and the finding
that was explicitly deferred is not deferred at all. Under a light profile, where the fix floor
defers most of what review confirms, that turns one plan into an open-ended queue of defects
nobody chose to schedule.

So deferred defects go into a container of their own directly under the plan root, related to the
item whose review produced them and blocked by nothing. The container is deliberately NOT a
release unit: a parking lot that later reached zero remaining leaves would trip the auto-release
decision and cut a release PR for work that was parked, not planned. Items in it are tracked,
visible and re-schedulable by a human — which is what deferring is supposed to mean — and an
explicitly named one can still be built as a one-off.

## Why docs stage rather than publish

An epic that merges has reached the base branch, not production, and public documentation must
never describe functionality ahead of the product — so the epic-release docs payload carries
`live: false` and the docs skill stages the edits; the production release (`live: true`) is
what publishes them. Release notes never happen here under any setting: they are the production
release's business, and only on the owner's explicit `--release-notes`.

## Why the release PR is linked back onto every leaf

A fast-mode story has no PR, so its completion ritual cites its merge SHA and integration
branch and promises that the release PR link follows at step 8. Step 8's link-back is where
that promise is kept; skipping it leaves every fast-mode story in the batch pointing at a link
that never arrives, and an item with no pointer to its shipped code fails the ritual's whole
purpose.

## Why auto-release honours a present config key over the profile

`epicIntegrationBranches.autoRelease` in the file is the operator's decision; the profile
supplies a value only when the key is absent. A config flag the loop ignores is worse than no
flag — the operator believes they disabled auto-release while the loop merges to develop anyway
— so a present key wins whatever the profile says, and the contradiction is reported aloud.

## Why a one-off under an Epic parent still bypasses the epic branch

`create-story` and `create-defect` both offer a release-unit item as a parent, so a one-off
CAN have a release-unit ancestor — and without the explicit bypass, the general derivation
rule would route it onto that epic's integration branch and strand it there until an unrelated
epic releases. A one-off ships straight to develop, and because nothing comes after it, its own
PR is the only place the cloud roster and CI will ever see the code — which is why it takes the
full 4b ritual under every profile, and why fast mode is never available to it.

## Cited by

- `skills/build-item/SKILL.md` — the step-8 pointer ("Read … when step 7 reports the release
  unit at zero") and the one-off section's pointer ("Read … before changing the one-off
  classification or its step-0 delta").
- `skills/build-item/SKILL.md` — the working-base note on why stories merge into the integration
  branch, step 5a's story-branch deletion, step 6.5's below-floor defect placement, and step 8's
  `live: false` / no-release-notes rules, each citing this file with "(why: …)".
