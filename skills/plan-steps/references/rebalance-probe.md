---
load: contract
---
# rebalance-probe — Prove the auto-scheduler will not overwrite what the rebalance writes

`plan-steps`'s `rebalance-probe@1` step. Prove the auto-scheduler will not overwrite what the rebalance writes.

## Verdict

`SCHEDULER PROBE: HELD | OVERWRITTEN | LOOP ACTIVE <item>`

## Procedure

Requires `rebalance-proposal@1` (the runner refuses the step without a fresh proof of each). Follow
`${CLAUDE_PLUGIN_ROOT}/skills/rebalance/SKILL.md`, step 3's auto-scheduler probe, whole and in its order. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

## Result

After the verdict and its evidence, one fenced `json` block with `probe`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `rebalance-probe@1` dispatch.
