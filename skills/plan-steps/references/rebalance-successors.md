---
load: contract
---
# rebalance-successors — Create each merged story with the original specs preserved

`plan-steps`'s `rebalance-successors@1` step. Create each merged story with the original specs preserved.

## Verdict

`REBALANCE SUCCESSORS: CREATED <count> | FAILED [<reason>]`

## Procedure

Requires `rebalance-probe@1` (the runner refuses the step without a fresh proof of each). Follow
the procedure below and `${CLAUDE_PLUGIN_ROOT}/skills/rebalance/references/recoverable-write-order.md`, whole and in its order. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

**Only what was approved, from this conversation.** This step writes the proposal the person signed off with "yes, rebalance", exactly as this
conversation holds them. When it no longer holds them word for word (a run picked up in a new
session, or a compaction that summarised them), answer `FAILED approval not in this conversation`
and write nothing: never rebuild them from DevStride, memory or a summary. The person then starts
the command again, and the approval is asked for again.

- **3a. Create each successor** — `create_item` with `${CLAUDE_PLUGIN_ROOT}/skills/plan/references/splice-mechanics.md` step 3's call pattern:
  `workType` = the absorbed items' leaf type, `parentNumber` = their release unit, `startDate` =
  `dueDate` = today (placeholders), `priorityId` at or above the highest absorbed priority (an
  org-specific id — resolve the collection via `get_workspace_context`), title WITHOUT a prefix,
  `boardId` by that step's board rule. The
  `description` is the drafted spec, then a trailing collapsed **"Absorbed specs"** section with the
  FULL original description of every absorbed item, verbatim, under a sub-heading of its number and
  title:

  ```html
  <details><summary>Absorbed specs</summary>
  <h3>I20131 — Add attachment table + S3 bucket</h3>
  …that item's description, unchanged…
  </details>
  ```

  The `specDepth` cap applies to the successor's OWN spec, never this section; a split's parts each
  embed the whole original. **Read each successor back** (`get_item(view:"full")`); a stripped
  `<details>` wrapper → fall back to a plain trailing `<h2>Absorbed specs</h2>`. Record the
  `absorbed → successor` map; everything after keys off it.

## Result

After the verdict and its evidence, one fenced `json` block with `map`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `rebalance-successors@1` dispatch.
