---
name: rationalize-gantt
description: Backfill synthetic dates and rationalize the dependency graph of a DevStride plan so its Gantt renders as a clean cascade
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

Backfill synthetic dates and rationalize the dependency graph of a DevStride plan so its Gantt renders as a maximally-compressed, gapless, fully-valid dependency cascade. Use it after building out (or partway through) a plan whose item dates have drifted, gone stale, sit in the future, or never reflected the real `blocked_by` graph — and to surface/clean up wrong or coarse dependencies (the red "invalid dependency" lines are a free lint of your plan graph). Assumes every story takes exactly ONE day — the Claude Code build pace — so the timeline is a synthetic critical-path view, not a forecast.

Plan-root argument — the item number whose descendant tree IS the plan (a parent item at any
grouping level of your org's hierarchy — e.g. this org's Solution or Epic — or a workstream; e.g.
`I20100`), or a roadmap/Gantt name; empty → ask which plan to rationalize: $ARGUMENTS

IMPORTANT:
- The DevStride MCP targets PRODUCTION. Every date and relationship change here is a real, user-visible edit to live items. The cascade OVERWRITES existing start/due dates across the whole tree — including the real completion-ritual dates set by `build-item`. Confirm the scope root (and whether completed items are in scope) before mutating.
- This is a Gantt-grooming skill — it changes DevStride data only, never the repo.
- **Re-date ONLY — never renumber.** Leaf-item titles carry stable bracketed execution-order prefixes (`[N]`, `[23.1]`) per the CANONICAL NUMBERING CONVENTION — `${CLAUDE_PLUGIN_ROOT}/skills/plan/references/execution-order-numbering.md` — which are INDEPENDENT of the synthetic dates this skill computes. Do NOT touch, re-sequence, or "fix" title prefixes here even when the recomputed cascade reorders items on the timeline — write only `startDate`/`dueDate` (step 4) and relationships (step 6), never `title`. Prefixes disagreeing with date-order is expected per that convention — leave it.
- Goal state: every story is 1 day, each dependency sits on the immediately-preceding day(s), there are NO empty days, and there are NO red (invalid) dependency lines. "Compress as much as possible AND display only valid dependency dates."

## 0. Scope + confirm
- Resolve the plan root from `$ARGUMENTS` (or ask). Pull the full descendant tree with `search_items` (hierarchy=[root], itemType=workitem, no `isDone` filter, limit 200) → the node list with `number`/`title`/`parentNumber`/`lane`/dates.
- Confirm with the user, because each materially changes the output: (a) the root; (b) re-date completed items too, or only not-done? (default: everything, for one clean cascade); (c) confirm the 1-day-per-story assumption.

## 1. Disable the organization-wide dependency auto-scheduler FIRST — non-negotiable
- Apply the canonical Enable Link Mode rule NOW, in full — `${CLAUDE_PLUGIN_ROOT}/skills/rationalize-gantt/references/auto-scheduler-off.md`: read the organization setting, have the user disable it if on (never change it automatically), run the probe-date verification before mass-writing dependent dates, and omit `staticMode` from every probe, date, and relationship write. Gist: with the scheduler on, the backend overwrites the stored dates of dependent items, defeating this entire skill.

## 2. Gather the full dependency graph
- For every item in the tree, fetch its `blocked_by` edges: `get_item(view:"full", fields:["number","relationships"])`, keeping `type === "blocked_by"` referenceIds.
- For large trees, FAN THIS OUT with a `Workflow` (chunks of ~10 items per agent, each returning `{item, blockedBy:[...]}`, merged) — far faster than serial reads. Workflow gotcha: read `args` defensively at the top — `const items = Array.isArray(args) ? args : JSON.parse(args)` (args can arrive JSON-stringified).

## 3. Compute the compressed cascade (deterministic — do it in a script, not by hand)
- CONTAINERS = items that are a `parentNumber` of another item (any container level — this org: Epics/Capabilities). LEAF stories = the rest.
- **DETECT CYCLES FIRST, before computing any depth.** Topologically sort the LEAF→LEAF `blocked_by` graph (repeatedly remove nodes with no unprocessed dependents). If every node is removed the graph is acyclic — proceed. If any remain, **STOP: do not compute depths and do not write a single date.** But do NOT report the whole remainder as "the cycle": the leftover set also contains innocent ancestors that merely feed a cycle (given `A ↔ B` and `A blocked_by C`, `C` never clears either, yet `C → A` is a perfectly valid edge). Reporting it would invite deleting a correct dependency. **Isolate the true members first** — compute strongly connected components over the remaining subgraph and report only components of size > 1 (plus any self-edge), naming the actual cycle path. Everything outside those components is fine and must be left alone.
  **Then say how to get moving again**, because a stopped pass wrote NO dates and the plan is
  therefore entirely undated — a worse state than the one it was called to fix, if the operator is
  left there. Report the cycle path, propose which edge to drop or repoint (the members are usually
  a mutual `blocked_by` pair, one direction of which is simply wrong), and once the edges are
  corrected **re-run this step from the top**. Step 6's REMOVE/REPOINT machinery is unreachable
  while the stop stands — steps 4-7 never execute — so the correction happens before the re-run,
  not inside this pass. This is not optional defensive coding: the depth definition below is recursive with a base case of "nothing depends on it", so no member of a cycle ever reaches that base case and a script implementing it either never terminates or blows its stack. `plan` relies on THIS pass to catch cycles, so a hang here reads as a hung tool rather than the graph error it is.
- `depth(leaf)` = 0 if no leaf depends on it (a final deliverable → sits on TODAY), else `1 + max(depth(c) for every leaf c that is blocked_by this leaf)`. Use only LEAF→LEAF `blocked_by` edges for depth (ignore edges to containers / out-of-tree items here — they are handled as violations in step 5). Safe to evaluate only because the cycle check above already passed.
- `date(leaf) = TODAY − depth days`; `startDate == dueDate` (1-day stories).
- CONTAINER span = `[min(child start), max(child due)]` over its descendants (container spans nest — this org: epics span their stories, capabilities their epics).
- Result: leaves land on TODAY, every dependency is exactly one day before its dependent, and every day from the deepest root to today is populated (no dead zones).

## 4. Apply the dates
- Write with `bulk_update_items` ({ `workItems`:[{number,startDate,dueDate}], `folders`:[] }). Both keys are required; pass `folders: []`.
- CHUNK to ~22 items per call — a ~65-item payload returns `503 Service Unavailable`.

## 5. Find the dependency violations (the red lines)
- A red edge = a dependent dated on/before its dependency finishes. For EVERY `blocked_by` edge X→D, flag a violation when `start(X) ≤ due(D)`. Compute it in the script over all edges + the dates you just set. Two sources dominate:
  - **Coarse container-level links** — X is `blocked_by` a whole CONTAINER (this org: an epic/capability) whose span reaches today, so X (earlier) violates it. These are the bulk of the reds.
  - **Cross-container / external links** — D lives outside the plan tree (another container branch of the hierarchy). Fetch D's real date to judge; it is often already Done and dated early.

## 6. Rationalize each violated edge — review necessity, do NOT blindly offset
- The wrong fix is to push the dependent after the whole epic (that de-compresses into the future). Instead, judge each violated edge against the plan (read X's + D's descriptions and X's OTHER `blocked_by` edges):
  - **REMOVE** — the link is redundant: X's genuine prerequisites are already captured by its story-level `blocked_by` edges (or by timing), and the epic/external link merely restates "needs that capability." Drop it.
  - **REPOINT** — the intent is real but too coarse: re-point it at the specific foundational STORY inside the epic that X actually depends on (usually an early one), so the edge becomes valid against the existing dates with no date change.
  - **KEEP (+offset)** — X genuinely must follow the ENTIRE target. ONLY this case warrants an offset (move X to `due(D) + 1`), which de-compresses; keep it rare and deliberate, and tell the user.
- For many violations, fan the per-edge review out with a `Workflow` (one agent per dependent X: fetch X + its targets, return `{dep, verdict: REMOVE|REPOINT|KEEP, repointTarget?, rationale}`). This is the "are these accurate to the plan and in fact necessary" review — be decisive and cite what you saw.
- Apply with `bulk_update_items` `workItemRelationships` (`removedRelationships` / `addedRelationships`, each `{type:"blocked_by", entity:"workitem", referenceId}`), omitting `staticMode` per `${CLAUDE_PLUGIN_ROOT}/skills/rationalize-gantt/references/auto-scheduler-off.md`. A REPOINT = remove the old edge + add the new one.

## 7. Verify + report
- Recompute violations over the UPDATED graph (apply your removes/repoints, and add the now-known external-target dates, in the script). Assert ZERO remain.
- Report: the per-day distribution (items per day, earliest → today), the edge changes (removed / repointed / kept-with-offset), and any KEEP offsets. Tell the user to refresh the Gantt.

## Why this exists / philosophy
The DevStride plan is the spine for `/devstride:build-item`; this skill keeps its Gantt honest. Because Claude Code finishes each story in a day, real execution collapses to a point — so a synthetic 1-day-per-story cascade ordered by the TRUE dependency graph is the most useful stakeholder view: it shows critical-path depth, compresses to exactly `critical-path-length` days with no dead zones, and turns every red line into a prompt to fix a wrong/coarse dependency rather than a scheduling fudge.
