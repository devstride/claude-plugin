---
name: ultracode-build
description: "Build engine for a scoped DevStride story: understand, build and hand back evidence"
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

**Session model.** Read `${CLAUDE_PLUGIN_ROOT}/skills/plan/references/session-models.md` once per top-level run, role `runner`, first — never when `build-item` invoked this skill.

**Goal:** one scoped story understood, built and handed back with evidence — understand → build →
hand back. The Build workflow's build step, run once the branch exists and the item is In
Progress; the risk check (`risk-check`) and the local gate (`local-checks`) are steps of their own
that follow it. It never opens a PR or merges.

Argument — item number + one-line goal, optionally `profile: <name>`, `review-moment:
release-deferred|pr-boundary` (read by `risk-check`, not here) and `answer: <text>` (a person's
reply to this step's last question) (e.g. `I20130 enforce the seat-count invariant profile:
standard review-moment: release-deferred`): $ARGUMENTS

## Verdict

`BUILD: READY | NEEDS DECISION <question> | BLOCKED [<reason>]`

## Hard floors

- **Config wins.** `.claude/ds-config.json` (`verify.*`, `baseBranch`, `generated.*`,
  `preCommitWiringChecks`, `conventionsDoc`, `lessonsDoc`, `commitConventions`, `itemTagFormat`,
  `review.localAssistCommand`, `profile`, `profileOverrides`) is
  authoritative over any literal here; every command comes from it. Coding conventions live in
  `conventionsDoc`, which is human-owned and BINDING — obey every rule in it; never substitute
  conventions remembered from elsewhere.
- **Lessons are read-only here and advisory.** `lessonsDoc` (fallback `.claude/ds-lessons.md`) is
  READ, never written — `review` owns every write. An absent or empty file is a valid state: proceed
  exactly as without it — no note, no prompt, no setup step.
- **Stop and ask ONLY at a genuine fork** (`BUILD: NEEDS DECISION <question>`, with your
  recommendation): an ambiguous or risky choice, scope that turns out human- or infra-gated, a
  destructive or outward-facing action. Given an `answer`, apply it and carry on. Read
  `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/needs-you.md` when the top-level run is
  unattended, `needsYou.label` set.

**Engineering economy.** Read
`${CLAUDE_PLUGIN_ROOT}/skills/ultracode-build/references/engineering-economy.md` before choosing an
approach or launching agents: reuse, DRY/YAGNI, bounded parallelism, task-sized Claude
models/effort, and the optional read-only local support call.

**Delivery profile.** The contract is
`${CLAUDE_PLUGIN_ROOT}/skills/plan/references/delivery-profiles.md`; this skill honours
`understandReaders` (phase 1). Resolve it ONCE, before phase 1, and announce it with its source:

- **Passed** (`profile: <name>`, the `build-item` path): use it as given, never re-resolve —
  "profile: standard — from the invocation". A name the contract does not define
  (`profile: standart`) is a stop-and-ask, never a guess: no column would supply the knobs;
  the retired `enterprise` alone is read as `standard`, said so (the contract).
- **Standalone**: walk the contract's resolution order; its root marker needs
  `get_item(view: 'full')` — a summary read omits the description and silently falls through.
  Announce the source ("… — from the plan root", "… — from config", "… — default").

Then apply `profileOverrides` to those knobs within the contract's floors; report and ignore an
unknown knob.

**Story claim.** With `claims` set, heartbeat the story at the start of each phase below, phase
name as `phase` (`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/story-claims.md`).

## 1. UNDERSTAND

An evidence-backed picture of "done" before any code. **Provision readers proportional to the
story — never reflexively all six**; `understandReaders` CAPS the fan-out.

**Load `lessonsDoc` here, inline, beside `conventionsDoc`** — it is small and capped per
`${CLAUDE_PLUGIN_ROOT}/skills/review/references/lessons-format.md`, never a reason for a reader.
Lessons are **ADVISORY hypotheses, NOT rules**: machine-distilled, never independently reviewed,
possibly stale or wrong. Where one genuinely applies to THIS story's code, handle it up front; where
it does not, ignore it silently. A lesson never overrides `conventionsDoc`, the spec, or your own
reading of the code.

- **Trivial** (one-line fix, copy tweak, rename, config flip with no contract surface): no
  Workflow; read the few files inline; the risk check still self-checks. **Unsure → not trivial.**
- **Fresh grounding refresh on the item** (a dated section naming files, symbols, prior art,
  adjusted scope): pre-paid — verify its claims with targeted reads; at most 1–2 readers for
  angles it misses.
- **Otherwise** name the independent questions whose answers can change the build plan and fan
  only those; each reader returns paths, line ranges and concrete facts. Vague uncertainty is read
  inline until it becomes a real question.

The cap bounds every branch: **0** (`prototype`) — no Workflow for ANY story, read inline
(substantive means more files, not readers); **≤ 2** (`standard`) — readers only for angles the
spec or refresh does not pin, none for a fully pinned spec; **≤ 4** (`extended`) — as standard,
plus the cross-contract angles a subsystem-sized story touches beyond its spec; **up to six**
(override). Announce the count provisioned against the cap.

Route mechanical inventories to `haiku`/`low`, routine contract or test-plan reading to
`sonnet`/`medium`, cross-file synthesis to `sonnet`/`high`; one `opus`/`high` critic only when an
independent view can change a cross-module decision. A story meeting `review.localAssistCommand`'s
narrow trigger launches its one read-only call concurrently with the readers; routine stories skip it.

**Core readers**: **downstream-contract** (callers, request/response shape, event/command/query
signature, storage columns or access pattern), **module-structure** (where the code lives and its
layout, with the mirroring directory under `verify.testDir`), **test-plan** (tests it must not
break, new tests, the repo's test-harness patterns). Add **design-doc** (only when the validated
description does not pin behaviour and the out-of-scope boundary), **libs/conventions**
(unfamiliar utilities) or **infra/seam** (genuinely touching external services) only when
warranted.

Synthesize (1) a **build plan** — files, order, the contract each satisfies, tests — and (2) a
one-line **buildable-now-vs-deferred scope line** with a rationale per deferral; it becomes the PR
body's Deferred note. Gated on a human decision or user-provisioned infra → STOP and surface it
(`BUILD: NEEDS DECISION`, or `BLOCKED` when nothing a person can answer here unblocks it); never
build a half-thing around a missing dependency.

## 2. BUILD

Implement in the main agent (not a Workflow), in coherent increments: targeted check → commit.

- **Follow the contract per file and reuse what UNDERSTAND found.**
- **Commit per coherent step** — not every edit, not one giant commit — message per
  `commitConventions.messageFormat`, tag per `itemTagFormat` (fallback: Conventional Commits with
  scope and item tag, `fix(subscription): enforce seat-count invariant [I20130]`). AI attribution is
  optional; never invent or reuse attribution metadata; PR bodies get none.
- **Fastest relevant feedback while building**: the affected type-check, configured wiring checks,
  touched tests via `verify.testSingle` — widened when the change is broad.
- **Generated files**: a type error is tolerated only in a `generated.paths` file matching
  `generated.toleratedTypeErrors`; everything else stops. Fix by re-running
  `generated.regenCommand`, never by hand. When routes/handlers change, regenerate and commit the
  output in its OWN commit — build output, excluded from review, and it keeps the pre-push hook's
  regen a no-op instead of amending after you push.
- **Let the git hooks own wiring checks, regen and the commit-amend**; a commit failing a wiring
  check is surfaced and the omission fixed.

## 3. Hand back

Done when the branch holds the built story: commits made and pushed, the affected type-checks,
wiring checks and touched tests green. The risk check and the complete local gate are not run here.

**Human recap.** The answer's first line is its verdict (`BUILD: READY`). Then lead with
`Built / Checked / Next`: outcomes, what validation ran or did not run, and what still has to run
before the story can merge. Then the item, **the profile and its source**, and four lists — each
stated as empty when empty, never omitted:

- **buildable-now-vs-deferred scope line** — build and review deferrals, each tagged has-a-home or
  untracked;
- **untracked-deferral list** — each homeless finding worth filing; load-bearing:
  `capture-findings` turns each into a tracked item;
- **dismissed-findings list** — every verified finding left unfixed and not worth filing, with its
  rationale, so the PR body shows what was judged rather than missed (normally empty under
  `all-confirmed`);
- **deviations list** — every material divergence from the written spec: a different approach, a
  false spec assumption (a dependency already shipped, a missing field, an existing component),
  scope cut or added, each with a one-line rationale. It feeds the PR body AND the as-built
  reconciliation; a deviation only in your head ships undocumented.

After the evidence, one fenced `json` block: `deferrals`, `deviations`, `untrackedDeferrals`,
`dismissed` (the four lists, each an array), `scopeLine` and `head` (the full commit handed back).

Do NOT open the PR or merge — those are later steps of the Build workflow. Standalone, finish with
/devstride:risk-check and /devstride:local-checks.
