---
load: contract
---
# rebalance-report — Report the re-sliced plan and the next item the build loop will pick

`plan-steps`'s `rebalance-report@1` step. Report the re-sliced plan and the next item the build loop will pick.

## Verdict

`REBALANCE REPORT: RE-SLICED <counts> | FAILED [<reason>]`

## Procedure

Requires `rationalize-gantt@1` (the runner refuses the step without a fresh proof of each). Follow
the procedure below, whole and in its order. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

### 4. Report

Counts (not-started before → after, per release unit and in total; untouchables listed as
unchanged); the contract's **shape against target** line; the absorbed → successor map with numbers, prefixes and titles; archived items and the
successor each comment names; the marker written, where, any descendant markers rewritten, and the
un-extracted units it covers; the orphan-check result; unchanged leaves below target depth for a
follow-up `/devstride:plan`; and **the next-unblocked item**, re-derived per
`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/next-unblocked.md` against the re-sliced plan
(projection warning included), never assumed to be the lowest-numbered successor. Leave the plan
root in handoff project memory as it was and note the re-slice there (date, profile before →
after), so a bare `/devstride:build-item` resumes at the new grain. A dry run reports the proposal
and says plainly that nothing was written.

## Result

After the verdict and its evidence, one fenced `json` block with `before`, `after`, `next`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `rebalance-report@1` dispatch.
