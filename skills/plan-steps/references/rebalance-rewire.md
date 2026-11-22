---
load: contract
---
# rebalance-rewire — Move every absorbed item's edges to its successor, adding before removing

`plan-steps`'s `rebalance-rewire@1` step. Move every absorbed item's edges to its successor, adding before removing.

## Verdict

`REBALANCE REWIRE: DONE <edges> | ORPHANS <numbers> | FAILED [<reason>]`

## Procedure

Requires `rebalance-successors@1` (the runner refuses the step without a fresh proof of each). Follow
the procedure below and `${CLAUDE_PLUGIN_ROOT}/skills/rebalance/references/recoverable-write-order.md`, whole and in its order. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

**Approved text only.** Write the proposal exactly as this conversation holds it approved; if it no
longer does (a new session, a compaction), answer `FAILED approval not in this conversation`
and write nothing, never rebuilding it.

- **3b. Re-wire** — fetch every absorbed item's edges NOW with
  `get_item(view:"full", fields:["number","relationships"])`, never from the step-1 snapshot.
  Internal edges (both ends in one absorbed set) vanish; the successor inherits the **UNION of the
  external edges** in both directions — edges to Done items included (satisfied prerequisites keep
  the history honest). **Translate BOTH endpoints through the global absorbed → successor map**
  (a split: FIRST part on the `blocked_by` side, LAST part as a target), de-duplicate, and write only
  edges between two live items. A split's parts chain serially in seam order unless the proposal
  marked them parallel (then each carries both sides). Write with `add_relationship` or
  `bulk_update_items` `workItemRelationships` (`addedRelationships`, each `{type:"blocked_by",
  entity:"workitem", referenceId}`), THEN remove every edge still touching an absorbed original,
  both directions — archiving does not detach edges; add before remove, so no live item is ever
  edgeless. **Orphan gate — hard, exactly as in `plan` step 5**: re-read the edges of EVERY still-live
  not-started leaf (successors + untouched; fan out for a large tree) and assert each has ≥ 1
  `blocked_by` OR `blocks` edge; absorbed originals and deferred-container members are excluded
  (deliberately edgeless).
  Do not proceed to 3c with one standing.

## Result

After the verdict and its evidence, one fenced `json` block with `orphans` and a `proof` object with `kind`, `orphans`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `rebalance-rewire@1` dispatch.
