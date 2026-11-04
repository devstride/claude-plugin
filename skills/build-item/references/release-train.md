---
load: contract
---
# The release train — where one-offs go when one is configured

**Goal:** one-off items (no release-unit ancestor) batch on one long-lived branch that ships with
every release, instead of each merging straight into `baseBranch` and paying its own CI and
deploy.

`releaseTrain` below means `releaseTrain`, or `supportTrain` when only that is present; both present
is a config error — STOP and name it.

`releaseTrain.branch` absent → none of this runs: a one-off's working base is `baseBranch` and it
takes the full per-story PR ritual, as before. `releaseTrain.fastMerges` absent or `false` → a
one-off on the train still takes the full per-story PR ritual (4b), with the train as the pull
request's base.

## Routing (step 0)

- **A train that never ships strands its one-offs.** With `release.mergeTrainBeforeCut` not `true`,
  nothing ever merges the train into `baseBranch`, so route the one-off to `baseBranch` instead and
  announce why ("release train set, but releases do not merge it").
- **One-off AND `releaseTrain.branch` set (and the train ships) → the working base is the train.**
  Resolve it with `git ls-remote --exit-code --heads origin <train>`: present → reuse; absent →
  create it off a freshly fetched `origin/<baseBranch>` and push. Announce "release train <name>:
  reused" or "created".
- **One-offs touching deploy configuration or migrations never ride the train; a reviewed release unit may.** A one-off whose change touches a
  path matching an entry of `release.releaseBranchFixExclusions` (absent → nothing is excluded;
  matching per `${CLAUDE_PLUGIN_ROOT}/skills/release/references/branch-patterns.md`) ships to
  `baseBranch` by the full 4b ritual instead, announced with the matching paths. Decide it at step 0
  from the validated spec, and check it again on the real diff (`git diff --name-only --no-renames
  origin/<train>...HEAD`) immediately before anything merges onto the train — the 5a merge, or the
  4b pull request's merge — since a review fix can add such a path. A story branch that turns out to
  touch one is moved with `git rebase --onto origin/<baseBranch> origin/<train>` (a disposable story
  branch; this drops the other one-offs the train carries), its verification receipt is void (rerun
  the local gate on the new tree), and it continues by 4b into `baseBranch` as a `pr-boundary`
  review. A reviewed release unit (an epic's pull request, merged onto the train through its own
  review) may carry migrations and infrastructure on the train: `release` checks only work no pull
  request reviewed, and, when `release.devDeployVerification` is set, waits for the development
  deploy before merging production.

`python3 ${CLAUDE_PLUGIN_ROOT}/skills/build-item/scripts/routing.py` implements this routing: `target`
(with `changedFiles` for the exclusion rule) at step 0, `excluded` for the check before a merge.

## Delivery path

- **`releaseTrain.fastMerges` true → fast mode (4a, then 5a) exactly as for an epic branch, with the
  train in its place**: the completed risk check (immediate-risk verifier and matched lenses
  included), a green local gate at the profile's `storyVerify` width, a `--no-ff` merge onto the
  train with the subject `merge: <itemNumber> <short scope> into <train>` — the item number always
  leads, whatever `commitConventions.epicMergeFormat` says, because `release` reads it later — the
  push, then the story branch deleted. The full review, the configured engines and CI move to the
  train's pull request into `baseBranch`, which `release` opens before every cut. 4a's floor holds:
  no completed risk check or receipt → 4b.
- **A small, clean fix skips its own review pass.** With `releaseTrain.smallFixes` set, on the fast
  path only, after the build run `git diff --numstat -z --no-renames origin/<train>...HEAD |
  python3 -c 'import json,sys; print(json.dumps({"config": json.load(open(".claude/ds-config.json")),
  "numstat": sys.stdin.read()}))' | python3 ${CLAUDE_PLUGIN_ROOT}/skills/build-item/scripts/routing.py
  small` — never through a shell variable, which drops the NULs (exit 2 → STOP naming the error). `small: true`, AND
  the risk check raised no finding, launched no immediate-risk verifier and matched no mandatory
  lens → 4a's `review` LOCAL-ONLY call does not run: with no finding there is nothing to triage
  or distill into lessons. The progress table's review row reads "covered by the train's release
  review (small fix: N files, M lines)". Everything else in 4a holds: the floor, the local gate,
  the merge-commit body. Otherwise 4a runs as usual (a risk-check finding still reaches the lessons
  store through it), the reason said once. The train's pull request into `baseBranch` is the
  batch's one full review and one CI run.
- **Otherwise → 4b with the train as the base.**

## Settings

- `releaseTrain.smallFixes` — `{maxFiles, maxChangedLines}`, both required, each at least 1; lines
  are added plus removed. Absent → no fix counts as small. The high-risk list is
  `release.productionReview.highRiskPaths` plus `release.releaseBranchFixExclusions`.
- `releaseTrain.lateArrivals` — `"restart"` or `"offer"` (absent: `"offer"`); what `release` does
  with a one-off that lands while the train's review is running
  (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-branch.md` step 4a).

## Completion ritual (step 6) for a one-off on the train

- **It is NOT Done yet.** `add_comment` "merged to the release train <name> (<pull request link,
  or merge SHA>); ships with the next release". Leave its status as it is — the train is not an
  epic branch, so no merged status — set `startDate`, set no `dueDate`. `release` marks it Done
  when the train's pull request reaches `baseBranch`.
- The pull request link (4b) and the as-built reconciliation run as usual.
- `release.autoStart.enabled` → its trigger after this ritual
  (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/auto-start.md`).
- Step 7 terminates as for any one-off; the recap says it is on the release train and becomes Done
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
