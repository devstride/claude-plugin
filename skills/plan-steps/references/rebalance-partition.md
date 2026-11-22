---
load: contract
---
# rebalance-partition — Separate the leaves that may be re-sliced from the ones that are untouchable

`plan-steps`'s `rebalance-partition@1` step. Separate the leaves that may be re-sliced from the ones that are untouchable.

## Verdict

`REBALANCE PARTITION: PARTITIONED <counts> | NO CHANGE NEEDED`

## Procedure

Requires `rebalance-gates@1`, `plan-ground@1` (the runner refuses the step without a fresh proof of each). Follow
the procedure below, whole and in its order. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

### 1. Read and partition

- Use the `ground` step's **comprehend-plan** reading of the root from this run; invoke
  comprehend-plan again only when that reading is not in the conversation (a resumed session, or a
  run without the runner). Never hand-roll the tree read; deferrals, "as-built" comments and design
  decisions live in its descriptions-and-comments traversal.
- Partition every leaf into exactly one set: **Done** and **In Progress**, landed leaves (merged
  status or a "merged onto" comment, awaiting their epic's release) counted with In Progress (both
  UNTOUCHABLE; their edges are read, never rewritten) and **Not started** (the only candidates).
  Every member of the plan root's deferred container
  (`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/deferred-container.md`) is UNTOUCHABLE
  whatever its status: never merged, split, renumbered or archived here, and dated only by
  `rationalize-gantt`'s deferred pass (3f).
  Dates are not frozen: 3f re-dates every not-Done item but a landed one, In Progress included, and
  build-item's ritual stamps the real dates when it merges.
- **Current profile** — the nearest EFFECTIVE marker per the contract: the item's own, else the
  closest ancestor's (walk `hierarchy` up with `get_item(view:"full")`), else config `profile` (unknown: `standard`),
  else `extended`. On a whole-root run check every release unit for its OWN marker (it wins for its
  subtree; direction is decided per unit). **Announce both ends with sources** ("current:
  enterprise (retired: read as standard) — from the root marker on I20100; target: extended — from
  `$ARGUMENTS`"). Current
  equals target everywhere → say so and ask whether to proceed (a wrong-grain plan is a valid
  reason, but the owner's call).
- **Target knobs** — `profileOverrides` in the repo's `.claude/ds-config.json` (contract,
  "Overrides") pins `grain`/`specDepth` for every profile; slice and draft to the overridden value
  and name it in the announcement.
- **Re-fetch every candidate in full** — `get_item(view:"full")` + `list_comments` (whole thread);
  comprehend-plan's summaries are the wrong source for a successor spec or the verbatim text 3a
  embeds.
- **Record the open leaves' dates for 3f** — one evidence line, `Open-leaf dates: item-days <N>,
  earliest start <date>`: the length and earliest start the plan's open leaves have now. 3a's
  placeholders reset both, and `redate` passes them to `rationalize-gantt`.
- **Scoped to one release unit**: it is the "root" below; siblings are read (edge targets) but never
  re-sliced, and 3e's marker lands on the unit, winning for its subtree.
- Note release units with **no leaves at all** — nothing to re-slice; 3e's marker alone covers them.

## Result

After the verdict and its evidence, one fenced `json` block with `notStarted`, `untouchable`, `current`, `target`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `rebalance-partition@1` dispatch.
