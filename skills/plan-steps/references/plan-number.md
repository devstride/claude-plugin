---
load: contract
---
# plan-number — Number the leaves in the order the build loop will pick them

`plan-steps`'s `plan-number@1` step. Number the leaves in the order the build loop will pick them.

## Verdict

`PLAN NUMBERED: NUMBERED <range> | EXTENDED <range> | ALREADY NUMBERED | UNNUMBERED PLAN KEPT | FAILED [<reason>]`

## Procedure

Requires `rationalize-gantt@1` (the runner refuses the step without a fresh proof of each). Follow
`${CLAUDE_PLUGIN_ROOT}/skills/plan/SKILL.md`, step 6.5; `${CLAUDE_PLUGIN_ROOT}/skills/plan/references/execution-order-numbering.md`, whole and in its order. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

## Result

After the verdict and its evidence, one fenced `json` block with `range`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `plan-number@1` dispatch.
