---
name: insert-defect
description: Insert a new Defect into a live DevStride roadmap, spliced into the dependency chain and dated for the build-item loop
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

**Goal.** Insert a NEW Defect (the one-day leaf role — this org's Defect type) into a live DevStride roadmap, spliced into the dependency chain and dated so the `/devstride:build-item` loop picks it up NEXT. Its POSITION looks native to the plan; its DESCRIPTION stays an honest repro/root-cause of the real bug. `build-item` step 6.5 never uses it: a review finding worth filing goes to `/devstride:create-defect` DEFERRED, beside the chain, never into it.

Argument — free text describing the defect, optionally with a parent item number at any grouping level (this org: Module/Capability/Epic — e.g. `I20100 webhook retries duplicate on 429`, or just `webhook retries duplicate on 429`): $ARGUMENTS

## Rules that must hold

- **The procedure is `${CLAUDE_PLUGIN_ROOT}/skills/plan/references/splice-mechanics.md`**, steps 0–5 in order, with `<leaf>` = Defect. The steps below carry only what is Defect-specific.
- **DevStride MCP writes are PRODUCTION, immediately** — every `create_item` / `update_item` / `add_relationship` / `remove_relationship` is a real, user-visible change to the live plan. There is no draft mode.
- **Item numbers are looked up, never composed.** Use only numbers read back from the API — the one `create_item` returns for the new defect, and the parent/neighbour numbers you fetched.
- **Name the fields your logic reads.** `search_items` and default projections omit `relationships` and `description`; request them (`view:"full"`, `fields:[...]`) and never read their absence as "none".
- **The organization-wide auto-scheduler must be OFF before any date or edge write** — read `enableStaticMode` first, never flip it, omit `staticMode` from every write: `${CLAUDE_PLUGIN_ROOT}/skills/rationalize-gantt/references/auto-scheduler-off.md` (steps 4 and 5).
- **The consuming repo's `.claude/ds-config.json` wins** over any inline default here for `hierarchyRoles` and branch settings; work-type NAMES come from the org at runtime (`get_work_type_hierarchy`), `hierarchyRoles` only disambiguating.
- Gantt grooming only: DevStride data, never the repo. Code changes are a separate `/devstride:build-item` run AFTER the item exists.

## Steps (Defect-specific parts)

0. **Resolve + read.** Require a real description of the bug; a bare item number or vague invocation → STOP and ask for the repro and expected-vs-actual behavior. No parent given → ask which one; never guess.
1. **Where the loop is.** `NEXT` per `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/next-unblocked.md`. **Queue jump:** a defect often warrants jumping ahead of already-planned stories (it blocks something real). If so, say so explicitly and CONFIRM with the user before splicing it earlier than a plain "next" insertion — never silently reprioritize. When it jumps, the item it must precede takes `NEXT`'s place in the splice.
2. **Housing container.** A defect often belongs under whichever container owns the broken behavior, even if that container is otherwise "done" — reopening its slot is fine. Otherwise reuse a genuinely matching container or create one (splice-mechanics step 2).
3. **Create the defect.** workType = the org's defect-flavored leaf type via `get_work_type_hierarchy` (this org: `Defect`); description = an honest one-paragraph repro/root-cause spec — capture repro steps and expected-vs-actual if the user supplied enough, otherwise ask. Priority at least `NEXT`'s — and, when it jumps the queue, above the sibling it must precede; priority alone cannot beat an earlier-dated open container (`next-unblocked.md`).
4. **Splice** per splice-mechanics step 4, auto-scheduler check first.
4.5. **Number** per `${CLAUDE_PLUGIN_ROOT}/skills/plan/references/execution-order-numbering.md` — its queue-JUMP case applies to a defect that must precede the current `NEXT`; read the neighbours' prefixes; never renumber them; unnumbered plan → no prefix, say so.
5. **Verify + report** per splice-mechanics step 5, including the re-derived next pick (`next-unblocked.md`) and the Enable Link Mode warning (`auto-scheduler-off.md`).

## Hard floors

- Never invent a parent item; if step 0 cannot resolve one, ask.
- Never fabricate historical context (no "this was always planned") — write the real, honest repro/root-cause.
- This skill only inserts. Build it separately with `/devstride:build-item <new-item-number>`.
