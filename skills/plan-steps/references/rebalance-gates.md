---
load: contract
---
# rebalance-gates — Check that nothing else is writing to the plan and the arguments are whole

`plan-steps`'s `rebalance-gates@1` step. Check that nothing else is writing to the plan and the arguments are whole.

## Verdict

`REBALANCE GATES: CLEAR | BUILD LOOP ACTIVE <item> | SCHEDULER ON | BAD ARGUMENTS <what>`

## Procedure

Requires nothing (the runner refuses the step without a fresh proof of each). Follow
`${CLAUDE_PLUGIN_ROOT}/skills/rebalance/SKILL.md`, step 0 (the gates), whole and in its order. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

## Result

After the verdict and its evidence, one fenced `json` block with `root`, `target`, `dryRun`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `rebalance-gates@1` dispatch.
