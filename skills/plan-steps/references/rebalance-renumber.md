---
load: contract
---
# rebalance-renumber — Give each successor the number slot of its first absorbed item

`plan-steps`'s `rebalance-renumber@1` step. Give each successor the number slot of its first absorbed item.

## Verdict

`REBALANCE RENUMBER: DONE <range> | UNNUMBERED PLAN KEPT | FAILED [<reason>]`

## Procedure

Requires `rebalance-rewire@1` (the runner refuses the step without a fresh proof of each). Follow
the procedure below and `${CLAUDE_PLUGIN_ROOT}/skills/rebalance/references/recoverable-write-order.md`, whole and in its order. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

- **3c. Number** — per the CANONICAL NUMBERING CONVENTION,
  `${CLAUDE_PLUGIN_ROOT}/skills/plan/references/execution-order-numbering.md`, and nothing else:
  each successor takes a dotted sub-number in the slot of its FIRST (lowest-prefixed) absorbed item
  — `UPSTREAM`/`NEXT` are the nearest still-live numbered leaves before and after it (absorbed items
  are leaving, not neighbours) — via that file's splice arithmetic; a split's parts take successive
  sub-numbers in seam order. **Existing items are never renumbered** — read neighbours' prefixes off
  their titles; never recompute the plan. Apply with `update_item` or
  chunked `bulk_update_items` (`title`), keeping the rest of the title. An unnumbered plan stays
  unnumbered (that file's handling; say so; never mix).

## Result

After the verdict and its evidence, one fenced `json` block with `range`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `rebalance-renumber@1` dispatch.
