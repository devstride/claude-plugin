---
load: contract
---
# rebalance-successors — Create each merged story with the original specs preserved

`plan-steps`'s `rebalance-successors@1` step. Create each merged story with the original specs preserved.

## Verdict

`REBALANCE SUCCESSORS: CREATED <count> | FAILED [<reason>]`

## Procedure

Requires `rebalance-probe@1` (the runner refuses the step without a fresh proof of each). Follow
`${CLAUDE_PLUGIN_ROOT}/skills/rebalance/SKILL.md`, step 3a, whole and in its order. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

## Result

After the verdict and its evidence, one fenced `json` block with `map`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `rebalance-successors@1` dispatch.
