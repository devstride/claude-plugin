---
load: contract
---
# rebalance-rewire — Move every absorbed item's edges to its successor, adding before removing

`plan-steps`'s `rebalance-rewire@1` step. Move every absorbed item's edges to its successor, adding before removing.

## Verdict

`REBALANCE REWIRE: DONE <edges> | ORPHANS <numbers> | FAILED [<reason>]`

## Procedure

Requires `rebalance-successors@1` (the runner refuses the step without a fresh proof of each). Follow
`${CLAUDE_PLUGIN_ROOT}/skills/rebalance/SKILL.md`, step 3b, whole and in its order. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

## Result

After the verdict and its evidence, one fenced `json` block with `orphans` and a `proof` object with `kind`, `orphans`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `rebalance-rewire@1` dispatch.
