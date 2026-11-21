---
load: contract
---
# rebalance-partition — Separate the leaves that may be re-sliced from the ones that are untouchable

`plan-steps`'s `rebalance-partition@1` step. Separate the leaves that may be re-sliced from the ones that are untouchable.

## Verdict

`REBALANCE PARTITION: PARTITIONED <counts> | NO CHANGE NEEDED`

## Procedure

Requires `rebalance-gates@1`, `plan-ground@1` (the runner refuses the step without a fresh proof of each). Follow
`${CLAUDE_PLUGIN_ROOT}/skills/rebalance/SKILL.md`, step 1 (the partition), whole and in its order. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

## Result

After the verdict and its evidence, one fenced `json` block with `notStarted`, `untouchable`, `current`, `target`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `rebalance-partition@1` dispatch.
