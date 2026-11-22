---
load: contract
---
# rebalance-marker — Rewrite the plan root's delivery profile line, and only that line

`plan-steps`'s `rebalance-marker@1` step. Rewrite the plan root's delivery profile line, and only that line.

## Verdict

`REBALANCE MARKER: REWRITTEN <profile> | FAILED [<reason>]`

## Procedure

Requires `rebalance-archive@1` (the runner refuses the step without a fresh proof of each). Follow
the procedure below and `${CLAUDE_PLUGIN_ROOT}/skills/rebalance/references/recoverable-write-order.md`, whole and in its order. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

**Only what was approved, from this conversation.** This step writes the proposal the person signed off with "yes, rebalance", exactly as this
conversation holds them. When it no longer holds them word for word (a run picked up in a new
session, or a compaction that summarised them), answer `FAILED approval not in this conversation`
and write nothing: never rebuild them from DevStride, memory or a summary. The person then starts
the command again, and the approval is asked for again.

- **3e. Rewrite the root marker** — `get_item(view:"full")` the root (or scoped unit), replace the
  `Delivery profile:` line (case-insensitive) or prepend one, and `update_item` the description.
  **Touch only the marker line** — the rest is the owner's. A descendant marker that now disagrees
  is rewritten only with the owner's yes. Leafless units get this marker's coverage alone; a later
  `/devstride:plan <unit>` slices them at the new grain.

## Result

After the verdict and its evidence, one fenced `json` block with `profile`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `rebalance-marker@1` dispatch.
