---
load: contract
---
# rebalance-probe — Prove the auto-scheduler will not overwrite what the rebalance writes

`plan-steps`'s `rebalance-probe@1` step. Prove the auto-scheduler will not overwrite what the rebalance writes.

## Verdict

`SCHEDULER PROBE: HELD | OVERWRITTEN | LOOP ACTIVE <item>`

## Procedure

Requires `rebalance-proposal@1` (the runner refuses the step without a fresh proof of each). Follow
the procedure below and `${CLAUDE_PLUGIN_ROOT}/skills/rebalance/references/recoverable-write-order.md`, whole and in its order. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

### 3. Write — in this order, so an interruption duplicates work and never loses it

The order is load-bearing; never reorder to save calls. Chunk every bulk call to ~22 items (larger
payloads return `503`) and omit `staticMode` everywhere. **Read
`${CLAUDE_PLUGIN_ROOT}/skills/rebalance/references/recoverable-write-order.md` before the first
write, and when a run was interrupted mid-step 3.** The loop re-check comes first: re-run the
"Refuse while a build loop is active on this plan" bullet of
`${CLAUDE_PLUGIN_ROOT}/skills/plan-steps/references/rebalance-gates.md`, and answer
`LOOP ACTIVE <item>` with no write when it trips. Then run the
auto-scheduler **probe-date verification** (one `update_item` on a dependent item, read back,
restore); it is the only write before 3a, and an overwritten probe date stops the run.

## Result

After the verdict and its evidence, one fenced `json` block with `probe`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `rebalance-probe@1` dispatch.
