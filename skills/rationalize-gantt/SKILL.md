---
name: rationalize-gantt
description: Backfill synthetic dates and rationalize the dependency graph of a DevStride plan so its Gantt renders as a clean cascade
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

**Goal:** the plan's Gantt renders as a maximally-compressed, gapless, fully-valid dependency
cascade — every story 1 day, each dependency on the immediately-preceding day(s), NO empty days and
NO red (invalid) dependency lines. Use it after building out (or partway through) a plan whose dates
drifted, went stale, sit in the future or never reflected the real `blocked_by` graph. Every story
takes exactly ONE day (the Claude Code build pace), so this is a synthetic critical-path view, not a
forecast: it shows critical-path depth in exactly `critical-path-length` days and turns every red
line into a prompt to fix a wrong or coarse dependency rather than a scheduling fudge — the plan is
the spine `/devstride:build-item` walks, and this keeps it honest.

Plan-root argument — the item whose descendant tree IS the plan (a parent item at any grouping
level — e.g. this org's Solution or Epic — or a workstream; e.g. `I20100`), or a roadmap/Gantt name;
empty → ask which plan to rationalize: $ARGUMENTS

## Rules that must hold

- **The DevStride MCP targets PRODUCTION.** Every date and relationship change is a real,
  user-visible edit, and the cascade OVERWRITES start/due dates across the whole tree — including
  the real completion dates `build-item`'s ritual stamped. Confirm scope (step 0) before mutating.
  It changes DevStride data only, never the repo.
- **Re-date ONLY — never renumber.** Leaf titles carry stable execution-order prefixes (`[N]`,
  `[23.1]`) per the CANONICAL NUMBERING CONVENTION —
  `${CLAUDE_PLUGIN_ROOT}/skills/plan/references/execution-order-numbering.md` — independent of these
  dates. Write only `startDate`/`dueDate` (step 4) and relationships (step 6), never `title`;
  prefixes disagreeing with date order is expected — leave it.
- **Compute in a script, never by eye** — the cascade, the violations and the final check alike.
- **Read edges explicitly** — `get_item(view:"full", fields:["number","relationships"])`; the
  default projection omits `relationships`, and an absent field read as "no edges" drops them.
- **A dependency cycle writes NOTHING** (step 3).

## 0. Scope + confirm

Resolve the root (or ask). `search_items` (hierarchy=[root], itemType=workitem, no `isDone` filter,
limit 200) gives the nodes with `number`/`title`/`parentNumber`/`lane`/dates. Confirm, since each
changes the output: (a) the root; (b) re-date completed items too, or only not-done (default:
everything, for one clean cascade — callers extending a live plan ask for not-done only; a landed
leaf, built but awaiting its epic's release, counts as done); (c) the
1-day-per-story assumption.

## 1. Disable the organization-wide dependency auto-scheduler FIRST — non-negotiable

Apply the canonical Enable Link Mode rule NOW, in full —
`${CLAUDE_PLUGIN_ROOT}/skills/rationalize-gantt/references/auto-scheduler-off.md`: READ the
organization's `enableStaticMode` first; if it is on, have the user disable it — **never change it
automatically**; run the probe-date verification before mass-writing dependent dates; and omit
`staticMode` from every probe, date and relationship write. With the scheduler on, the backend
overwrites the stored dates of dependent items, defeating this entire skill.

## 2. Gather the dependency graph

For every item, keep its `type === "blocked_by"` referenceIds from the explicit relationships read.
Large trees: fan out with a `Workflow` (~10 items per agent, each returning `{item, blockedBy}`,
merged); read `args` defensively — `const items = Array.isArray(args) ? args : JSON.parse(args)`.

## 3. Compute the compressed cascade

- CONTAINERS are items that are some item's `parentNumber` (any level — this org: Epics/
  Capabilities); LEAF stories are the rest. Depth uses only LEAF→LEAF `blocked_by` edges; edges to
  containers or out-of-tree items are judged as violations in step 5.
- **DETECT CYCLES FIRST.** Topologically sort the leaf graph (repeatedly remove nodes with no
  unprocessed dependents). Anything left → **STOP: compute no depths, write not a single date.** The
  depth rule below recurses to "nothing depends on it", which no cycle member reaches — a script
  would hang or blow its stack, and `plan` relies on this pass to catch cycles. Report only the TRUE
  members: strongly connected components of size > 1 (plus self-edges) over the remainder, naming
  the cycle path — the remainder also holds innocent ancestors (given `A ↔ B` and `A blocked_by C`,
  `C` never clears, yet `C → A` is valid), and reporting them invites deleting a correct edge.
  **Then say how to get moving again**: a stopped pass leaves the plan entirely undated, worse than
  before. Propose which edge to drop or repoint (usually one direction of a mutual `blocked_by`
  pair is simply wrong); once corrected, **re-run from the top**. Steps 4–7 never execute while the
  stop stands, so the fix happens before the re-run, not inside this pass.
- `depth(leaf)` = 0 if no leaf is `blocked_by` it (a final deliverable, on TODAY), else
  `1 + max(depth(c))` over every leaf `c` blocked_by it. `date(leaf) = TODAY − depth` days;
  `startDate == dueDate`. A container spans `[min(child start), max(child due)]` over its
  descendants (spans nest). Result: leaves end on TODAY, every dependency sits exactly one day
  earlier, every day from the deepest root to today is populated.

## 4. Apply the dates

`bulk_update_items` with `{ workItems: [{number, startDate, dueDate}], folders: [] }` — both keys
required. CHUNK to ~22 items per call; a ~65-item payload returns `503 Service Unavailable`.

## 5. Find the violations (the red lines)

For EVERY `blocked_by` edge X→D, a violation is `start(X) ≤ due(D)`. Two sources dominate: coarse
links to a whole CONTAINER whose span reaches today (the bulk of the reds), and links to items
outside the tree — fetch D's real date; it is often already Done and dated early.

## 6. Rationalize each violated edge — judge necessity, never blindly offset

Pushing the dependent after the whole container de-compresses into the future. Judge each edge
against the plan (X's and D's descriptions and X's OTHER `blocked_by` edges); for many, fan out a
`Workflow`, one agent per dependent, returning `{dep, verdict, repointTarget?, rationale}` — be
decisive and cite what you saw:

- **REMOVE** — redundant: X's real prerequisites are already captured by story-level edges (or by
  timing); the coarse link merely restates "needs that capability".
- **REPOINT** — real intent, too coarse: point it at the specific foundational STORY X needs
  (usually an early one), valid against the existing dates with no date change.
- **KEEP (+offset)** — X genuinely must follow the ENTIRE target: move X to `due(D) + 1`. The only
  case that de-compresses; keep it rare and deliberate, and tell the user.

Apply with `bulk_update_items` `workItemRelationships` (`removedRelationships` /
`addedRelationships`, each `{type:"blocked_by", entity:"workitem", referenceId}`); a REPOINT is a
remove plus an add. Omit `staticMode` per
`${CLAUDE_PLUGIN_ROOT}/skills/rationalize-gantt/references/auto-scheduler-off.md`.

## 7. Verify + report

Recompute violations over the UPDATED graph (your removes/repoints plus the known external dates)
and assert ZERO remain. Report the per-day distribution (earliest → today), the edge changes
(removed / repointed / kept-with-offset) and any offsets; tell the user to refresh the Gantt.
