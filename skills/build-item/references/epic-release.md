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
