---
load: contract
---
# plan-draft — Draft the specs for the signed-off shape; the drafting agents never write to DevStride

`plan-steps`'s `plan-draft@1` step. Draft the specs for the signed-off shape; the drafting agents never write to DevStride.

## Verdict

`PLAN DRAFTED: DRAFTED <counts> | FAILED [<reason>]`

## Procedure

Requires `plan-sign-off-record@1` (the runner refuses the step without a fresh proof of each). Follow
`${CLAUDE_PLUGIN_ROOT}/skills/plan/SKILL.md`, step 3 (Stage A, Stage B, Stage C, routing and the cap); `${CLAUDE_PLUGIN_ROOT}/skills/plan/references/delivery-profiles.md`, whole and in its order. It is the one **delegating** step (`delegates: true`): it may run one Workflow of drafting agents, which draft only and never call an MCP write tool.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

## Result

After the verdict and its evidence, one fenced `json` block with `draftRef`, `counts`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `plan-draft@1` dispatch.
