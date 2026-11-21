---
load: contract
---
# rebalance-proposal — Propose the merges or splits and wait for 'yes, rebalance'

`plan-steps`'s `rebalance-proposal@1` step. Propose the merges or splits and wait for 'yes, rebalance'.

## Verdict

`REBALANCE PROPOSAL: SIGNED OFF | DRY RUN | DECLINED`

## Procedure

Requires `rebalance-partition@1` (the runner refuses the step without a fresh proof of each). Follow
`${CLAUDE_PLUGIN_ROOT}/skills/rebalance/SKILL.md`, step 2 (the proposal and the explicit "yes, rebalance"), whole and in its order. It is an **interactive** step (`interactive: true`): it may hold a conversation with the person inside the step, asking product and shape questions, and reports waiting while it waits. It never asks a flow question; the loop owns those. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

## Result

After the verdict and its evidence, one fenced `json` block with `proposal` and a `proof` object with `kind`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `rebalance-proposal@1` dispatch.
