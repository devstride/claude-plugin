---
load: contract
---
# plan-orient — Resolve the plan root, its delivery profile and the organization's shape

`plan-steps`'s `plan-orient@1` step. Resolve the plan root, its delivery profile and the organization's shape.

## Verdict

`PLAN ORIENTATION: READY <root> | NEEDS ANSWER <question> | FAILED [<reason>]`

## Procedure

Requires nothing (the runner refuses the step without a fresh proof of each). Follow
`${CLAUDE_PLUGIN_ROOT}/skills/plan/SKILL.md`, step 0 (orient: ticket, parent, delivery profile, the organization's type names), whole and in its order. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

## Result

After the verdict and its evidence, one fenced `json` block with `root`, `workType`, `profile`, `profileSource`, `profileInherited`, `ticket`, `releaseUnitLevel`, `roles`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `plan-orient@1` dispatch.
