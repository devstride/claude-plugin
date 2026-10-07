---
load: contract
---
# Splice mechanics — inserting one leaf into a live plan — CANONICAL

The single authoritative procedure for splicing ONE new leaf (this org's Story or Defect) into a
live plan's dependency chain so `/devstride:build-item` picks it up next. `insert-story` and
`insert-defect` apply it by citation, step for step (their step numbers match the headings
below), and state only what differs by leaf type. `<leaf>` below means the item being inserted.
Numbering is NOT restated here — it lives in `execution-order-numbering.md`.

## Step 0 — resolve the parent and read the plan

- The skill defines what "enough to act on" is; without it, STOP and ask — never invent the work.
- An `I#####` in the arguments is the anchor: `get_item(view:"full")` it and classify it against
  the org's REAL container/leaf work type names from `get_work_type_hierarchy` (never assume the
  literal Capability/Epic/Story/Defect names). A top-level container (this org's Module) needs a
  housing container below it (step 2); a lower-level container (this org's Capability or Epic)
  IS the direct parent. No anchor → ask which parent item; never guess a plan to insert into.
- Pull the descendant tree: `search_items` (hierarchy=[anchor], itemType=workitem, no `isDone`
  filter, limit 200) — containers vs executable leaves, their lanes, their dates.
- `search_items` and default `get_item` projections OMIT `relationships`. For each candidate
  container fetch `blocked_by`/`blocks` explicitly with
  `get_item(view:"full", fields:["number","relationships"])`; for a big tree fan this out with a
  `Workflow` (chunks of ~10 items/agent) rather than serial reads.

## Step 1 — where the loop currently is

- `NEXT` = the next-unblocked item per `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/next-unblocked.md`
  (projection warning included).
- The In Progress, most recently landed or most-recently-Done item is the upstream anchor the
  `<leaf>` attaches after (landed: in the merged status or carrying the landed comment, not yet
  Done — `next-unblocked.md`).
- Ambiguous tree (several parallel unblocked candidates, no clear critical path) → summarize what
  you found and ask which slot to insert before.

## Step 2 — find or create the housing container (this org: Capability/Epic)

- **`NEXT`'s release unit already holds landed leaves → house the `<leaf>` in THAT release unit**,
  whatever the theme or step 0's anchor (the user named another → say why and ask). Housed
  elsewhere, between a landed leaf and `NEXT`, it waits on that unit's release while the unit waits
  on it: a release-unit cycle (`next-unblocked.md`).
- A suitable lower-level anchor from step 0 is used directly.
- Otherwise look for an existing container under the root whose theme GENUINELY matches (read
  titles/descriptions — never force a mismatched fit).
- None fits → `create_item` with the container workType sibling containers already use under
  this root (resolved via `get_work_type_hierarchy`; ask if genuinely unclear), as the LAST child
  of the root, `startDate` = `dueDate` = today, titled for the surgical scope (e.g. "Webhook
  intake hardening"), never a placeholder. Create EVERY intermediate container level the org's
  `parentWorkTypeId` chain requires between anchor and leaf — the backend rejects skipped tiers.

## Step 3 — create the leaf

- `create_item`: workType = the skill's leaf type resolved via `get_work_type_hierarchy`;
  `parentNumber` = the step-2 container; `title`/`description` = a real one-paragraph spec, not
  the raw argument text (this is what `ultracode-build` validates against). Title WITHOUT its
  execution-order prefix — that depends on the neighbours step 4 pins.
- `startDate` = `dueDate` = today as a placeholder. One insert is not a cascade; to re-compress
  the plan's dates around it, run `/devstride:rationalize-gantt` on the root afterward.
- **Priority at least `NEXT`'s.** `priorityId` is org-specific, not a comparable string — resolve
  the rank order with `get_workspace_context` first (the non-canonical-config caveat of `plan`
  step 0), then pick one ranked at or above the target. It matters for candidates OTHER than
  `NEXT`: in the SAME open container, or any other open container dated no later, a
  default-priority insert can lose a tie it should win. It need not out-rank `NEXT` — the step-4
  splice removes `NEXT` from eligibility regardless of priority.
- **Priority alone cannot beat an EARLIER-dated open container** (worked consequence in
  `next-unblocked.md`). Step 5 verifies; never assume the bump guarantees "picked up NEXT".

## Step 4 — splice into the chain (insert-before, chain intact)

- **Before any edge write, confirm the organization-wide auto-scheduler is OFF** per
  `${CLAUDE_PLUGIN_ROOT}/skills/rationalize-gantt/references/auto-scheduler-off.md` (read
  `enableStaticMode`, probe when needed, never change the setting automatically).
- `UPSTREAM` = what `NEXT` was `blocked_by` before the insert; undefined when `NEXT` was the true
  root of the chain.
- **`NEXT` undefined — FIRST establish why.** It does not by itself mean the plan is finished: the
  selector also returns nothing when every open leaf is blocked (a cycle, or a head that never
  cleared) or gated on a human/infra decision. **Count the open leaves** — neither Done nor
  landed.
  - **Zero open leaves** (a completed plan being extended): `UPSTREAM` = the most recently landed
    or Done item step 1 identified. The ONLY case where `UPSTREAM` comes from step 1, not
    `NEXT`'s edges.
  - **Open leaves exist but none is selectable — STOP and surface it.** Never apply the fallback:
    wiring to an unrelated Done item makes the `<leaf>` independently eligible and papers over a
    blocked or cyclic plan. Report what blocks (run `/devstride:rationalize-gantt` on the root if
    it looks like a cycle), then ask where the `<leaf>` belongs.
  - **Why it fails quietly:** skipping the fallback creates a leaf with ZERO dependency edges and
    nothing errors — but no `[N]` prefix AND no `blocked_by`/`blocks` edges is exactly what
    `build-item`'s one-off heuristic matches, so it ships STRAIGHT TO THE BASE BRANCH, bypassing
    the plan's integration branch, and has no neighbour to number against.
  - *Worked example:* `[1]`-`[8]` all Done → wire `blocked_by` to `[8]`, number it **`[8.1]`**.
    Dotted, not `[9]`: the integer sequence is reserved for `/devstride:plan`'s extend-path
    authoring (taking `[9]` collides with the next item that pass mints), and a dotted prefix is
    what marks an item as spliced in rather than planned.
- Wire with `add_relationship` / `remove_relationship` (or `bulk_update_items`
  `workItemRelationships` for several edges), omitting `staticMode` from every write:
  - `UPSTREAM` exists → add `blocked_by` from the NEW `<leaf>` → `UPSTREAM`.
  - `NEXT` exists → remove the old `UPSTREAM → NEXT` edge (if any) and add `blocked_by` from
    `NEXT` → the NEW `<leaf>`, so it sits immediately upstream of `NEXT`, rest of chain intact.
  - Neither exists — after the fallback that means a genuinely EMPTY plan, no Done items either —
    no wiring; the `<leaf>` simply IS next. A plan with merely nothing OPEN never reaches here.
- Touch no dates or relationships outside this splice point — whole-plan re-rationalizing is
  `rationalize-gantt`'s job.

## Step 4.5 — execution-order number

Apply `${CLAUDE_PLUGIN_ROOT}/skills/plan/references/execution-order-numbering.md` splice
arithmetic (read the neighbours' current prefixes; never recompute the plan; never renumber a
neighbour), then prefix the title via `update_item` (`title`), keeping the step-3 title intact.
Unnumbered plan → that file's handling: no prefix, and say so in the report.

## Step 5 — verify and report

- `get_item` the `<leaf>` back: correct parent, prefix sorts between its neighbours, edges match
  the splice, dates today/today, lane = default (not started).
- **Re-derive what `build-item` would actually pick next** with `next-unblocked.md` (worked
  consequence included) against the current plan, never assuming the splice worked. If it picks
  something else, say so plainly — the user may raise the container's dates or accept a later slot.
- If Enable Link Mode is ON, dependents may have been forward-rescheduled when the edge landed
  (`auto-scheduler-off.md`) — warn the user to disable it in Settings → Organization.
- Report: number/title with its prefix (or the unnumbered note), the parent (created or reused),
  the upstream/downstream splice, and whether `/devstride:build-item next` will pick it up next.

## Hard floors

- DevStride data only, never the repo; this inserts the item and does not build it — hand off to
  `/devstride:build-item <new-item-number>` separately.
- Never invent a parent — if step 0 cannot resolve one, ask.
- Never fabricate history ("this was always planned") — the position looks native to the plan;
  the description stays an honest account of the real work.

## Cited by

- `insert-story` SKILL.md steps 0–5
- `insert-defect` SKILL.md steps 0–5
