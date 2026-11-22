---
load: contract
---
# rebalance-gates — Check that nothing else is writing to the plan and the arguments are whole

`plan-steps`'s `rebalance-gates@1` step. Check that nothing else is writing to the plan and the arguments are whole.

## Verdict

`REBALANCE GATES: CLEAR | BUILD LOOP ACTIVE <item> | SCHEDULER ON | BAD ARGUMENTS <what>`

## Procedure

Requires nothing (the runner refuses the step without a fresh proof of each). Follow
the procedure below, whole and in its order. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

### 0. Safety gates — all of them, before a single read is trusted

- **Arguments.** Resolve the item with `get_item(view:"full")`; it must be a grouping item, never a
  leaf (a leaf → ask for its release unit or plan root). The target is one of the contract's bare
  profile words (resolution-order item 1); none, or any other word in its place → ask (a target of
  the retired `enterprise` → offer `extended` plus the contract's override recipe). A wrong root
  re-slices somebody else's plan; a guessed profile is the wrong grain at production speed. Note
  `--dry-run`.
- **Roles at runtime.** `get_work_type_hierarchy` (and `get_workspace_context` for statuses and
  priorities) decides which types are **leaves**, which level is the **release unit** (where
  `/devstride:build-item` branches and releases) and which are plain containers above it; bind every
  role word here to what it returns. Ambiguous release-unit level → `hierarchyRoles.releaseUnit` in
  `.claude/ds-config.json` if the repo is known, else ask. User-facing text says "grouping item" or
  the org's type name, never "container".
- **Refuse while a build loop is active on this plan** — two writers on one plan is the collision.
  Either is a hard stop: an **In Progress** leaf under the root with a **live branch**
  (`get_item_branches`, or `git ls-remote --heads origin "*/I<number>-*"` when the repo is known),
  or handoff project memory naming this root (or an ancestor/descendant) as mid-iteration. Report
  what tripped and stop — never wait it out, never move an In Progress item to clear it. An In
  Progress leaf with NO branch (a landed one included) is not a loop but stays untouchable.
- **Auto-scheduler OFF** — apply `${CLAUDE_PLUGIN_ROOT}/skills/rationalize-gantt/references/auto-scheduler-off.md`:
  its READ-ONLY check now (read the organization setting; if on, have the user disable it — never
  change it automatically) and `staticMode` omitted from every write. Its probe-date verification
  is a WRITE, so it runs only at the top of step 3, after sign-off, never on a dry run — with
  propagation on, the backend would overwrite the edges and dates step 3 writes.
- **Re-run the loop check immediately before step 3 writes anything** — a loop started while the
  proposal was being discussed is exactly the collision this gate exists for.

## Result

After the verdict and its evidence, one fenced `json` block with `root`, `target`, `dryRun`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `rebalance-gates@1` dispatch.
