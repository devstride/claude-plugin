---
load: contract
---
# plan-wire — Wire the dependency edges and prove no new leaf is left without one

`plan-steps`'s `plan-wire@1` step. Wire the dependency edges and prove no new leaf is left without one.

## Verdict

`PLAN WIRED: WIRED <edges> | ORPHANS <numbers> | FAILED [<reason>]`

## Procedure

Requires `plan-create@1` (the runner refuses the step without a fresh proof of each). Follow
`${CLAUDE_PLUGIN_ROOT}/skills/plan/SKILL.md`, step 5 (the true shape and the zero-orphan gate), whole and in its order. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

## Result

After the verdict and its evidence, one fenced `json` block with `orphans` and a `proof` object with `kind`, `orphans`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `plan-wire@1` dispatch.
