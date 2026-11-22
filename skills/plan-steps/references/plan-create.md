---
load: contract
---
# plan-create — Create the approved tree top-down, only the items that are missing

`plan-steps`'s `plan-create@1` step. Create the approved tree top-down, only the items that are missing.

## Verdict

`PLAN CREATED: CREATED <count> | PARTIAL <progress> | FAILED [<reason>]`

## Procedure

Requires `plan-sign-off-record@1`, `plan-draft-approval@1` (the runner refuses the step without a fresh proof of each). Follow
the procedure below, whole and in its order. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

**Approved text only.** Write the plan exactly as this conversation holds it approved; if it no
longer does (a new session, a compaction), answer `FAILED approval not in this conversation`
and write nothing, never rebuilding it.

### 4. Create the items live

- Top-down, **every intermediate container level the hierarchy requires** — walk the
  `parentWorkTypeId` chain from the root's type to the leaf types and create each level in order (an
  org with `Enterprise → Epic → Feature → Story` needs the Feature tier; the backend rejects illegal
  parent/type pairings, and a skipped tier fails AFTER part of the tree exists). `create_item` with
  step 0's type names; `create_sub_item` only if the plan genuinely needs sub-items (rare — confirm).
  Then step 2's deferred container.
- **No created item takes a board from its parent**, container or leaf: `boardId` is the board
  the user named for it, else an explicit `null` (an omitted one can inherit the parent's); never
  `activeAgents.boardId` (plan roots only; `build-item` places them).
- Leaves (Story, or Defect for known-bug remediation) reuse the `create_item` CALL PATTERN of
  `${CLAUDE_PLUGIN_ROOT}/skills/plan/references/splice-mechanics.md` step 3 (same field shape,
  today-dated placeholder) — NOT its step-4 UPSTREAM/NEXT splice topology; step 5 owns the graph. Invoke `insert-story` itself only to splice
  ONE story into an otherwise-finished plan later.
- EXTEND path: create only the NEW items step 2 identified. Every new item's `startDate`/`dueDate`
  is **today** as a placeholder; real dates are step 6's.

## Result

After the verdict and its evidence, one fenced `json` block with `created`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `plan-create@1` dispatch.
