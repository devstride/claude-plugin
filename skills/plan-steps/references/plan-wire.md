---
load: contract
---
# plan-wire — Wire the dependency edges and prove no new leaf is left without one

`plan-steps`'s `plan-wire@1` step. Wire the dependency edges and prove no new leaf is left without one.

## Verdict

`PLAN WIRED: WIRED <edges> | ORPHANS <numbers> | FAILED [<reason>]`

## Procedure

Requires `plan-create@1` (the runner refuses the step without a fresh proof of each). Follow
the procedure below, whole and in its order. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

**Approved text only.** Write the plan exactly as this conversation holds it approved; if it no
longer does (a new session, a compaction), answer `FAILED approval not in this conversation`
and write nothing, never rebuilding it.

### 5. Wire the full dependency graph — no orphans

- Resolve the Stage C `blockedBy`/`blocks` titles (and Stage B's cross-epic contracts) to the real
  numbers `create_item` returned, and wire with `add_relationship`, or `bulk_update_items`
  `workItemRelationships` in chunks (large payloads 503). Omit `staticMode` from every write per
  `${CLAUDE_PLUGIN_ROOT}/skills/rationalize-gantt/references/auto-scheduler-off.md`.
- **The true shape**: mostly WIDE fan-out/fan-in around a few narrow serial "gate" stories on the
  critical path — foundation stories fan out (a `blocks` edge to every downstream leaf in their
  subsystem), convergent stories fan in (several `blocked_by`), gate stories sit on the serial spine,
  marked in title/description, with few precise edges (chokepoints, not hubs), and genuinely
  independent branches stay parallel. The goal is dependency ACCURACY, not one serial thread.
- **Edges between two release units run one way**, never both (why:
  `references/release-unit-shaping.md`).
- **Hard gate**: every new leaf (deferred-container members excepted) has ≥ 1 `blocked_by` OR `blocks` edge, verified with `search_items`
  plus `get_item(view:"full", fields:["number","relationships"])` (a large batch: fan this
  read-only check out on `haiku`/`low`). An orphan is a wiring bug — give a parallel branch a
  `blocks` edge where it rejoins, or place it on the spine.

## Result

After the verdict and its evidence, one fenced `json` block with `orphans` and a `proof` object with `kind`, `orphans`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `plan-wire@1` dispatch.
