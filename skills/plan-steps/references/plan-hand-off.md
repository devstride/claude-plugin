---
load: contract
---
# plan-hand-off — Report the finished plan and where the build loop starts

`plan-steps`'s `plan-hand-off@1` step. Report the finished plan and where the build loop starts.

## Verdict

`PLAN HANDED OFF: HANDED OFF <root> | ANOTHER ROUND WANTED`

## Procedure

Requires `plan-number@1` (the runner refuses the step without a fresh proof of each). Follow
`${CLAUDE_PLUGIN_ROOT}/skills/plan/SKILL.md`, step 7 (the hand-off report), whole and in its order. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

## Result

After the verdict and its evidence, one fenced `json` block with `root`, `newCount`, `existingCount`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `plan-hand-off@1` dispatch.
