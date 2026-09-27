---
name: ultracode-build
description: "Build engine for a scoped DevStride story: understand, build, verify, and run a risk-sized pre-handoff check"
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

**Goal:** one scoped story built, verified green at its profile's width, risk-checked and handed
back with evidence — understand → build → verify → risk check → hand back. Invoked by `build-item`
once the branch exists and the item is In Progress; it never opens a PR or merges.

Argument — item number + one-line goal, optionally `profile: <name>` and
`review-moment: release-deferred|pr-boundary` (e.g. `I20130 enforce the seat-count invariant
profile: standard review-moment: release-deferred`): $ARGUMENTS

## Hard floors

- **Config wins.** `.claude/ds-config.json` (`verify.*`, `baseBranch`, `generated.*`,
  `preCommitWiringChecks`, `conventionsDoc`, `lessonsDoc`, `commitConventions`, `itemTagFormat`,
  `review.localAssistCommand`, `review.mandatoryLenses`, `profile`, `profileOverrides`) is
  authoritative over any literal here; every command comes from it. Coding conventions live in
  `conventionsDoc`, which is human-owned and BINDING — obey every rule in it; never substitute
  conventions remembered from elsewhere.
- **Lessons are read-only here and advisory.** `lessonsDoc` (fallback `.claude/ds-lessons.md`) is
  READ, never written — `review` owns every write. An absent or empty file is a valid state: proceed
  exactly as without it — no note, no prompt, no setup step.
- **The immediate-risk verifier and mandatory lenses fire from the DIFF**, not the plan's theme,
  under every profile — `extended` included — and no override removes them (phase 3).
- **Verified P1 and serious-P2 findings are always fixed** — no numeric cap; a stall STOPS for
  human help (phase 3).
- **Green means observed.** A red required check is stop-and-fix, never commit-anyway; the gate's
  proof is a verification receipt, never a remembered result.
- **Stop and ask ONLY at a genuine fork**: an ambiguous or risky finding, scope that turns out
  human- or infra-gated, a destructive or outward-facing action.

**Engineering economy.** Read
`${CLAUDE_PLUGIN_ROOT}/skills/ultracode-build/references/engineering-economy.md` before choosing an
approach or launching agents: reuse, DRY/YAGNI, bounded parallelism, task-sized Claude
models/effort, and the optional read-only local support call.

**Delivery profile.** The contract is
`${CLAUDE_PLUGIN_ROOT}/skills/plan/references/delivery-profiles.md`; this skill honours
`understandReaders` (phase 1), `fixFloor` (3) and `storyVerify` (2, 4). Resolve it ONCE, before
phase 1, and announce it with its source:

- **Passed** (`profile: <name>`, the `build-item` path): use it as given, never re-resolve —
  "profile: standard — from the invocation". A name the contract does not define
  (`profile: standart`) is a stop-and-ask, never a guess: no column would supply the knobs.
- **Standalone**: walk the contract's resolution order; its root marker needs
  `get_item(view: 'full')` — a summary read omits the description and silently falls through.
  Announce the source ("… — from the plan root", "… — from config", "… — default").

Then apply `profileOverrides` to those knobs within the contract's floors; report and ignore an
unknown knob.

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
  Workflow; read the few files inline; phase 3 still self-checks. **Unsure → not trivial.**
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
(`enterprise`). Announce the count provisioned against the cap.

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
body's Deferred note. Gated on a human decision or user-provisioned infra → STOP and surface it;
never build a half-thing around a missing dependency.

## 2. BUILD

Implement in the main agent (not a Workflow), in coherent increments: targeted check → commit.

- **Follow the contract per file and reuse what UNDERSTAND found.**
- **Commit per coherent step** — not every edit, not one giant commit — message per
  `commitConventions.messageFormat`, tag per `itemTagFormat` (fallback: Conventional Commits with
  scope and item tag, `fix(subscription): enforce seat-count invariant [I20130]`). AI attribution is
  optional; never invent or reuse attribution metadata; PR bodies get none.
- **Fastest relevant feedback while building**: the affected type-check, configured wiring checks,
  touched tests via `verify.testSingle` — widened when the change is broad.
- **The profile's complete `storyVerify` gate runs once on the final story SHA** — a floor whose
  width the profile sets. If phase 3 changes the SHA, rerun the affected checks and any gate the
  change can invalidate; never repeat an unchanged command on an unchanged SHA. Record tree/SHA,
  config hash, commands, results and counts exactly as
  `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/verification-receipts.md` defines.
- **Generated files**: a type error is tolerated only in a `generated.paths` file matching
  `generated.toleratedTypeErrors`; everything else stops. Fix by re-running
  `generated.regenCommand`, never by hand. When routes/handlers change, regenerate and commit the
  output in its OWN commit — build output, excluded from review, and it keeps the pre-push hook's
  regen a no-op instead of amending after you push.
- **`verify.skipDuringStoryBuilds` suites are skipped** during story builds (gated where their
  entries say); an empty list skips nothing, and a full `verify.test` run still leaves listed
  suites out — except a touched spec of one of them, run directly.
- **Let the git hooks own wiring checks, regen and the commit-amend**; a commit failing a wiring
  check is surfaced and the omission fixed.

## 3. STORY RISK CHECK (before hand-off)

Inspect the hand-written diff against the working base once, generated files excluded. This is a
bounded story check; the full merge-boundary pass uses
`${CLAUDE_PLUGIN_ROOT}/skills/ultracode-build/references/review-fanout.md`.
`review-moment: release-deferred` means a fast story whose complete finder/verifier and
configured-engine pass waits for the release PR's full diff; `review-moment: pr-boundary` means
`review` runs it on the direct story PR next; no marker (standalone) → this check plus a report of
the missing caller context — never guess that a full review happened.

- **Every story** gets a main-agent self-check: acceptance-criteria match, correctness at changed
  boundaries, meaningful negative tests, repo conventions, needless custom machinery or duplication.
  Lessons apply as hypotheses. A routine diff: fix what it finds, launch no generic fan-out.
- **Immediate risk floor.** When the DIFF touches authentication/authorization, a migration or
  irreversible state transition, or a deployed-runtime contract (including migration and durable-
  event safety under a rolling deploy), name the files and risk and launch one
  focused `opus`/`xhigh` verifier per independent boundary, maximum two — grouping related ones, dropping
  none. It tries to reproduce a concrete failure, checks the matching security/deploy invariant and
  returns anchored findings as CONFIRMED / PLAUSIBLE / REFUTED; REFUTED is the default and "could
  not rule it out" is not evidence. The profile cannot remove this floor.
- **Mandatory lenses.** A `review.mandatoryLenses` entry whose `paths` match a hand-written file
  is an immediate-risk boundary of its own: one focused verifier carrying its `name` and
  `question`, even on a routine diff, reported as `mandatory lens <name>: ran (N findings)`; an
  unmatched entry is not mentioned; a malformed one is named once and ignored. Read
  `${CLAUDE_PLUGIN_ROOT}/skills/ultracode-build/references/mandatory-lenses.md` when one matches.
- A configured `review.localAssistCommand` may take one read-only call, concurrently, on a distinct
  risk question — advisory, never a second mandatory pass.
- **Ids** `F1…Fn` follow `review-fanout`'s fingerprint/occurrence rule, keeping every source and
  anchor; a security duplicate keeps its classification. A verdict from a browser, service or
  manual run names the path exercised and those not exercised — never a bare "verified".
- **Universal fix floor.** A verified P1 or serious P2 (defined in `review-fanout`) is fixed, its
  affected checks rerun, and a focused verifier re-run with the cumulative story ledger until a
  pass finds none — no numeric cap. No patch change, no progress or an unavailable verifier while
  one remains STOPS for human help. Then the profile's `fixFloor`: **`p1-security`**
  (`prototype`) — P1 correctness and any security finding, everything else deferred with a one-line
  rationale; **`likely-important`** (`standard`, `extended`) — findings both likely and material (a
  security finding is material by definition), the rest dismissed with a one-line rationale;
  **`all-confirmed`** (`enterprise`) — **fix every CONFIRMED and PLAUSIBLE.**
- **Nothing is silently dropped**: an unfixed finding is DEFERRED — with a home (a tracked
  downstream item or this story's intentional seam: rationale + owning item) or, with no home,
  on the **untracked-deferral list** for `build-item` step 6.5, since PR prose is invisible to the
  loop — or DISMISSED with its reason. Drop REFUTED. Commit fixes per
  `commitConventions.reviewFixFormat` (fallback `fix(<scope>): <summary> [<itemNumber> review]`),
  regenerating artifacts if routes changed. A genuinely ambiguous risky finding is asked about,
  with a recommendation.
- **Story review ledger**: item-number namespace, base/head SHA, risk and files, each finding's
  id/fingerprint/anchors/claim/verdict/disposition, checks rerun, any local-assist conclusion. The
  later review receives it and may challenge it, but never rediscovers or reverses a settled finding
  without new evidence.
- **Risk-check report**, one line: profile, review moment, routine vs immediate-risk, agents used
  (normally zero; focused verifier count when required), matched lenses, raised/fixed/deferred/
  dismissed totals.

## 4. Hand back

Done when the branch holds a built, risk-checked, all-green story: commits made and pushed,
type-checks and wiring checks green, the test gate green at the profile's `storyVerify` width.

**Human recap.** Lead with `Built / Checked / Next`: outcomes, what validation and review ran or did
not run, and whether the story is ready for its merge path. Then report to `build-item`: the item,
**the profile and its source**, the SHA-keyed verification receipt, the phase-3 risk-check report
and story review ledger, and four lists — each stated as empty when empty, never omitted:

- **buildable-now-vs-deferred scope line** — build and review deferrals, each tagged has-a-home or
  untracked;
- **untracked-deferral list** — load-bearing: step 6.5 turns each into a tracked item;
- **dismissed-findings list** — every verified finding the `fixFloor` left unfixed and undeferred,
  with its rationale, so the PR body shows what was judged rather than missed (normally empty under
  `all-confirmed`);
- **deviations list** — every material divergence from the written spec: a different approach, a
  false spec assumption (a dependency already shipped, a missing field, an existing component),
  scope cut or added, each with a one-line rationale. It feeds the PR body AND the as-built
  reconciliation; a deviation only in your head ships undocumented.

Do NOT open the PR or merge — that is `pr` / `build-item`'s job.
