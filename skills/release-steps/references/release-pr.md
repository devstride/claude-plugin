---
load: contract
---
# Open the release pull request — a draft, so CI runs last and once

`release-steps`' `release-pr@1` step (the step `open-release-pr`). **Read
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-pr.md` in full first**: the
release-flavored body and its markers, cited, not copied.

1. **Shape** (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`): `ADOPTED`
   or `MERGED` → `ADOPTED <pr>`, the shape's `pullRequest`. The payload's `tower` with
   `adopted: true` wins over the shape, whatever it said (`resume-rules.md` "What the payload
   carries"): `ADOPTED <pr>`, the provider's local record's `pr` (`clearance.md` "The local
   record"), open or merged. Nothing is opened.
2. **Safe to re-run.** An open pull request into `release.productionBranch` whose head is this
   run's release branch (the name in `cut-branch`'s recorded `CUT <name>`, from the runner's
   `status`) is this run's, opened by an earlier attempt cut off before its `done` →
   `OPENED <pr>` again; never a second, and never a `gh pr create` GitHub would refuse. With no
   release branch pattern (headed by the source), only one whose holder marker is this session's
   or this run's recorded verdict for this step counts.
3. **Draft or not** is the CI hold's reading
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/ci-hold-proof.md` step 1): pull-request
   workflows exist → `--draft` (the draft holds CI via `ci.draftGateCondition` until the
   review's ready flip); none → no `--draft`, said "no pull-request CI".
4. **Open it**: `gh pr create [--draft] --base <productionBranch> --head <release branch>` (no
   `release.releaseBranchPattern`: `--head <releaseSource>`), never `--fill`. The body follows
   `prBodyTemplate.sections` as `release-pr.md` "`open-release-pr`" says, from the delta of `origin/<productionBranch>..<sourceHead>`
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-delta.md` step 4, read again),
   and ends with `<!-- devstride:loop -->`, on a release branch
   `<!-- devstride:release-branch <name> cut <sourceHead> -->`
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-branch.md` "Where the cut point
   is read") and, under scope `merge-and-deploy`, `<!-- devstride:release-holder <digest> on
   <machine> -->` (the digest rule of `${CLAUDE_PLUGIN_ROOT}/skills/release/references/clearance.md`).
   Every marker is written now: the body is never edited after the ready flip.
5. **Heartbeat `pr --pr <n>`** once it is open (scopes `release` and `cut-to-deploy`, only while
   this session's local clearance record shows it holds the tower; `resume-rules.md`
   "Heartbeats"). Exit 4 → stop.
6. Leave cloud review requests to the review; never `--delete-branch` a pull request headed by the
   source or a protected branch. Answer `OPENED #<n>`, with its link and whether it is a draft.

## Verdict

`RELEASE PR: OPENED <pr> | ADOPTED <pr>`

## Result

`state`: `opened` or `adopted`; `pullRequest`: its number, which the pre-merge checks read.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-branch.md` — the cut marker
