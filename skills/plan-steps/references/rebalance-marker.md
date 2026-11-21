---
load: contract
---
# rebalance-marker — Rewrite the plan root's delivery profile line, and only that line

`plan-steps`'s `rebalance-marker@1` step. Rewrite the plan root's delivery profile line, and only that line.

## Verdict

`REBALANCE MARKER: REWRITTEN <profile> | FAILED [<reason>]`

## Procedure

Requires `rebalance-archive@1` (the runner refuses the step without a fresh proof of each). Follow
`${CLAUDE_PLUGIN_ROOT}/skills/rebalance/SKILL.md`, step 3e, whole and in its order. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

## Result

After the verdict and its evidence, one fenced `json` block with `profile`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `rebalance-marker@1` dispatch.
