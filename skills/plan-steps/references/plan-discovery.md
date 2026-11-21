---
load: contract
---
# plan-discovery — Ask the questions that change the shape, until the person says 'yes, build this'

`plan-steps`'s `plan-discovery@1` step. Ask the questions that change the shape, until the person says 'yes, build this'.

## Verdict

`PLAN SHAPE: SIGNED OFF | SIGNED OFF WITH ASSUMPTIONS | NOT SIGNED OFF [<reason>]`

## Procedure

Requires `plan-orient@1`, `plan-ground@1` (the runner refuses the step without a fresh proof of each). Follow
`${CLAUDE_PLUGIN_ROOT}/skills/plan/SKILL.md`, step 2 (the discovery loop, the skip pushback and the explicit "yes, build this"), whole and in its order. It is an **interactive** step (`interactive: true`): it may hold a conversation with the person inside the step, asking product and shape questions, and reports waiting while it waits. It never asks a flow question; the loop owns those. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

## Result

After the verdict and its evidence, one fenced `json` block with `tree`, `sequencing`, `assumptions`, `deferredContainer`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `plan-discovery@1` dispatch.
