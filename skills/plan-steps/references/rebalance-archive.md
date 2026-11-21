---
load: contract
---
# rebalance-archive — Archive the originals only after their successors have edges

`plan-steps`'s `rebalance-archive@1` step. Archive the originals only after their successors have edges.

## Verdict

`REBALANCE ARCHIVE: ARCHIVED <count> | FAILED [<reason>]`

## Procedure

Requires `rebalance-renumber@1` (the runner refuses the step without a fresh proof of each). Follow
`${CLAUDE_PLUGIN_ROOT}/skills/rebalance/SKILL.md`, step 3d, whole and in its order. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

## Result

After the verdict and its evidence, one fenced `json` block with `archived`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `rebalance-archive@1` dispatch.
