---
load: contract
---
# rebalance-archive — Archive the originals only after their successors have edges

`plan-steps`'s `rebalance-archive@1` step. Archive the originals only after their successors have edges.

## Verdict

`REBALANCE ARCHIVE: ARCHIVED <count> | FAILED [<reason>]`

## Procedure

Requires `rebalance-renumber@1` (the runner refuses the step without a fresh proof of each). Follow
the procedure below and `${CLAUDE_PLUGIN_ROOT}/skills/rebalance/references/recoverable-write-order.md`, whole and in its order. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

- **3d. Archive the absorbed originals** — only now, one item at a time: `add_comment` (`Absorbed
  into I<successor> by /devstride:rebalance on <YYYY-MM-DD>; spec preserved there.` — a split names
  every part), then immediately `archive_item`. **NEVER `delete_item`**: an archived item keeps its
  number, history and comments; a deleted one leaves every reference to it dangling.

## Result

After the verdict and its evidence, one fenced `json` block with `archived`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `rebalance-archive@1` dispatch.
