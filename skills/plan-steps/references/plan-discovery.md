---
load: contract
---
# plan-discovery — Ask the questions that change the shape, until the person says 'yes, build this'

`plan-steps`'s `plan-discovery@1` step. Ask the questions that change the shape, until the person says 'yes, build this'.

## Verdict

`PLAN SHAPE: SIGNED OFF | SIGNED OFF WITH ASSUMPTIONS | NOT SIGNED OFF [<reason>]`

## Procedure

Requires `plan-orient@1`, `plan-ground@1` (the runner refuses the step without a fresh proof of each). Follow
the procedure below, whole and in its order. It is an **interactive** step (`interactive: true`): it may hold a conversation with the person inside the step, asking product and shape questions, and reports waiting while it waits. It never asks a flow question; the loop owns those. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

### 1. Ground on any existing plan FIRST — extend vs. fresh root

Invoke **comprehend-plan** on the root before any other question — never hand-roll the tree read. It
tells you what exists, Done vs open, the wired edges, recorded design decisions (including "as-built"
comments on shipped items) and any orphan stories worth fixing in this pass. Tell the user which one
state applies:

- **Empty root** → a from-scratch plan.
- **Partial plan, extend** → **ADDITIVE**: existing items are locked inputs; scope the loop to the
  gaps comprehend-plan flagged plus the new slice. A spec that looks wrong or stale → say so and ask
  for explicit authorization; never overwrite because a fresh draft reads better.
- **Partial plan, shallow/placeholder** (one-liners, no design, no wiring) → ask whether to flesh
  out in place keeping titles/IDs, or archive and replace. Never decide alone — it may be intentional.

Never invent a rebuild: existing content and no "start over" means extend.

### 2. Interactive discovery loop — the core of the skill

Work it like a sharp staff engineer/PM, top-down, with explicit sign-off before going deeper. Ask
dependent decisions in sequence; otherwise numbered batches of no more than three, one plain decision and
consequence per bullet. Ask as many rounds as the ambiguity needs. Cover at minimum:

- **Source material** — a design or requirements doc is read BEFORE asking further questions.
- **Scope** — IN vs OUT/deferred; V1 vs V-next.
- **Grouping items** (this org: Capabilities) — a first-cut split at one-paragraph depth for the user
  to correct; do not over-elaborate.
- **Release units per grouping item** (this org: Epics) — phase-tagged where relevant ("V1a - …"),
  noting backend/frontend/infra-only. Ask the real judgment calls — wave boundaries, which unit owns
  which subsystem, where foundation work falls, deliberate deviations — as the specific question
  that changes the shape ("does the schema change belong here, or in its own foundation release
  unit that fans out to both?"), never just "does this look right". Rules for every release unit
  (the reasoning: `${CLAUDE_PLUGIN_ROOT}/skills/plan/references/release-unit-shaping.md` — read it
  when proposing the breakdown, or when a user asks why a boundary is wrong):
  - **A self-contained, shippable unit of end-consumer value — never merely a technical grouping.**
    Prefer vertical slices; fold a foundation into the first slice that needs it, or mark a
    genuinely shared one an explicit **internal enabler**. Shaping question: "if we shipped only this
    release unit and stopped, what can the end consumer now do?" — "nothing yet" means the boundary
    is wrong.
  - **Treat the development branch as PRODUCTION whenever promotion is frequent** (check
    `release.autoDeployOnMerge` and how often `release.releaseSource` promotes to
    `release.productionBranch`): each unit must be independently PRODUCTION-safe. Ask **(a) blast
    radius** (who is exposed day one; what gates it, or "nothing gates this"), **(b) billable,
    account-global or externally visible infrastructure** (an owner decision now, never a footnote in
    a bill), **(c) deploy integrity** (no leaf may reference a resource a later leaf creates — that
    ordering sits inside one unit). The answers land in the unit's **Release safety** section.
  - **Provision the deferred-work container; never park follow-ups under an active value release
    unit** — they stop it ever reaching zero remaining leaves. ONE container DIRECTLY under the plan
    root (`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/deferred-container.md`), NOT a release
    unit; its items carry a related-to edge — never `blocked_by` or an `[N]` prefix — back.
    Discovered SCOPE still splices into the chain via `insert-story`. A leaf whose theme does not match its release unit is a rehoming signal.
- **Leaf titles per release unit** (this org: Stories) — titles only, no specs yet. Grain is **the
  resolved profile's `grain` row and Shape targets, read now and quoted** when proposing, never a
  remembered size (above range: ask once about merging, never refuse);
  the row also settles where foundation work (scaffold, CI, schema, harness) sits. Flag foundation stories (under `prototype`: "goes first inside its slice")
  and mark gate stories (release-blocking checks, leak guards) for step 5. Grain changes; dating
  does not — step 6 still gives every leaf the same assumed length (one synthetic day unless
  `item-days` says otherwise), because dates show dependency depth, not effort.
- **Sequencing intent** — genuinely parallel vs hard serial gate; the narrow critical-path spine vs
  the wide parallel waves around it.
- **Depth/risk areas** — data model, module ownership, permission model: the user's call now, not a
  build agent's later. A divergence from a source doc is recorded as "(deviation, recorded)" with the
  doc § and rationale.

Under `prototype`, spend the rounds differently, not fewer than the ambiguity needs: every question
that would change the shape is still asked; only the ceremony per question drops. Conversely, match
depth to real ambiguity — do not stall a simple, well-specified root.

**If the user tries to skip the loop** ("you decide", "skip the questions"): push back once — a plan
without real answers on scope, staging and foundation stories lacks the dependency accuracy and spec
depth `/devstride:build-item` needs to run unattended; it only looks structured. If they insist,
comply, but label every assumption under "Assumptions made because Q&A was skipped" in the shape
summary and flag the affected descriptions. Never degrade quality silently.

**Sign-off — the hard boundary between judgment and drafting.** Do not draft until the full grouping
item → release unit → leaf-title shape and the sequencing intent are confirmed. Summarize the final
tree in one message (no specs) and get an explicit **"yes, build this"**. Then, at this sign-off:

## Result

After the verdict and its evidence, one fenced `json` block with `tree`, `sequencing`, `assumptions`, `deferredContainer`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `plan-discovery@1` dispatch.
