---
load: contract
---
# Review the release — the full gated review, settled on one head

`release-steps`' `release-review@1` step. How `review` is invoked, how the head is re-validated
and what happens to findings are
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-pr.md` "Step 2", cited, not copied.

1. **Config wins.** Load `.claude/ds-config.json`: `release.productionBranch`,
   `release.releaseBranchPattern`, `release.releaseBranchFixExclusions`,
   `release.productionReview`, `preShipChecks`, `profile` and the `review.*` block `review` reads.
2. **Which release, and its shape**
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`). The pull request and
   branch are the payload's `shape` ones when it is `ADOPTED`: the open pull request is reviewed.
   When it is `NEW`, they are this run's own open release pull request into the production branch
   (under scope `merge-and-deploy`, the one whose `devstride:release-holder` marker is this
   session's). `MERGED` → nothing is reviewed again: `SETTLED <head>`, the head that merged.
3. **Heartbeats.** Send the tower `heartbeat review` before the first mutation, only when this
   session holds the tower; heartbeat the train claim through the review and CI waits
   (`resume-rules.md` "Heartbeats").
4. **Resolve the delivery profile first** and pass it by name to `review`
   (`${CLAUDE_PLUGIN_ROOT}/skills/plan/references/delivery-profiles.md`): the payload's `profile`
   when it carries one, else a bare profile word the run was started with,
   else config `profile` (unknown: `standard`), else `extended`, announced with its source. It never loosens this step — unless `release.productionReview` is set: then
   read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/review-once.md` first; it decides how
   much of this step runs (an identical tree: one `highRiskEngine` pass over the high-risk paths,
   then the hold is discharged by the `pre-ship-resume` step, which marks the pull request ready).
5. **Invoke `review`, declaring it DRIVEN**, with `review-moment: production-release`,
   `release-branch: true` on a release branch, critical merge-gate routing, the scope manifest
   from the delta (`git log --first-parent origin/<productionBranch>..<head>` and the merged pull
   requests in that range: files and symbols where epics interact, conflict-resolution commits,
   migrations and public contracts, commits with no settled review record) and each constituent
   pull request's seeded dispositions from its `devstride:review-context` marker. Enforce the
   release-surface scope with that manifest (why: `release-gates.md`, which `release-pr.md`
   points to). Run again after the hotfix catch-up answered `MERGED`, it is a contextual
   follow-up over that merge's range with the same ledger and counters, never a fresh cycle 1.
6. **Declare a PRE-SHIP HOLD in that same invocation** whenever `pre-ship release select`, never
   given `--ran-at-train` here, prints `PRE-SHIP SELECTED`: `review` settles, stops at its 7.1b
   and hands back. The pre-ship checks and the ready flip are later steps: CI last, once.
7. **Every commit added to a release branch first passes the fix-exclusion check** against
   `release.releaseBranchFixExclusions`; a match is refused → `BLOCKED`. Never rebase, amend or
   force-push it.
8. **Re-validate the head immediately before the flip or the hand-back.** On a release branch it
   advances only by this run's fix commits and a hotfix merge, each re-reviewed. Anything else →
   `HEAD MOVED`: a ready pull request is first returned to draft (`gh pr ready --undo`); the next
   attempt recomputes the delta and restarts the review on the new head with the same ledger,
   target and safety triggers. Any return to this step voids any owner yes already given.
9. **Findings.** Only a genuinely ambiguous or risky finding stalls → `BLOCKED`, with a
   recommendation. Each untracked deferral becomes a `create-defect deferred` or
   `create-story deferred` item when a plan root exists, else it is noted for the owner; never
   spliced. Do NOT merge here.
10. **Settled** → `SETTLED <head>`: the SHA that finally settled is `<reviewedHead>` (after
    `review` 7.3's empty re-trigger commit when one fired: same tree). Say whether a hold is
    waiting, and with `release.productionReview` which path the review took, with both tree hashes.

## Verdict

`RELEASE REVIEW: SETTLED <head> | HEAD MOVED | BLOCKED <findings>`

## Result

`state`: `settled-hold` (a pre-ship hold waits to be discharged), `settled`, `already-merged`,
`head-moved` or `blocked`; `reviewedHead`: the settled SHA, else the head the review last read.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
