---
name: insert-story
description: Insert a new Story into a live DevStride roadmap, spliced into the dependency chain and dated for the build-item loop
---

Insert a NEW Story (the one-day leaf role — this org's Story type) into a live DevStride roadmap — spliced into the dependency chain and dated so the `/devstride:build-item` loop picks it up NEXT. Its POSITION in the sequence looks native to the plan; its DESCRIPTION stays an honest spec of the real work (see the IMPORTANT note below — this is a splice/date operation, not a fabricated history). This is also the canonical capture path that `build-item` step 6.5 and `ultracode-build` use to turn an untracked deferral or newly-found follow-up into tracked, dependency-ordered work.

Argument — free text describing the story, optionally prefixed/suffixed with a parent item number
(any grouping level of your org's hierarchy, e.g. this org's Module/Capability/Epic — as in
`I20100 add rate limiting to webhook intake` or just `add rate limiting to webhook intake`): $ARGUMENTS

IMPORTANT — the DevStride MCP targets PRODUCTION (`api.devstride.com`). Every create/update here is a real, user-visible change to the live plan.

IMPORTANT — this is a Gantt-grooming skill: it changes DevStride data only, never the repo. If the user also wants code changes, that's a separate `/devstride:build-item` run AFTER this item exists.

## 0. Resolve the parent and read the plan

- **First, require enough to act on.** If `$ARGUMENTS` carries no real description of the work (just an item number, or an empty/vague invocation), STOP and ask the user what the story actually is before creating or splicing anything — do NOT invent one.
- If `$ARGUMENTS` contains an item number (`I#####`), that is the anchor — `get_item(view:"full")` it, and resolve the org's REAL container/leaf work type names via `get_work_type_hierarchy` to classify it (never assume the literal Capability/Epic/Story names). If it's a top-level container (this org's Module), you'll need to find/create a housing container at the level below (step 2). If it's already a lower-level container (this org's Capability or Epic), it IS the direct parent.
- If no item number is given, ask the user which parent item (any grouping level — this org:
  Module/Capability/Epic) this story belongs to — do NOT guess at a plan to insert into.
- Pull the full descendant tree under the resolved anchor with `search_items` (hierarchy=[anchor], itemType=workitem, no `isDone` filter, limit 200) to see the current shape: which children are containers and which are executable leaves (this org: Capabilities/Epics vs Stories/Defects), their lanes, and their dates.
- For each candidate container in that tree, fetch its `blocked_by`/`blocks` relationships (`get_item(view:"full", fields:["number","relationships"])`) — for a big tree, fan this out with a `Workflow` (chunks of ~10 items/agent) rather than serial reads.

## 1. Understand where the loop currently is

- Identify the item `/devstride:build-item` would pick up NEXT — the **next-unblocked story** per the canonical rule in `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/next-unblocked.md` (apply it, projection warning included). Call it `NEXT`.
- Identify what is currently In Progress or most-recently-Done — this is the upstream anchor the new story will attach after.
- If the tree is ambiguous (multiple parallel unblocked candidates, or no clear critical path), summarize what you found and ask the user which slot to insert before, rather than guessing.

## 2. Find or create the housing container (this org: Capability/Epic)

- If the resolved anchor from step 0 is already a suitable lower-level container (this org's Capability or Epic), use it directly — skip to step 3.
- Otherwise (anchor is a top-level container, or no anchor was resolvable to a suitable container), look for an existing housing container under the root whose theme genuinely matches the new story (read titles/descriptions — don't force a mismatched fit). When creating one, create EVERY intermediate container level the org's `parentWorkTypeId` chain requires between the anchor and the leaf — the backend rejects skipped tiers.
- If none fits, create one: `create_item` with the container workType sibling containers already use under this root — resolved from the org's real type names via `get_work_type_hierarchy` (this org: `Capability` or `Epic`); ask if genuinely unclear — as the LAST child of the root, with `startDate` and `dueDate` both set to **today**. Give it a title that describes the surgical scope (e.g. "Webhook intake hardening"), not a generic placeholder.
- This new container becomes the direct parent for the story.

## 3. Create the story

- `create_item` — workType = the org's story-flavored leaf type resolved via `get_work_type_hierarchy` (this org: `Story`), `parentNumber` = the container resolved/created in step 2, `title`/`description` from `$ARGUMENTS` (write a real one-paragraph spec, not just the raw argument text — this is what `ultracode-build` will validate against later). Create the title WITHOUT its execution-order prefix for now — the prefix depends on the `UPSTREAM`/`NEXT` neighbours pinned in step 4, so it is assigned there.
- Set `startDate` = today, `dueDate` = today as a placeholder. (A single insert is not a full cascade; if the plan's dates should be re-compressed around the new item, run `/devstride:rationalize-gantt` on the plan root afterward — see step 5.)
- **Set the new story's priority to at least `NEXT`'s priority.** Priority is an org-specific `priorityId`, not a comparable string — resolve the org's priority collection/rank order with `get_workspace_context` first (the same non-canonical-config caveat `plan` step 0 calls out), then pick a `priorityId` ranked at or above `NEXT`'s. This matters for candidates OTHER than `NEXT` itself: within the SAME open container, or against any other still-open container dated no later than this one, a default-priority insert can lose a tie it should win. It does NOT need to out-rank `NEXT` — the relationship splice in step 4 removes `NEXT` from eligibility outright, independent of priority.
- **Priority alone cannot beat an EARLIER-dated open container** — see the worked consequence in `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/next-unblocked.md`. Step 5 verifies this explicitly — don't assume the priority bump alone guarantees "picked up NEXT."

## 4. Splice it into the dependency chain (insert-before, chain intact)

- **Before wiring any edge, confirm the organization-wide dependency auto-scheduler is OFF** — apply the canonical Enable Link Mode rule in `${CLAUDE_PLUGIN_ROOT}/skills/rationalize-gantt/references/auto-scheduler-off.md` now (check, probe-date verification when needed, never change the setting automatically).
- Let `NEXT` = the item identified in step 1 as what `/devstride:build-item` would currently pick up next (if the loop currently has nothing unblocked/open, `NEXT` is undefined — skip straight to attaching only the upstream side below).
- Let `UPSTREAM` = whatever `NEXT` was `blocked_by` before this insertion (the last-completed/in-progress item on that path). If `NEXT` had no upstream dependency (it was the true root of the chain), `UPSTREAM` is undefined.
  - **If `NEXT` itself is undefined, FIRST establish why** — an undefined `NEXT` does NOT by itself mean the plan is finished. The canonical selector also returns nothing when every open leaf is blocked (a dependency cycle, or a chain whose head never cleared) or when the remaining candidates are all gated on a human/infra decision. **Count the open leaves.**
    - **Zero open leaves — a genuinely completed plan being extended:** fall back to the **most-recently-Done item step 1 already identified** as the upstream anchor and attach the new story after it. This is the ONLY case where `UPSTREAM` comes from step 1 rather than from `NEXT`'s edges.
    - **Open leaves exist but none is selectable — STOP and surface it.** Do not apply the fallback: wiring the new story to an unrelated Done item would make it independently eligible and quietly paper over a blocked or cyclic plan, which is a problem the operator needs told about, not routed around. Report what is blocking (and run `/devstride:rationalize-gantt` on the root if it looks like a cycle), then ask where this story belongs.
  - **Why this matters, and why it fails quietly:** skipping the fallback drops through to the "neither exists" branch below and creates a story with ZERO dependency edges. Nothing errors. But an item with no `[N]` prefix AND no `blocked_by`/`blocks` edges is exactly what `build-item`'s one-off heuristic matches, so the loop classifies the new story as an unplanned one-off and ships it STRAIGHT TO THE BASE BRANCH, bypassing the plan's integration branch entirely. It also cannot be numbered relative to the previous final item, because it has no neighbour to number against.
  - *Worked example:* a plan whose items `[1]`-`[8]` are all Done. `NEXT` is undefined; step 1 identified `[8]` as the most-recently-Done item. Wire `blocked_by` from the new story to `[8]`, and number it **`[8.1]`** — the canonical convention's "after the LAST item with no `NEXT`" case. It stays a DOTTED sub-number, not `[9]`: the integer sequence is reserved for `/devstride:plan`'s extend-path authoring, so taking `[9]` here would collide with the next item that pass mints, and dotted prefixes are what mark an item as spliced in rather than planned.
- Wire relationships with `add_relationship` / `remove_relationship` (or `bulk_update_items` `workItemRelationships` for multiple edges at once), omitting `staticMode` from every write per `${CLAUDE_PLUGIN_ROOT}/skills/rationalize-gantt/references/auto-scheduler-off.md`.
  - If `UPSTREAM` exists: add `blocked_by` from the NEW story → `UPSTREAM`.
  - If `NEXT` exists: remove the old `UPSTREAM → NEXT` edge (if any) and add `blocked_by` from `NEXT` → the NEW story. This makes the new story sit immediately upstream of `NEXT`, preserving the rest of the chain.
  - If neither `UPSTREAM` nor `NEXT` exists — which after the fallback above means a genuinely EMPTY plan, with no Done items either — no relationship wiring is needed; the new story simply IS the next thing. A plan that merely has nothing OPEN does not reach this branch.
- Do NOT touch dates/relationships on anything outside this immediate splice point — this skill inserts one item, it does not re-rationalize the whole plan (`rationalize-gantt` is the tool for that).

## 4.5 Assign the execution-order number

- Per the CANONICAL NUMBERING CONVENTION — `${CLAUDE_PLUGIN_ROOT}/skills/plan/references/execution-order-numbering.md` — assign the new story a dotted sub-number using that file's splice arithmetic (worked cases included): read the current prefixes off `UPSTREAM`'s and `NEXT`'s titles, do NOT recompute the whole plan, and NEVER renumber the neighbours.
- Apply it by prefixing the title via `update_item` (`title`), leaving the rest of the title from step 3 intact.
- **If the plan is UNNUMBERED** (the neighbours have no bracketed prefixes), apply that file's unnumbered-plan handling: skip the prefix and say so in the report.

## 5. Verify + report

- `get_item` the new story back and confirm: correct parent, execution-order prefix sorts between its neighbours (step 4.5), `blocked_by`/`blocks` edges match the splice, dates = today/today, lane = default (not started).
- **Re-derive what `/devstride:build-item` would actually pick next** — re-apply the canonical next-unblocked rule (`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/next-unblocked.md`, worked consequence included) against the current plan state (including the new item) rather than assuming the splice worked. If the re-derivation picks some OTHER story than the new insert, tell the user plainly (don't silently claim success); they may want to raise this container's dates or accept the new item lands later in the queue than "immediately next."
- If the organization-wide Enable Link Mode is ON, dependents may have been forward-rescheduled once the new `blocked_by` edge landed (mechanism: `${CLAUDE_PLUGIN_ROOT}/skills/rationalize-gantt/references/auto-scheduler-off.md`) — warn the user to disable it in Settings → Organization if the new item's dependents got pushed out unexpectedly.
- Report: the new item number/title (including its assigned execution-order prefix, or a note that
  the plan is unnumbered), its parent item (created or reused), the upstream/downstream splice, and
  whether `/devstride:build-item next` will actually pick it up next (per the re-derivation above).

IMPORTANT:
- Never invent a parent item for the plan — if step 0 can't resolve one, ask.
- Never fabricate a fake historical context in the description (no "this was always planned" language) — write the real, honest spec for the work.
- This skill does not run any of the build loop — it only inserts the item. Hand off to `/devstride:build-item` (or `/devstride:build-item <new-item-number>`) separately to actually build it.
