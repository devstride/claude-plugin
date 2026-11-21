---
load: contract
---
# plan-draft-approval — Walk the person through the drafts until they approve them

`plan-steps`'s `plan-draft-approval@1` step. Walk the person through the drafts until they approve them.

## Verdict

`PLAN DRAFT REVIEW: APPROVED | NOT APPROVED [<reason>]`

## Procedure

Requires `plan-draft@1` (the runner refuses the step without a fresh proof of each). Follow
`${CLAUDE_PLUGIN_ROOT}/skills/plan/SKILL.md`, the content review at the end of step 3, whole and in its order. It is an **interactive** step (`interactive: true`): it may hold a conversation with the person inside the step, asking product and shape questions, and reports waiting while it waits. It never asks a flow question; the loop owns those. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

## Result

After the verdict and its evidence, one fenced `json` block with `approved` and a `proof` object with `kind`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `plan-draft-approval@1` dispatch.
