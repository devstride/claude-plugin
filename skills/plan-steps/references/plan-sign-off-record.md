---
load: contract
---
# plan-sign-off-record — Record the sign-off, and nothing else, in DevStride

`plan-steps`'s `plan-sign-off-record@1` step. Record the sign-off, and nothing else, in DevStride.

## Verdict

`SIGN-OFF RECORDED: RECORDED <profile> | LINK MODE ON | FAILED [<reason>]`

## Procedure

Requires `plan-discovery@1` (the runner refuses the step without a fresh proof of each). Follow
`${CLAUDE_PLUGIN_ROOT}/skills/plan/SKILL.md`, the sign-off record: the ticket link, the root marker, start and item-days, Enable Link Mode read only, whole and in its order. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

## Result

After the verdict and its evidence, one fenced `json` block with `root`, `profile`, `start`, `itemDays`, `linkMode` and a `proof` object with `kind`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `plan-sign-off-record@1` dispatch.
