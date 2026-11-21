---
load: contract
---
# plan-create — Create the approved tree top-down, only the items that are missing

`plan-steps`'s `plan-create@1` step. Create the approved tree top-down, only the items that are missing.

## Verdict

`PLAN CREATED: CREATED <count> | PARTIAL <progress> | FAILED [<reason>]`

## Procedure

Requires `plan-sign-off-record@1`, `plan-draft-approval@1` (the runner refuses the step without a fresh proof of each). Follow
`${CLAUDE_PLUGIN_ROOT}/skills/plan/SKILL.md`, step 4 (creation top-down, the deferred-work container, the board rule), whole and in its order. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

## Result

After the verdict and its evidence, one fenced `json` block with `created`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `plan-create@1` dispatch.
