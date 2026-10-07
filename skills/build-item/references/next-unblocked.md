---
load: contract
---
# Next-unblocked selection — CANONICAL DEFINITION

The single authoritative rule for which item `/devstride:build-item` picks up next. Every skill that
selects, splices around, or reports "what runs next" applies THIS rule by citation — none
restates it.

## The rule

The next-unblocked item is: the highest-priority leaf item (a `hierarchyRoles.leaf` type — this
org's Story/Defect) that is neither Done nor LANDED (below), with every `blocked_by` target
satisfied, in the earliest-dated open container (this org: Capability/Epic) on the critical
path. Priority breaks ties; earlier `startDate` breaks remaining ties. Exclude anything the gating
check catches (`build-item` step 0's GATING CHECK — items that depend on a human/infra decision
that is the user's).

**A `blocked_by` target is satisfied** when it is Done, OR when it is in the git-confirmed landed
set (below) AND has the SAME nearest release-unit ancestor as the dependent leaf, so the same
integration branch. The merged status alone never satisfies one — a column of that name often
holds an open code review; only a caller without git (below) stands in with it. A target landed
under a different release unit is satisfied only when Done, so the next release unit waits until
the previous one reaches its release target.

**A release-unit cycle is never plain "blocked"**: a leaf of unit A waits on a leaf of unit B
while a leaf of B waits on a not-yet-Done leaf of A, so neither unit can release. Report it as a
release-unit cycle, naming the edge to repoint — the one making the unit in flight (it holds landed
leaves; else the earlier-dated) wait on the other.

**Exclude everything under the deferred-defect container** — the container titled
`defects.deferredContainerTitle` that sits directly under the plan root and holds postponed
review findings. Those items are tracked, not queued: they are never auto-selected, they never
count toward a remaining-leaf total, and the container is never a release unit. An item there
that the USER names explicitly by number is still built, as a one-off.

## Landed leaves — merged onto an integration branch, not yet Done

A leaf merged onto its release unit's integration branch (`build-item` 5a, or a 4b pull request
into that branch) has not reached its release target: it is **landed**, not Done. It is never a
candidate and never counts as remaining (`build-item` steps 0 and 7). A caller that reads
DevStride but never git (`comprehend-plan`, `splice-mechanics.md`, `rationalize-gantt`,
`rebalance`) has no landed set: it counts a leaf as landed when it sits in the merged status or
carries the landed comment.

- **At the merge (`build-item` step 6)** — not Done. Move it to the **merged status**: the status
  named `epicIntegrationBranches.mergedStatusName` (absent → `"Review"`; `null` → none), resolved
  BY NAME from the leaf's work-type status collection (`get_workspace_context`, as step 1 resolves
  In Progress), never a hard-coded id; no status of that name, or a move that fails → leave its
  status and say so. ALWAYS `add_comment` the **landed comment** "merged onto <integration branch>
  at <merge SHA> (<pull request link, if any>); Done when the <release unit> release pull request
  reaches <release target>", and write step 6's dates: `startDate`/`dueDate` = branch creation →
  this merge.
- **The git history is the record.** `git fetch origin`, then once per integration branch:
  `git log --first-parent --merges --format=%s origin/<release target>..origin/<integration
  branch>` (release target = `epicIntegrationBranches.releaseTarget`; branch resolved as
  `build-item`'s working base does; none on origin → the set is empty). Take ONLY each merge's
  identifying number — at `<itemNumber>` in `commitConventions.epicMergeFormat` (fallback
  `^merge: (I[0-9]+)\b`) for a fast merge, `from [^ ]+/(I[0-9]+)-` for a pull-request merge — as
  `release` reads the train (`release-branch.md` §1 step 6); merges of the base branch carry no
  number. **A leaf is landed when its number is in that landed set.** The merged status is only
  the visible signal and never stands in for the set. A pull-request merge subject names the
  branch only because `build-item` 5b passes GitHub's default subject with `--subject`: a
  repository set to use the pull-request title as the merge subject would leave no number to read.
- **Recovery — keyed on the landed comment, never the status** (it may be `null`, missing, or a
  failed move). Before selecting a candidate, read its comments: a not-Done leaf carrying the
  landed comment but absent from the landed set is never auto-selected, never rebuilt, and still
  counts as remaining, so step 8 cannot fire over it. Its merge SHA reachable from
  `origin/<release target>` (`git merge-base --is-ancestor`) → the release merged without a
  close-out: run the close-out below now and compute the ready-set again after it — never select
  from one computed before. Otherwise report the mismatch and ask.
- **Close-out (`build-item` step 8, first thing after the release pull request merges; or
  recovery).** Capture the landed set BEFORE the merge — when step 7 reports the unit at zero, and
  again right before step 8 merges (the range is empty after it). A release already merged, by
  anyone, gives that unit's set from its merge commit `<merge>` — the release pull request's
  `mergeCommit`, from
  `gh pr list --head <integration branch> --base <release target> --state merged --json number,mergeCommit`:
  `git log --first-parent --merges --format=%s <merge>^1..<merge>^2`.
  For each number: `get_item`; keep only a not-Done `hierarchyRoles.leaf` under this release unit;
  `update_item` → Done (it works off-board; `mark_done` does not), writing NO dates — they stay
  step 6's, so no auto-scheduler check — then `add_comment` "reached <release target> with the
  <release unit> release pull request #<n>". Skip one already Done or carrying that comment, so a
  re-run is a no-op; report every leaf of the unit left open as "not marked Done: <item>" — never
  guess.

## Projection warning — fetch relationships EXPLICITLY

**Fetch each candidate's relationships EXPLICITLY** — `search_items` and the default `get_item`
summary both OMIT `relationships`, so a selection computed from them sees no edges at all and
will happily run blocked work out of dependency order. The edge graph + priority + dates then
suffice — reach for `/devstride:comprehend-plan` only when the plan's state is genuinely unclear.

## Worked consequence — priority alone cannot beat an earlier-dated open container

The rule sorts by earliest-dated open container FIRST; priority only breaks ties within that
tier. If a splice creates a brand-new container dated today while some OTHER open container
elsewhere in the plan started earlier and still has its own unblocked story, that story remains
ahead of the insert no matter how high the insert's priority is set. After any splice, re-derive
the pick with this rule against the current plan state rather than assuming the splice worked.

## Why the ready-set is shape, not a fan-out instruction

The ready-set this rule produces says which items COULD run next; it never says they may run at
the same time. Test execution is serial against shared test infrastructure — runners sharing
containers or databases corrupt each other's state — and a per-checkout instance
(`localEnvironment.instanceBoundTo: directory`) isolates dev servers and app data, NOT that
shared infrastructure. Add the dirty-tree abort in `branch-feature` and an MCP that writes to
production, and a concurrent loop has three ways to damage state for one saved hour. Surfacing
the ready-set lets a HUMAN fan the waves out deliberately; the loop itself stays serial.

## Cited by

- `build-item` SKILL.md step 0 (canonical owner — selection and recovery) and the "Serial by
  design" rule (the ready-set-is-shape reasoning); steps 6, 7 and 8 (landed leaves, close-out)
- `plan/references/splice-mechanics.md` (where a splice lands, and which release unit houses it),
  and through it `insert-story` and `insert-defect`
- `comprehend-plan` SKILL.md (the next-unblocked read and the landed count)
- `rationalize-gantt` SKILL.md and `rebalance` SKILL.md (landed leaves without git; the re-derived
  next pick)
- `setup/references/config-defaults.md` (`releaseTarget` — when a story is Done)
- `plan` SKILL.md (the execution-order walk)
