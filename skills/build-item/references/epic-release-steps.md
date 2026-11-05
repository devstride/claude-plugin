---
load: contract
---
# Epic release — the steps after the gate fires

A branch reference (CONTRIBUTING.md, "Branch references"): `build-item` step 8 keeps the gate —
zero remaining leaves, working base the unit's integration branch, auto-release on per
`epicIntegrationBranches.autoRelease` — and reads this file in full before acting on a release
that fires, or on step 0's recovery close-out after an owner merged the release. Every bullet is an
instruction for a release that fires; a recovery close-out applies only the Merge bullet from
"close out" onward — never Refresh, verify, cut or merge again. The reasoning behind them is
`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/epic-release.md`.

## Steps

In plan scope, the refresh source, the cut base and the close-out change as
`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plan-scope.md` says; read it with this file.

- **Refresh**: pull the epic branch, fetch `baseBranch`, merge its captured tip `<baseOid>` — merge,
  NEVER rebase shared story SHAs; non-mechanical conflicts STOP. Push.
- **One verification plan for the merged tree**: aggregate story receipts, invalidating only what the
  refresh or combined tree changed. A `verify.typecheck`/`test`/`lint` command the PR workflows run
  exactly is not run locally; a required command CI lacks runs once as a pre-ship check on the final
  reviewed head; `preShipChecks` stay local; a firing `verify.skipDuringStoryBuilds` entry stays
  cloud-only. Record where each runs; never infer coverage from a job name.
- **Cut via `/devstride:pr`** autonomously, declaring `merge-only: true`: head = epic branch, base =
  `routing.py release-target`'s branch (`epicIntegrationBranches.releaseTarget` without plan scope), flagged **EPIC RELEASE PR** (body leads with the epic and
  lists its stories), with the profile, the verification plan and the aggregate risk-check ledger.
  Full review → uncovered pre-ship checks → ready flip → CI.
- **Review scope.** Fast mode used (`fastStoryMerges.epicReleaseIsFirstCloudPass`) → **review the
  FULL diff**, every story, ledgers only preventing re-raised settled findings. Stories took 4b → a
  computed manifest of cross-story contracts, combined behaviour and develop-merge resolutions;
  cloud may still cover the whole PR. A firing
  `verify.skipDuringStoryBuilds` suite is mandatory, with no story exemption; with the list empty,
  local pre-ship suites remain the callers' step-2b responsibility.
- **Merge** `gh pr merge <n> --merge` once green and settled (landed set captured first), then
  **close out** (`next-unblocked.md`): `add_comment` on the RELEASE-UNIT item (release PR, leaves,
  date), Done if its status is tracked, THEN landed leaves → Done, **linking the release PR onto
  every leaf** (the close-out comment, or `link_pull_request`). Delete the epic branch **only if
  `epicIntegrationBranches.deleteBranchAfterRelease`** — false retains it.
- **Docs STAGE, never publish** — only when `docs.updateOnEpicRelease` is true (else silent): call
  **`update-docs update`** with the `epic-release` payload, **`live: false`**, never optional
  (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/docs-hooks.md`, every field it names);
  `NOT CONFIGURED` → say so and continue; keep its links exact. **Never release notes here.**
- Update handoff memory and sync develop.
- **Human recap.** Lead with `Merged / Released`: every item and its effect, where it landed,
  validation/review/CI, docs, whether live, the remaining production action. Surface, never
  perform, the owner-cut promotion (`/devstride:release`). New findings → 6.5.
- **Last, after the recap:** merged onto the train with `release.autoStart.enabled` → its trigger
  (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/auto-start.md`), after docs staged `live: false`.
  The checkout lease is KEPT through it: `return-checkout` waits until the trigger answers SKIP or ERROR, loses the claim, or the release it starts stops, and that release runs in this same leased checkout.

## Cited by

- `skills/build-item/SKILL.md` — step 8, once its gate fires or for step 0's recovery close-out.
- `skills/build-item/references/next-unblocked.md` — the Close-out bullet, for the release unit's
  comment and Done.
- `skills/build-item/references/plan-scope.md` — the plan's release reuses these steps.
