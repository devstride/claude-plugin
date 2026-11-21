---
load: contract
---
# plan-orient — Resolve the plan root, its delivery profile and the organization's shape

`plan-steps`'s `plan-orient@1` step. Resolve the plan root, its delivery profile and the organization's shape.

## Verdict

`PLAN ORIENTATION: READY <root> | NEEDS ANSWER <question> | FAILED [<reason>]`

## Procedure

Requires nothing (the runner refuses the step without a fresh proof of each). Follow
the procedure below, whole and in its order. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

### 0. Orientation — resolve the root, the profile and the org's shape

- **Take any `--ticket <ticket#>[,<ticket#>]` out FIRST**: never the parent. Verify it here, link it
  at step 2's sign-off (discovery may move the plan), as `originating_ticket` only, never another
  type: **read `${CLAUDE_PLUGIN_ROOT}/skills/plan/references/originating-ticket.md` in full before linking**.
- The parent comes from `$ARGUMENTS`, or ask — never guess. `get_item(view: 'full')` it to confirm
  its work type (the planning level); the full view carries the `description` the profile needs.
- **Resolve the delivery profile and announce it with its source** (and any override) in the
  orientation message, per the contract's resolution order and root marker, with three plan rules:
  - **The marker step walks upward** — the parent's own description, else each ancestor up
    `hierarchy` with `get_item(view: 'full')` until one carries a marker (a parent is often a release
    unit BELOW a marked root; stopping early silently re-gates the subtree). Note whether it was the
    parent's own or inherited — step 2 writes a marker only when the parent has none and the profile
    came from somewhere other than an ancestor's marker. A descendant's own marker wins for its
    subtree; shape leaves beneath it to that profile.
  - **`profileOverrides.grain` / `profileOverrides.specDepth`** (repo known) each name another
    profile's column for that one knob; an absent key changes nothing; an unknown VALUE is reported
    and ignored, never guessed at.
  - **An argument that disagrees with an existing marker is a QUESTION, never an override** — the
    marker is a recorded decision; ask which profile this pass plans under ("change it" means
    `rebalance` first, per step 2).
- `get_work_type_hierarchy` and `get_workspace_context` give the org's REAL type names, statuses and
  priorities. **This runtime resolution is normative**: plan root and intermediate containers, the
  **release unit** (the level whose completion cuts a release — this org's Epic) and the executable
  **leaf** types (this org's Story/Defect) all bind to what it returns. Never assume canonical
  naming — some orgs have typos or custom hierarchies (a real org's Capability type is spelled
  `Capabilty`). **The release unit shaped here MUST be the level the delivery loop branches and
  releases at**: when structure leaves it ambiguous, use `hierarchyRoles.releaseUnit` as the
  tie-breaker if the repo is known, otherwise ASK and suggest recording the answer in
  `hierarchyRoles` (Feature-sized plans against Epic-sized releases undermine the
  production-safety boundary).

## Result

After the verdict and its evidence, one fenced `json` block with `root`, `workType`, `profile`, `profileSource`, `profileInherited`, `ticket`, `releaseUnitLevel`, `roles`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `plan-orient@1` dispatch.
