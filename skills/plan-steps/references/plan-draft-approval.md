---
load: contract
---
# plan-draft-approval — Walk the person through the drafts until they approve them

`plan-steps`'s `plan-draft-approval@1` step. Walk the person through the drafts until they approve them.

## Verdict

`PLAN DRAFT REVIEW: APPROVED | NOT APPROVED [<reason>]`

## Procedure

Requires `plan-draft@1` (the runner refuses the step without a fresh proof of each). Follow
the procedure below, whole and in its order. It is an **interactive** step (`interactive: true`): it may hold a conversation with the person inside the step, asking product and shape questions, and reports waiting while it waits. It never asks a flow question; the loop owns those. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

- Show the user a condensed review (grouping items and units in full, leaves summarized with an offer
  to expand) before any live write. Fix small corrections in place; a real undecided question loops
  back to step-2 discovery — never rerun the whole Workflow for a small fix.

## Result

After the verdict and its evidence, one fenced `json` block with `approved` and a `proof` object with `kind`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `plan-draft-approval@1` dispatch.
