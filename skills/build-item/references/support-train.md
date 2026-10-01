---
load: contract
---
# The support train — where one-offs go when one is configured

**Goal:** one-off items (no release-unit ancestor) batch on one long-lived branch that ships with
every release, instead of each merging straight into `baseBranch` and paying its own CI and
deploy.

`supportTrain.branch` absent → none of this runs: a one-off's working base is `baseBranch` and it
takes the full per-story PR ritual, as before. `supportTrain.fastMerges` absent or `false` → a
one-off on the train still takes the full per-story PR ritual (4b), with the train as the pull
request's base.

## Routing (step 0)

- **A train that never ships strands its one-offs.** With `release.mergeTrainBeforeCut` not `true`,
  nothing ever merges the train into `baseBranch`, so route the one-off to `baseBranch` instead and
  announce why ("support train set, but releases do not merge it").
- **One-off AND `supportTrain.branch` set (and the train ships) → the working base is the train.**
  Resolve it with `git ls-remote --exit-code --heads origin <train>`: present → reuse; absent →
  create it off a freshly fetched `origin/<baseBranch>` and push. Announce "support train <name>:
  reused" or "created".
- **Deploy configuration and migrations never ride the train.** A one-off whose change touches a
  path matching an entry of `release.releaseBranchFixExclusions` (absent → nothing is excluded;
  matching per `${CLAUDE_PLUGIN_ROOT}/skills/release/references/branch-patterns.md`) ships to
  `baseBranch` by the full 4b ritual instead, announced with the matching paths. Decide it at step 0
  from the validated spec, and check it again on the real diff before step 4: a story branch cut
  from the train that turns out to touch such a path is moved with
  `git rebase --onto origin/<baseBranch> origin/<train>` (a disposable story branch; this drops the
  other one-offs the train carries) and continues by 4b into `baseBranch`.

## Delivery path

- **`supportTrain.fastMerges` true → fast mode (4a, then 5a) exactly as for an epic branch, with
  the train in its place**: the completed risk check (immediate-risk verifier and matched lenses
  included), a green local gate at the profile's `storyVerify` width, a `--no-ff` merge onto the
  train per `commitConventions.epicMergeFormat` (the item number leads the subject — `release`
  reads it later), the push, then the story branch deleted. The full review, the configured
  engines and CI move to the train's pull request into `baseBranch`, which `release` opens before
  every cut. 4a's floor holds: no completed risk check or receipt → 4b.
- **Otherwise → 4b with the train as the base.**

## Completion ritual (step 6) for a one-off on the train

- **It is NOT Done yet.** `add_comment` "merged to the support train <name> (<pull request link,
  or merge SHA>); ships with the next release". Leave its status as it is, set `startDate`, set no
  `dueDate`. `release` marks it Done when the train's pull request reaches `baseBranch`.
- The pull request link (4b) and the as-built reconciliation run as usual.
- Step 7 terminates as for any one-off; the recap says it is on the support train and becomes Done
  when the next release ships it.

## Why

Every merge into the base branch runs paid CI and, in many repositories, a deploy. One-offs that
batch on the train get one full review and one CI pass at release time — the same reasoning as an
epic release pull request — and the train ships with every release, so nothing waits longer than
the next cut. Deploy configuration and migrations are excluded because the train reaches
production at the next release with little time in between; they deserve their own pull request,
CI and an earlier deploy to a development stage.

## Cited by

- `skills/build-item/SKILL.md` — the working-base precedence, one-off mode, step 4 and step 6.
