---
name: rationalize-gantt
description: Backfill synthetic dates and rationalize the dependency graph of a DevStride plan so its Gantt renders as a clean cascade
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

**Goal:** the plan's Gantt renders as a maximally-compressed, gapless, fully-valid dependency
cascade that BEGINS ON THE PLAN'S START DATE — every story the same assumed length, each dependency
in the immediately-preceding slot, NO empty slots and NO red (invalid) dependency lines. Use it
after building out (or partway through) a plan whose dates drifted, went stale, sit in the past or
never reflected the real `blocked_by` graph. Every story takes the same assumed length (ONE day,
the Claude Code build pace, unless `item-days` says otherwise), so this is a synthetic critical-path
view, not a forecast: it shows critical-path depth in exactly `critical-path-length` slots and turns
every red line into a prompt to fix a wrong or coarse dependency rather than a scheduling fudge —
the plan is the spine `/devstride:build-item` walks, and this keeps it honest.

Plan-root argument — the item whose descendant tree IS the plan (a parent item at any grouping
level — e.g. this org's Solution or Epic — or a workstream; e.g. `I20100`), or a roadmap/Gantt name;
optionally `start <YYYY-MM-DD>`, the day the earliest story this pass dates begins, and
`item-days <N>`, the whole calendar days one story is assumed to take (step 0 settles both);
empty → ask which plan to rationalize: $ARGUMENTS

## Rules that must hold

- **The DevStride MCP targets PRODUCTION.** Every date and relationship change is a real,
  user-visible edit, and the cascade OVERWRITES start/due dates across the tree — when asked to
  re-date completed items too, including the real completion dates `build-item`'s ritual stamped.
  Confirm scope (step 0) before mutating.
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
limit 200) gives the nodes with `number`/`title`/`parentNumber`/`status`/dates. Confirm, since each
changes the output: (a) the root; (b) which leaves to re-date — default the not-done ones only, so
a finished story keeps the completion date `build-item`'s ritual stamped; re-date completed items
too only when the user asks for one clean cascade — say it moves finished stories onto the new
dates (a landed leaf — merged status or a "merged onto"
comment, awaiting its epic's release
(`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/next-unblocked.md`) — counts as done);
(c) the start date and the item length — the arguments' `start` and `item-days`, else ASK for
both here, offering the defaults: the day after today, and the length the open stories already
share (one day when they share none). **A plan never starts today or earlier unless the user names
that day.** A run another skill invoked, or one with nobody to ask, never asks: it uses what its
caller passed, else the defaults; (d) the deferred items: resolve the plan root's deferred container and
its `members` with `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/deferred-container.md`
("Finding it") and say "N deferred items will be dated after the plan". **Members — the container
included — stay out of steps 2, 3, 5 and 6 entirely** (no depth, no violation, no edge
rationalized); a `blocked_by` or `blocks` edge found touching one is REPORTED, never written or
removed. Step 4.5 alone dates them.

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
- **Run the script — never compute a date another way.** Pipe `{"today", "start", "itemDays",
  "leaves": [{"number", "blockedBy", "groups", "fixed", "startDate", "dueDate"}]}` to
  `python3 ${CLAUDE_PLUGIN_ROOT}/skills/rationalize-gantt/scripts/cascade-dates.py`: `leaves` is
  every leaf outside the deferred container, `blockedBy` its step-2 referenceIds, `groups` every
  container above it up to and including the root, and EVERY leaf carries its existing dates.
  `start` and `itemDays` are step 0's, each sent only when named: absent, the script uses the day
  after `today` and the length the open leaves already share, else one day (`itemDaysFrom`). In
  not-done-only mode each Done or landed leaf also carries `"fixed": true` and is never re-dated.
- **Exit 1 is a DEPENDENCY CYCLE → STOP: write not a single date** (`plan` relies on this pass to
  catch cycles). `cycles` lists only the TRUE members — strongly connected components of size > 1,
  plus self-edges — each with the `path` round it; report exactly those and the path, never a leaf
  merely waiting on a cycle (given `A ↔ B` and `A blocked_by C`, `C → A` is valid, and naming `C`
  invites deleting a correct edge). **Then say how to get moving again**: a stopped pass leaves the
  plan entirely undated, worse than before. Propose which edge to drop or repoint (usually one
  direction of a mutual `blocked_by` pair is simply wrong); once corrected, **re-run from the
  top**. Steps 4–7 never execute while the stop stands, so the fix happens before the re-run, not
  inside this pass.
- **Exit 0** returns `assignments` (each leaf's start and due), `groupSpans` (each container's
  span over its descendants; spans nest), `distribution`, `outsideEdges` (step 5 judges them) and
  the `start` and `itemDays` used: the deepest leaves begin on `start`, every dependency is due
  before its dependents start, and no slot is empty. **`heldBy` set** → a finished blocker was not
  over before a leaf it blocks would have started, so the whole cascade moved later by the fewest
  days that clear it: tell the user `requestedStart`, `start` and which item held it.

## 4. Apply the dates

`bulk_update_items` with `{ workItems: [{number, startDate, dueDate}] }` — every assignment and every group span, the root's included. CHUNK to ~22 items per call; a ~65-item payload returns `503 Service Unavailable`.

## 4.5 Date the deferred items — after the plan

Pipe `{"today", "start", "itemDays", "valueLeaves": [{"number", "dueDate"}], "deferred": [{"number",
"done", "startDate", "dueDate"}]}` to `python3 ${CLAUDE_PLUGIN_ROOT}/skills/rationalize-gantt/scripts/deferred-dates.py`
— `start` and `itemDays` as step 3 returned them, `valueLeaves` the dates step 3 just computed for every leaf outside the container (plus the
existing dates of Done leaves in not-done-only mode), `deferred` every member leaf with its
`groups` (the matched containers and intermediate nodes above it). It returns the
`boundary` (the last value due date, never earlier than the day before `start`), `assignments` (`scheduled`: `itemDays` long each, the first starting
the day after the boundary, then the next, in item-number order; `kept`: an item already starting after the boundary
keeps its dates),
`untouchedDone` and `groupSpans`. Write every `scheduled` entry and every group's span
(and the root's due date, when a deferred item is now due after it)
with step 4's chunked `bulk_update_items`, under step 1's check, `staticMode` omitted; a `kept`
entry writes nothing. Related-only items cannot trigger propagation. No member → skip.

## 5. Find the violations (the red lines)

For EVERY `blocked_by` edge X→D whose dependent X this pass dated, a violation is
`start(X) ≤ due(D)`. Two sources dominate: coarse links to a whole CONTAINER whose span reaches the
plan's end (the bulk of the reds), and links to items outside the tree — fetch D's real date; it is
often already Done and dated early. **An edge whose dependent kept its dates (a `fixed` leaf) is
history**: count the red ones for the report; never rationalize one.

## 6. Rationalize each violated edge — judge necessity, never blindly offset

Pushing the dependent after the whole container de-compresses into the future. Judge each edge
against the plan (X's and D's descriptions and X's OTHER `blocked_by` edges); for many, fan out a
`Workflow`, one agent per dependent, returning `{dep, verdict, repointTarget?, rationale}` — be
decisive and cite what you saw:

- **REMOVE** — redundant: X's real prerequisites are already captured by story-level edges (or by
  timing); the coarse link merely restates "needs that capability".
- **REPOINT** — real intent, too coarse: point it at the specific foundational STORY X needs
  (usually an early one), valid against the existing dates with no date change.
- **KEEP (+offset)** — X genuinely must follow the ENTIRE target: move X to start on `due(D) + 1`,
  keeping its length. The only case that de-compresses; keep it rare and deliberate, and tell the
  user.

Apply with `bulk_update_items` `workItemRelationships` (`removedRelationships` /
`addedRelationships`, each `{type:"blocked_by", entity:"workitem", referenceId}`); a REPOINT is a
remove plus an add. Omit `staticMode` per
`${CLAUDE_PLUGIN_ROOT}/skills/rationalize-gantt/references/auto-scheduler-off.md`.

## 7. Verify + report

Recompute violations over the UPDATED graph (your removes/repoints plus the known external dates)
and assert ZERO remain among the edges whose dependent this pass dated. Report the start date and
item length used (and a held start), how many red edges between finished stories were left alone, the
distribution per start day (first → last), the edge changes
(removed / repointed / kept-with-offset) and any offsets, and one deferred line: how many items
were dated and from which day to which, how many kept their own date, how many Done were left
alone, and any edge found touching a member; tell the user to refresh the Gantt.
