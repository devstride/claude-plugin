---
load: contract
---
# Plan-scope release — a whole plan released as one unit

Opt-in. Without the marker below, nothing in this file applies and every step behaves exactly as
the rest of `build-item` says. The reasoning is
`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/epic-release.md` ("Why the plan is the safety
unit in plan scope").

## The marker

- A plan root opts in with one description line, in the contract's exact form
  `<p><strong>Release scope:</strong> plan</p>`. `plan` writes it only when the owner raises it,
  never by default; no skill switches a plan on its own.
- Read it on the same walk as the delivery profile's root marker
  (`${CLAUDE_PLUGIN_ROOT}/skills/plan/references/delivery-profiles.md`, "The root marker"): every
  ancestor ABOVE the item's release unit, with `get_item(view: 'full')` — a summary omits the
  description, and a missing description is never read as "no marker". Pass the text after
  `Release scope:` on each ancestor as that chain entry's `releaseScope` (omit it, or pass `null`,
  when the description has no such line).
- The NEAREST marker decides, case-insensitively: `plan` → plan scope, rooted at that ancestor;
  `epic`, or no marker anywhere → the default. Any other value: routing answers `refuse` — STOP and
  quote the line to the owner.
- It is for a deliberate fast build whose epics depend on each other — never a way to keep
  unfinished features from customers (a stored product setting does that) — and it never leaves
  work log-jammed behind one deploy: ship as often as is efficient.

## The plan integration branch

- Named by `planIntegrationBranches.pattern` (`<prefix>`, the date token, `<plan-number>`,
  `<plan-title-slug>` — the plan root's title slug under `epicIntegrationBranches.slugRule`, passed
  as `planSlug`). Unset: routing exits 2 — report a config gap and stop; never invent a name.
- `python3 ${CLAUDE_PLUGIN_ROOT}/skills/build-item/scripts/routing.py release-target` answers
  `{kind: "plan", branch, create, from}`. `from` is where the epic would have gone without plan
  scope (`epicIntegrationBranches.releaseTarget`): the plan branch is cut from it and the whole plan
  is released into it. `create` → at the plan's FIRST epic release, fetch `from` and push
  `refs/remotes/origin/<from>:refs/heads/<branch>`. `ask` → ask the owner with the candidates;
  `refuse` → STOP with its reason.
- Merge-only: never rebased, amended or force-pushed, and deleted only by the plan release.

## New and existing epic branches

- When `target` answers `create` for an epic branch, cut it from `routing.py epic-base`'s `branch`
  (the plan branch once it exists, else `baseBranch`) instead of `baseBranch`.
- An EXISTING epic branch in plan scope is refreshed when a story starts: if
  `git merge-base --is-ancestor origin/<plan branch> origin/<epic branch>` fails, merge the plan
  branch in (`--no-ff`) and push before branching; a conflict STOPS.

## An epic's release (step 8)

The gate is unchanged. Then, in `epic-release-steps.md`'s order, with these differences:

- **Refresh** the plan branch first: merge `origin/<from>` into it (`--no-ff`), push. Then merge the
  plan branch into the epic branch in place of `baseBranch`. A conflict STOPS; a migration number
  taken on both sides STOPS for the owner.
- **Cut** the EPIC RELEASE PR with base = the plan branch; review the full diff as today.
- **Close out**: comment on the release unit ("reached <plan branch> with #<n>") and leave its leaves
  landed. They are NOT Done yet: Done comes with the plan's release. Delete the epic branch per
  `epicIntegrationBranches.deleteBranchAfterRelease`.
- **Age guard**: when the plan branch is more than 7 days old (its oldest commit in
  `origin/<from>..origin/<plan branch>`) or its diff against `from` matches
  `release.releaseBranchFixExclusions`, ask the owner ONCE per plan, recorded in handoff memory,
  whether to release the plan now. Never release early unasked. Yes → the plan release below,
  remaining epics included later on a fresh plan branch (the release deletes this one).

## Selection and counting

- **The plan's landed set**: each merge in
  `git log --first-parent --merges --format='%H %P' origin/<from>..origin/<plan branch>` whose
  second parent is NOT an ancestor of `origin/<from>` (that skips the refreshes) is an epic release;
  its stories are the merges in `git log --first-parent --merges --format=%s <merge>^1..<merge>^2`,
  numbers parsed as `next-unblocked.md` parses landed subjects.
- **`blocked_by`** is also satisfied when the target is in the plan's landed set AND the dependent is
  under the same plan root. A blocker outside the plan still waits for Done.
- **Remaining**: the plan's leaf descendants neither Done nor landed (in any epic's landed set or
  the plan's), the deferred container excluded
  (`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/deferred-container.md`). A held or blocked
  epic holds the whole plan: show it in the `Release scope` progress row, never work around it.

## The plan's release

When the plan's remaining count reaches zero:

- Gate: `epicIntegrationBranches.autoRelease`, read exactly as step 8 reads it (present wins;
  `"ask"` asks once).
- Refresh the plan branch from `from`, then cut the **PLAN RELEASE PR** via `/devstride:pr`
  declaring `merge-only: true`: head = the plan branch, base = `from`, body leading with the plan
  root and listing every epic with its release PR.
- **Review scope**: only what no pull request reviewed — the refresh merges' conflict resolutions
  and every commit with no settled reviewed-head record, passed as the scope manifest. Each epic was
  fully reviewed on its PR onto the plan branch.
- **Merge, then close out every epic of the plan**: the unit first, then its leaves, each → Done,
  linking the plan release PR ("reached <from> with the plan release pull request #<n>"). Delete the
  plan branch. Then `epic-release-steps.md`'s last bullet (the auto-start trigger) when `from` is
  the release train.

## Cited by

- `skills/build-item/SKILL.md` — the working base, step 0's marker walk and step 8.
- `skills/build-item/references/epic-release-steps.md` — refresh, cut base and close-out.
- `skills/build-item/references/next-unblocked.md` — blocker satisfaction and the remaining count.
- `skills/build-item/references/progress-table.md` — the `Release scope` row.
- `skills/plan/SKILL.md` — step 2, writing the marker.
- `skills/comprehend-plan/SKILL.md` — reporting the scope.
- `skills/setup/references/config-defaults.md` — `planIntegrationBranches`.
