---
name: ultracode-build
description: "Build engine for a single scoped DevStride story: understand, build, adversarial review, and fix loop via ultracode Workflows"
---

The build engine for one scoped story: understand → build (committing often) → adversarial review
→ hand back. Invoked by `build-item` once the branch exists, the item is In Progress, and
`$ARGUMENTS` carries the item number plus a one-line scope.

Argument — item number + one-line goal (e.g. `I20130 enforce the seat-count invariant`): $ARGUMENTS

**Config**: `.claude/ds-config.json` (`verify.*`, `baseBranch`, `generated.*`,
`preCommitWiringChecks`, `conventionsDoc`, `lessonsDoc`) — authoritative over any literal here.
Coding conventions live in `conventionsDoc` (`AGENTS.md`), not the config. `lessonsDoc` (inline
fallback `.claude/ds-lessons.md`) is the repo's lessons store, distilled from past review
findings — **this skill READS it and never writes it**; `review` owns every write. **An
absent or empty lessons file is a valid state: proceed exactly as you would without it**, no
note, no prompt, no setup step.

Stop and ask ONLY at a genuine fork: an ambiguous or risky review finding, scope that turns out
human- or infra-gated, or a destructive/outward-facing action.

## 1. UNDERSTAND

Build an evidence-backed picture of "done" before writing code. **Provision readers proportional
to the story — don't reflexively fan all six.**

**Load `lessonsDoc` here, alongside `conventionsDoc`.** It is small and capped per
`${CLAUDE_PLUGIN_ROOT}/skills/review/references/lessons-format.md`, so read it inline — it is never a
reason to spin up a reader. Lessons are **ADVISORY hypotheses, NOT rules** — this is the difference between them and
`conventionsDoc`, which is human-owned and binding. A lesson is machine-distilled from past
findings and never independently reviewed, so it can be stale, overgeneralized, or simply
wrong. Before letting one shape the implementation, check that it actually applies to THIS
story's code; where it does, handling it up front is the cheapest place to deal with a known
mistake class. Where it does not, ignore it — silently, with no note. A lesson never overrides
`conventionsDoc`, the item's spec, or your own reading of the code. Absent or empty file →
skip this paragraph entirely and build as usual.

- **Trivial story** (one-line fix, copy tweak, rename, config flip with no contract surface):
  no Workflow. Read the few relevant files inline. (Phase 3 still reviews it — narrowly.)
- **Fresh grounding refresh on the item** (a dated section naming exact files, symbols, prior art,
  adjusted scope): treat as pre-paid. Verify its claims with targeted reads and spin up at most
  1–2 readers for angles it doesn't cover.
- **Otherwise** run a Workflow fanning parallel readers, each returning structured findings — file
  paths, line ranges, the concrete fact found, not vibes.
- **Unsure which side of the line a story falls on? Treat it as SUBSTANTIVE.** An unnecessary
  Workflow costs little next to a missed contract mismatch or a false-green test.

Three **core readers** carry the build:

- **Downstream-contract** — the interface the new code must satisfy: callers, request/response
  shape, event/command/query signature, DB columns or DynamoDB access pattern.
- **Module-structure** — where the code lives: module, command/query/event/handler/init layout,
  repository, and the mirroring directory under `verify.testDir`.
- **Test-plan** — existing tests it must not break, new unit/scenario tests, the TestContext /
  multi-user / permission patterns that apply.

Add the rest only when warranted, else fold into your own reading: **design-doc** (when the
validated description doesn't already pin behavior and the out-of-scope boundary — for a plan
story it usually does), **libs/conventions** (when leaning on unfamiliar utilities), **infra/seam**
(only when genuinely touching AWS/DNS/SES/Stripe/Pusher/GitHub/Slack).

Synthesize into (1) a concrete **build plan** — files to add/change, order, the contract each must
satisfy, tests to add; and (2) a one-line **buildable-now-vs-deferred scope line** with a rationale
per deferral. That line is load-bearing: it becomes the PR body's Deferred note.

If UNDERSTAND reveals the story is gated on a human decision or infra the user must provision,
STOP and surface it — do not build a half-thing around a missing dependency.

## 2. BUILD

Implement against the plan in the main agent (not a Workflow). Tight loop: small increment →
checks green → commit → repeat.

- Follow the contract per file; reuse what UNDERSTAND found; **read the repo's `conventionsDoc`
  and obey every rule in it**. It is the authority on this repo's typing rules, styling tokens,
  error handling, module boundaries and logging policy — do not substitute conventions you
  remember from elsewhere.
- **Commit OFTEN** — one per coherent step, not one at the end. Message per
  `commitConventions.messageFormat` (fallback: Conventional Commits with scope and the item tag,
  e.g. `fix(subscription): enforce seat-count invariant [I20130]`). AI attribution is
  optional; never invent or reuse attribution metadata. PR bodies get none.
- **Keep checks green as you go**: every command in `verify.typecheck`, every entry in
  `preCommitWiringChecks` (when the repo configures any), and the touched test suite via
  `verify.testSingle`, **widened when the change is broad**. A red type-check, wiring
  check, or test is stop-and-fix, never commit-anyway.
- **Generated-file type errors are tolerated** only where config says so — a file matching
  `generated.paths` failing with a pattern in `generated.toleratedTypeErrors`. Everything else
  stops. Fix those by re-running `generated.regenCommand`, never by hand-editing the file.
- **Skip `verify.skipDuringStoryBuilds` suites** when that config list is non-empty — those suites
  are gated elsewhere (at the PR/release boundary their config entries define), so don't run them
  locally during a story build and don't expect their checks here. An empty list means there is
  nothing to skip. Exception: if the diff touches one of those suites' own files, run just the
  touched spec directly.
- **Regenerate API artifacts when routes/handlers change** (`generated.regenCommand`) and commit
  the output in its OWN commit — it is build output, not hand-written code, and the next phase
  excludes it from review. Committing it yourself first keeps the pre-push hook's regen a no-op and
  avoids the non-fast-forward divergence from the hook amending after you push.
- Let the git hooks own wiring checks, regen and the commit-amend — don't script them by hand.
  Expect a commit to fail the wiring checks; surface that output and fix the omission.

## 3. ADVERSARIAL REVIEW (before the PR)

The **Claude build-time pass** — first of three engines (this, then Codex-local and Copilot-cloud
via `review`). It runs pre-PR so issues never become GitHub threads.

**MANDATORY, at `effort: 'max'`, on every story — no trivial-diff skip**
(`review.reviewDepthPolicy`). Pass `effort: 'max'` on every finder and verifier agent; do not
inherit session effort. The loop front-loads its quality budget here precisely so CI — held until
review settles — runs once on an already-clean diff. A skipped pass just moves the defect to the
expensive, serialized part of the pipeline.

**Breadth scales with risk; existence does not.** Say which size you picked:

- **NARROW** (one-liner, copy tweak, rename, config flip): 1–2 finder lenses — **correctness, plus
  conventions when the diff touches styled or typed frontend code** — with batched verification.
  Cheap; skipping is what costs.
- **CONTAINED** (one subsystem, no deployed-runtime contract change, no new permission surface —
  a CLI verb, a test harness, a self-contained few-hundred-line refactor): 2–3 lenses chosen for the
  diff's real risk, batched verification (one verifier per finder's list, not per finding). Half a
  dozen agents, not twenty-five.
- **HIGH-RISK** (cross-module contracts, deployed handlers/routes, migrations, permission/security
  surface, event reshapes, anything the deploy-safety contract flags): all five lenses,
  per-finding verification.

Unsure → go one size up.

Run over **the hand-written diff only** — computed against the story's WORKING BASE (the branch the
PR will target) and **excluding generated files**; reviewing generated code wastes finder budget
and produces noise.

**Stage A — finders** (parallel, one per angle). Each returns findings with a `file:line` anchor
and a one-sentence claim.

**Hand each finder the lessons that match ITS angle** as ADDITIONAL named checks. Routing is a
JUDGMENT read from each lesson's Pattern text — the schema records a curation `class`
(`repeat`/`general`/`common`), never an angle, so there is nothing to look up. A lesson whose
Pattern matches no lens you provisioned for this story is simply dropped for this build, by
design: at NARROW or CONTAINED breadth most angles have no finder at all, and the lesson has
already done its main job as a phase-1 constraint. Two
guardrails, both load-bearing: lessons **EXTEND** a finder's checklist and never narrow it — a
finder that tunnels onto lesson patterns and misses a novel defect has done the opposite of its
job; and a lesson-derived finding goes through Stage B verification like any other, with a
concrete `file:line` claim about THIS diff. A lesson is a hypothesis about where defects
cluster, never a verdict. No lessons file → the finders' base checklists are the whole story.

- **Correctness** — logic bugs, edge cases, off-by-one, null/undefined, swallowed `Result` errors,
  races, wrong state transitions.
- **Security** — missing `Auth.requireAccess`, IDOR / org-scoping gaps, injection, secrets in code,
  over-broad ACLs.
- **Contract-match** — does the code actually satisfy UNDERSTAND's downstream contract?
- **Tests / false-green** — assertions that can't fail, mocked-away behavior under test, missing
  negative/permission cases, a green suite not covering the new path.
- **Cleanup / conventions** — `conventionsDoc` violations, dead code, leftover debug, KISS/YAGNI/DRY.

**Stage B — verification** (per-finding at HIGH-RISK, batched per-finder at CONTAINED):
**CONFIRMED** (real and reproducible) / **PLAUSIBLE** (likely real, not fully verifiable from the
diff) / **REFUTED** (the verifier shows why the code is fine). This stage exists precisely so you
do NOT blind-apply finder suggestions — a finding is not actionable until CONFIRMED or PLAUSIBLE.

Then act: **fix every CONFIRMED and PLAUSIBLE**, or explicitly DEFER with a reason and a tag:

- **Has a home** — belongs to a tracked downstream story or sits behind this story's intentional
  seam. Record the rationale and owning item.
- **No home (untracked)** — real, out-of-scope, and NO existing item will pick it up. As PR prose
  it is invisible to the loop forever, so carry it on the hand-back's **untracked-deferral list**
  for `build-item` step 6.5.

**Drop every REFUTED finding** — don't "fix" code the verification stage proved correct. Commit
fixes per `commitConventions.reviewFixFormat` (fallback: `fix(<scope>): <summary> [<itemNumber> review]`); regenerate API artifacts again if routes changed. A genuinely
ambiguous or risky finding is a fork — ask, with your recommendation.

## 4. Hand back

Done when the branch holds a built, self-reviewed, all-green story: commits made and pushed,
type-checks / wiring checks / relevant tests green.

Report to `build-item`: the item number, a one-line summary, green-checks confirmation, and
three lists —

- **buildable-now-vs-deferred scope line** (build + review deferrals, each tagged has-a-home vs
  untracked);
- **untracked-deferral list** — load-bearing; step 6.5 turns each into a spliced-in item. Empty is
  fine and normal, but say so explicitly rather than omitting it;
- **deviations list** — every material divergence from the written spec, not just deferrals: a
  different approach, a false spec assumption (a dependency already shipped, a DTO lacked a field,
  a component already existed), scope cut or added, each with a one-line rationale. This feeds the
  PR body AND the item's as-built reconciliation, so a deviation that only lives in your head ships
  undocumented.

Do NOT open the PR or merge — that is `pr` / `build-item`'s job.
