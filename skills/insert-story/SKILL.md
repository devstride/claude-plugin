---
name: insert-story
description: Insert a new Story into a live DevStride roadmap, spliced into the dependency chain and dated for the build-item loop
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

**Goal.** Insert a NEW Story (the one-day leaf role — this org's Story type) into a live DevStride roadmap, spliced into the dependency chain and dated so the `/devstride:build-item` loop picks it up NEXT. Its POSITION looks native to the plan; its DESCRIPTION stays an honest spec of the real work. It is also the path `build-item` step 6.5 uses to turn discovered scope into tracked, dependency-ordered work; a review finding worth filing goes to `/devstride:create-defect` DEFERRED instead.

Argument — free text describing the story, optionally with a parent item number at any grouping level (this org: Module/Capability/Epic — e.g. `I20100 add rate limiting to webhook intake`, or just `add rate limiting to webhook intake`): $ARGUMENTS

## Rules that must hold

- **The procedure is `${CLAUDE_PLUGIN_ROOT}/skills/plan/references/splice-mechanics.md`**, steps 0–5 in order, with `<leaf>` = Story. The steps below carry only what is Story-specific.
- **DevStride MCP writes are PRODUCTION, immediately** — every `create_item` / `update_item` / `add_relationship` / `remove_relationship` is a real, user-visible change to the live plan. There is no draft mode.
- **Item numbers are looked up, never composed.** Use only numbers read back from the API — the one `create_item` returns for the new story, and the parent/neighbour numbers you fetched.
- **Name the fields your logic reads.** `search_items` and default projections omit `relationships` and `description`; request them (`view:"full"`, `fields:[...]`) and never read their absence as "none".
- **The organization-wide auto-scheduler must be OFF before any date or edge write** — read `enableStaticMode` first, never flip it, omit `staticMode` from every write: `${CLAUDE_PLUGIN_ROOT}/skills/rationalize-gantt/references/auto-scheduler-off.md` (steps 4 and 5).
- **The consuming repo's `.claude/ds-config.json` wins** over any inline default here for `hierarchyRoles` and branch settings; work-type NAMES come from the org at runtime (`get_work_type_hierarchy`), `hierarchyRoles` only disambiguating.
- Gantt grooming only: DevStride data, never the repo. Code changes are a separate `/devstride:build-item` run AFTER the item exists.

## Steps (Story-specific parts)

0. **Resolve + read.** Require a real description of the work; a bare item number or vague invocation → STOP and ask what the story actually is. No parent given → ask which one; never guess.
1. **Where the loop is.** `NEXT` per `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/next-unblocked.md`.
2. **Housing container.** Reuse one whose theme genuinely matches the new story, else create it (splice-mechanics step 2).
3. **Create the story.** workType = the org's story-flavored leaf type via `get_work_type_hierarchy` (this org: `Story`); description = an honest one-paragraph spec. Priority at least `NEXT`'s; priority alone cannot beat an earlier-dated open container (`next-unblocked.md`).
4. **Splice** per splice-mechanics step 4, auto-scheduler check first.
4.5. **Number** per `${CLAUDE_PLUGIN_ROOT}/skills/plan/references/execution-order-numbering.md` — dotted sub-number between `UPSTREAM`'s and `NEXT`'s prefixes; never renumber the neighbours; unnumbered plan → no prefix, say so.
5. **Verify + report** per splice-mechanics step 5, including the re-derived next pick (`next-unblocked.md`) and the Enable Link Mode warning (`auto-scheduler-off.md`).

## Hard floors

- Never invent a parent item; if step 0 cannot resolve one, ask.
- Never fabricate historical context (no "this was always planned") — write the real, honest spec.
- This skill only inserts. Build it separately with `/devstride:build-item <new-item-number>`.
