---
load: contract
---
# rebalance-renumber — Give each successor the number slot of its first absorbed item

`plan-steps`'s `rebalance-renumber@1` step. Give each successor the number slot of its first absorbed item.

## Verdict

`REBALANCE RENUMBER: DONE <range> | UNNUMBERED PLAN KEPT | FAILED [<reason>]`

## Procedure

Requires `rebalance-rewire@1` (the runner refuses the step without a fresh proof of each). Follow
`${CLAUDE_PLUGIN_ROOT}/skills/rebalance/SKILL.md`, step 3c, whole and in its order. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

## Result

After the verdict and its evidence, one fenced `json` block with `range`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `rebalance-renumber@1` dispatch.
