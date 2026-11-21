---
load: contract
---
# rebalance-report — Report the re-sliced plan and the next item the build loop will pick

`plan-steps`'s `rebalance-report@1` step. Report the re-sliced plan and the next item the build loop will pick.

## Verdict

`REBALANCE REPORT: RE-SLICED <counts> | FAILED [<reason>]`

## Procedure

Requires `rationalize-gantt@1` (the runner refuses the step without a fresh proof of each). Follow
`${CLAUDE_PLUGIN_ROOT}/skills/rebalance/SKILL.md`, step 4, whole and in its order. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

## Result

After the verdict and its evidence, one fenced `json` block with `before`, `after`, `next`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `rebalance-report@1` dispatch.
