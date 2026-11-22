---
load: contract
---
# rebalance-proposal — Propose the merges or splits and wait for 'yes, rebalance'

`plan-steps`'s `rebalance-proposal@1` step. Propose the merges or splits and wait for 'yes, rebalance'.

## Verdict

`REBALANCE PROPOSAL: SIGNED OFF | DRY RUN | DECLINED`

## Procedure

Requires `rebalance-partition@1` (the runner refuses the step without a fresh proof of each). Follow
the procedure below, whole and in its order. It is an **interactive** step (`interactive: true`): it may hold a conversation with the person inside the step, asking product and shape questions, and reports waiting while it waits. It never asks a flow question; the loop owns those. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

### 2. Propose — in the main conversation, before any write

Per release unit, over the not-started set only: **direction is the contract's grain order**
(current vs target `grain` row); size every successor to the TARGET `grain` row and `specDepth`.

- **Coarser → MERGE** fine siblings into successors of that size; where the target row folds
  foundation in, scaffold, CI, schema, harness and permission-wiring leaves join the FIRST value
  successor needing them. A merge set is **siblings under one release unit** (the release and
  safety boundary — never merge across it) with **no untouchable item**.
- **Finer → SPLIT** along the spec's own seams (data model / backend / frontend / testing, or one
  acceptance criterion per part), each part the target row's size with its own tests. Never invent
  work the spec lacks; no seam → it stays whole.
- **Unchanged** where the grain fits — say so. This skill never rewrites an existing leaf's
  description: one whose spec sits below the target `specDepth` is LISTED ("grain fits; spec below
  target depth") for a follow-up `/devstride:plan` pass.
- **A merge set must be convex in the dependency graph** — an outside item on a path between two
  members makes the successor both upstream and downstream of it, a cycle 3f refuses to date. Fold
  it in or split the set now (`recoverable-write-order.md`).
- **Never change a leaf's release unit or work type**; a set mixing leaf types (a Story with a
  Defect) is not merged without asking.
- **Draft successor specs** to the target `specDepth` inline, in this step, from the FULL step-1
  re-fetch (only the plan's drafting step delegates, so this step starts no drafting agents).

Show a **before/after table**: per release unit, leaf count before → after (untouchables counted
separately); every not-started leaf → its successor's draft title or "unchanged" (a split: original
→ each part); each successor's title, one-line scope and the external edges it will inherit (3b) —
a wrong edge is caught here at zero cost; the marker to be written, the un-extracted units it
covers, and any descendant marker that would now disagree.

**Require an explicit "yes, rebalance".** "Looks fine", a question or silence is not sign-off.
`--dry-run` or a decline → STOP: the proposal IS the deliverable and NOTHING is written. Fix small
corrections in place and re-show; a real scope decision goes back to the owner, never to a drafting
agent.

## Result

After the verdict and its evidence, one fenced `json` block with `proposal` and a `proof` object with `kind`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `rebalance-proposal@1` dispatch.
