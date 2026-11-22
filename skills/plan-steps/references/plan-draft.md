---
load: contract
---
# plan-draft — Draft the specs for the signed-off shape; the drafting agents never write to DevStride

`plan-steps`'s `plan-draft@1` step. Draft the specs for the signed-off shape; the drafting agents never write to DevStride.

## Verdict

`PLAN DRAFTED: DRAFTED <counts> | FAILED [<reason>]`

## Procedure

Requires `plan-sign-off-record@1` (the runner refuses the step without a fresh proof of each). Follow
the procedure below and `${CLAUDE_PLUGIN_ROOT}/skills/plan/references/delivery-profiles.md`, whole and in its order. It is the one **delegating** step (`delegates: true`): it may run one Workflow of drafting agents, which draft only and never call an MCP write tool.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

### 3. Draft full specs via Workflow

One `pipeline()` (grouping items → release units → leaves), independent release units in
`parallel()`, fed every confirmed decision and the resolved profile's actual Stage C sections and
cap — not merely its name. Routing: Stage A's mechanical prose `haiku`/`low`; routine single-module
specs `sonnet`/`medium`; multi-module unit and leaf specs `sonnet`/`high`; one independent
`opus`/`high` critic only when cross-release contracts or an architectural ambiguity can materially
change a draft — its compact findings go to the affected agent, never a rerun of the fan-out. **Read
`${CLAUDE_PLUGIN_ROOT}/skills/plan/references/worked-example.md` to calibrate depth before opening
the Workflow** (illustrative fiction: copy the depth, never the paths). Depth is not uniform by
design — terse containers, real depth at release-unit and leaf level; padding the container level is
miscalibration.

- **Stage A — grouping items**: one short paragraph each (product concept + source-doc §).
- **Stage B — release units**, one agent each: **Business Description** (why, source-doc §);
  **Architectural Overview** (by module/subsystem, naming the files/commands/services likely touched
  and which child leaf owns each slice); **Key invariants** downstream work can rely on; **Release
  safety** — REQUIRED, since merging to develop reaches production within hours: day-one blast radius
  and what gates it (or "nothing gates this"), any billable/account-global/externally visible
  infrastructure as an owner decision, and any intra-unit deploy ordering (a stack naming a handler
  that does not exist yet fails the deploy and blocks the pipeline for everyone); "none" to all three
  is said explicitly — an empty section reads as unconsidered; **Cross-epic contracts** (what this
  unit's output feeds elsewhere; historical name); **Delivery Sequence** (its own leaves in
  dependency order, one-line justification each — feeds step 5).
- **Stage C — leaves**, one agent per release unit writing ALL siblings with shared sequencing
  context. The full template: **Business Description** (2–3 sentences, source §); **Architectural
  Design** — Data Model (exact table/column/type/default, file path, migration command), Backend
  (exact files, methods/fields, permission keys to gate on, edge-case rules), Frontend (scope, or
  explicitly "None in this story — X is a separate story"), Permissions and Security (keys + the
  invariant each enforces), Testing (exact spec path + enumerated cases as prose); **Dependencies**
  as structured data (`{blockedBy: ["Story: schema story for X"], blocks: [...]}`, by draft title);
  **Edge Cases** as explicit scope decisions ("duplicate uploads are NOT deduped in v1"); **Definition
  of Done**.
  - **The resolved `specDepth` row sets the section set and character cap — copy its section list
    and cap into the drafting prompt verbatim**, read from the contract at drafting time (an agent
    told only the name writes the full template; one told no cap pads). Omitted sections are absent,
    not abbreviated. The structured `Dependencies` are emitted under every profile, outside the cap.
  - Deviations from a source doc are recorded as "(deviation, recorded)" with § and rationale.
  - **Acceptance bar: implementation-ready** — `ultracode-build` can validate and build from it with
    minimal back-and-forth, not merely "reasonable-sounding". Under `prototype` that means precise
    acceptance criteria and named files; a short spec that leaves "done" to guesswork is under the
    bar at any length.

## Result

After the verdict and its evidence, one fenced `json` block with `draftRef`, `counts`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `plan-draft@1` dispatch.
