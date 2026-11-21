---
load: contract
---
# plan-number — Number the leaves in the order the build loop will pick them

`plan-steps`'s `plan-number@1` step. Number the leaves in the order the build loop will pick them.

## Verdict

`PLAN NUMBERED: NUMBERED <range> | EXTENDED <range> | ALREADY NUMBERED | UNNUMBERED PLAN KEPT | FAILED [<reason>]`

## Procedure

Requires `rationalize-gantt@1` (the runner refuses the step without a fresh proof of each). Follow
the procedure below and `${CLAUDE_PLUGIN_ROOT}/skills/plan/references/execution-order-numbering.md`, whole and in its order. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

### 6.5 Stamp execution-order numbers into leaf titles

With the graph wired and dated, execution order is fixed; stamp it so the plan reads in the order
`/devstride:build-item` walks it and later inserts have a stable anchor. The prefix format, splice
sub-numbering, stability guarantee and unnumbered-plan handling are the CANONICAL NUMBERING
CONVENTION, `${CLAUDE_PLUGIN_ROOT}/skills/plan/references/execution-order-numbering.md`; this step
owns only the compute-and-stamp.

- Compute the order in a script, never by eye: the order build-item's canonical next-unblocked walk
  (`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/next-unblocked.md`) would pick the leaves —
  earliest-dated open container first, then `blocked_by` topological order, then priority, then
  `startDate` as the final tie-break.
- `[1]` is the first story on that walk, incrementing along it; retitle to `[N] <existing title>`
  with `bulk_update_items` (`title`), ~22 per call. **Idempotent**: skip a title that already
  carries a bracketed prefix.
- **EXTEND path: never renumber existing items.** Number only NEW leaves — one landing at the END
  continues the integer sequence; one BETWEEN two numbers takes a dotted sub-number by the
  convention's splice arithmetic. An existing plan with no prefixes → tell the user and offer to
  number the whole tree in one pass rather than mixing numbered and unnumbered items.

## Result

After the verdict and its evidence, one fenced `json` block with `range`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `plan-number@1` dispatch.
