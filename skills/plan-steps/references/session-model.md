---
load: contract
---
# session-model — Check the session's model against the role this workflow wants, and only report it

`plan-steps`'s `session-model@1` step. Check the session's model against the role this workflow wants, and only report it.

## Verdict

`SESSION MODEL: MATCH | UNKNOWN | OFF | MISMATCH | MISMATCH UNATTENDED | MISMATCH ANSWERED`

## Procedure

Requires nothing (the runner refuses the step without a fresh proof of each). Follow
`${CLAUDE_PLUGIN_ROOT}/skills/plan/SKILL.md`'s Session model line, the profile sentence from `${CLAUDE_PLUGIN_ROOT}/skills/plan-steps/references/plan-orient.md`; `${CLAUDE_PLUGIN_ROOT}/skills/plan/references/session-models.md`, whole and in its order. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

`MISMATCH` asks the person once, switch or carry on. When the step comes back with their reply
(` answer: <it>`), act on it as `session-models.md` says (a switch: re-run the check once and say
its result in one line) and answer `MISMATCH ANSWERED`, never `MISMATCH` again: the run carries
on either way.

## Result

After the verdict and its evidence, one fenced `json` block with `verdict`, `profileLine`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `session-model@1` dispatch.
