---
load: contract
---
# plan-sign-off-record — Record the sign-off, and nothing else, in DevStride

`plan-steps`'s `plan-sign-off-record@1` step. Record the sign-off, and nothing else, in DevStride.

## Verdict

`SIGN-OFF RECORDED: RECORDED <profile> | LINK MODE ON | FAILED [<reason>]`

## Procedure

Requires `plan-discovery@1` (the runner refuses the step without a fresh proof of each). Follow
the procedure below, whole and in its order. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

- **Link any `--ticket`** to the confirmed root (that contract), then **write the root marker** —
  the only live writes before step 4 — in the
  contract's exact one-line form (`<p><strong>Delivery profile:</strong> <name></p>`). `update_item`'s
  `description: { html }` REPLACES the whole description: re-read with `get_item(view: 'full')` AT
  WRITE TIME, PREPEND the marker, write the concatenation — never the marker alone. Skip when the
  root already carries the resolved profile's marker. **On the EXTEND path never rewrite an existing
  marker** — that silently re-gates and re-grains leaves sliced under the old profile; it is
  `rebalance`'s job (marker AND re-slice). "Use the argument's profile" → stop, run `rebalance`,
  re-invoke; "keep the marker" → plan under it.
- **Settle the start date and the item length here**: the arguments' `start` and `item-days`,
  else ask for both, offering the defaults — the day after today, and one day per story (on the
  EXTEND path, the start, when still ahead, and the length the plan's open stories already have). **A plan never starts today or
  earlier unless the user names that day.** Step 6 passes on the length, and the start when named.
- **Batch the auto-scheduler heads-up here**, not at the end: step 6 needs the organization-wide
  dependency propagation OFF. Run the canonical Enable Link Mode check now
  (`${CLAUDE_PLUGIN_ROOT}/skills/rationalize-gantt/references/auto-scheduler-off.md`) — read the
  setting first; if it is on, tell the user now so they disable it during drafting; **never change it
  automatically** (step 6's skill owns the probe-date verification).

**Release scope clause.** A `Release scope: plan` line: only when the owner asks
(`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plan-scope.md`).

## Result

After the verdict and its evidence, one fenced `json` block with `root`, `profile`, `start`, `itemDays`, `linkMode` and a `proof` object with `kind`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `plan-sign-off-record@1` dispatch.
