---
load: contract
---
# Epic release — the steps after the gate fires

A branch reference (CONTRIBUTING.md, "Branch references"): `build-item` step 8 keeps the gate —
zero remaining leaves, working base the unit's integration branch, auto-release on per
`epicIntegrationBranches.autoRelease` — and reads this file in full before acting on a release
that fires, or on step 0's recovery close-out after an owner merged the release. Every bullet is an
instruction for a release that fires; a recovery close-out applies the claim, then only the Merge
bullet from "close out" onward — never Refresh, verify, cut or merge again. The reasoning behind them is
`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/epic-release.md`.

## Steps

- **Claim first**, at either entry (step 7 at zero, or step 0's dry chain or recovery close-out),
  unless auto-release is off: kind `epic-release`, key the release unit's number (plan scope: the
  plan's unit), as `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/parallel-building.md` says.
  `skip` → name who is releasing it, and carry on with this session's loop (reached from the
  dry chain: exit). Heartbeat it at each ship-intent stage of the release (`reviewing`,
  `verifying`, `landing`); after the close-out, release it, outcome `released`, never final. A
  STOP keeps it.

In plan scope, the refresh source, the cut base and the close-out change as
`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plan-scope.md` says; read it with this file.
With `claims` set, the release is declared as
`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/ship-intent.md` says.

- **Refresh**: the loop's ONE checkout of the epic branch by name: only the releasing session (the
  `epic-release` claim holder when claims are in use) runs it, and no story step holds a shared
  branch (each works detached). Release-only by name: `git checkout <epic branch> && git pull
  --ff-only origin <epic branch>`; git refuses it because another worktree
  holds it → STOP naming that worktree (`git worktree list`), never force. Fetch `baseBranch`,
  merge its captured tip `<baseOid>` — merge, NEVER rebase shared story SHAs; non-mechanical
  conflicts STOP. Push. `/devstride:pr` then opens the pull request from this named branch.
- **One verification plan for the merged tree**: aggregate story receipts, invalidating only what the
  refresh or combined tree changed. A `verify.typecheck`/`test`/`lint` command the PR workflows run
  exactly is not run locally; a required command CI lacks runs once as a pre-ship check on the final
  reviewed head; `preShipChecks` stay local; a firing `verify.skipDuringStoryBuilds` entry stays
  cloud-only. Record where each runs; never infer coverage from a job name.
- **Step records**: for each story of the unit, read its runs from the tracker
  (`list_item_workflow_runs`) and hand the answer to the runner's `judge` with the item. List every
  story whose verdict is not `complete` under `Step records` in the pull request body, with the
  `line` `judge` gives (`not-reported`: no run was recorded; `incomplete`: the steps named).
  **A warning for the reviewer, never a block**: the release goes on, and the full review covers
  those stories like any other. No tracker tool, or reporting off → one line saying so.
- **Migrations first**: before the cut, always, run the check in
  `${CLAUDE_PLUGIN_ROOT}/skills/release/references/migration-approval.md` on the unit's head; an
  unapproved migration is asked about now, never after the cut.
- **Cut via `/devstride:pr`** autonomously, declaring `merge-only: true`: head = epic branch, base =
  `routing.py release-target`'s branch (`epicIntegrationBranches.releaseTarget` without plan scope), flagged **EPIC RELEASE PR** (body leads with the epic and
  lists its stories), with the profile, the verification plan and the aggregate risk-check ledger.
  Full review → uncovered pre-ship checks → ready flip → CI.
- **Review scope.** Fast mode used (`fastStoryMerges.epicReleaseIsFirstCloudPass`) → **review the
  FULL diff**, every story, ledgers only preventing re-raised settled findings. Stories took the pull-request path → a
  computed manifest of cross-story contracts, combined behaviour and develop-merge resolutions;
  cloud may still cover the whole PR. A firing
  `verify.skipDuringStoryBuilds` suite is mandatory, with no story exemption; with the list empty,
  local pre-ship suites remain the callers' responsibility (`pr` step 2b, the release's `pre-ship-release`).
- **Consequence notices**, just before the merge: gather the release's notices, run the release
  unit's own check on the final reviewed head, then reconcile
  (`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/consequence-notices.md`).
- **Merge** with the `MERGE` line of `python3 ${CLAUDE_PLUGIN_ROOT}/skills/pr/scripts/merge-gate.py
  <n> <head>` (`<head>`: review's final reviewed head, never the live one) once green and settled (landed set captured first; anything else STOPS), then
  **close out** (`next-unblocked.md`): `add_comment` on the RELEASE-UNIT item (release PR, leaves,
  date), Done if its status is tracked, THEN landed leaves → Done, **linking the release PR onto
  every leaf** (the close-out comment, or `link_pull_request`), and quote on the release-unit item
  when it will be live (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/estimates.md`, from the
  release pull request's merge commit, when it merged onto the train or the source). Delete the epic branch **only if
  `epicIntegrationBranches.deleteBranchAfterRelease`** — false retains it.
- **Docs STAGE, never publish** — only when `docs.updateOnEpicRelease` is true (else silent): call
  **`update-docs update`** with the `epic-release` payload, **`live: false`**, never optional
  (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/docs-hooks.md`, every field it names);
  `NOT CONFIGURED` → say so and continue; keep its links exact. **Never release notes here.**
- Update handoff memory and sync develop.
- **Human recap.** Lead with `Merged / Released`: every item and its effect, where it landed,
  validation/review/CI, docs, whether live, the remaining production action, and the unit's and
  its leaves' consequence notices (`consequence-notices.md`). Surface, never
  perform, the owner-cut promotion (`/devstride:release`). New findings → invoke `capture-findings`
  with the release unit.
- **Last, after the recap:** merged onto the train with `release.autoStart.enabled` → its trigger
  (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/auto-start.md`), after docs staged `live: false`.
  The checkout lease is KEPT through it: `return-checkout` waits until the trigger answers SKIP or ERROR, loses the claim, or the release it starts stops, and that release runs in this same leased checkout.

## Cited by

- `skills/build-item/SKILL.md` — step 8, once its gate fires or for step 0's recovery close-out.
- `skills/build-item/references/next-unblocked.md` — the Close-out bullet, for the release unit's
  comment and Done.
- `skills/build-item/references/plan-scope.md` — the plan's release reuses these steps.
- `skills/build-item/references/parallel-building.md` — the epic-release claim.
