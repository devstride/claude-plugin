---
name: ultracode-build
description: "Build engine for a single scoped DevStride story: understand, build, adversarial review, and fix loop via ultracode Workflows"
---

The build engine for one scoped story: understand → build (committing often) → adversarial review
→ hand back. Invoked by `build-item` once the branch exists, the item is In Progress, and
`$ARGUMENTS` carries the item number plus a one-line scope — and, when the caller has resolved
it, the delivery profile.

Argument — item number + one-line goal, optionally followed by `profile: <name>` (e.g.
`I20130 enforce the seat-count invariant profile: standard`): $ARGUMENTS

**Config**: `.claude/ds-config.json` (`verify.*`, `baseBranch`, `generated.*`,
`preCommitWiringChecks`, `conventionsDoc`, `lessonsDoc`, `profile`, `profileOverrides`) —
authoritative over any literal here.
Coding conventions live in `conventionsDoc` (`AGENTS.md`), not the config. `lessonsDoc` (inline
fallback `.claude/ds-lessons.md`) is the repo's lessons store, distilled from past review
findings — **this skill READS it and never writes it**; `review` owns every write. **An
absent or empty lessons file is a valid state: proceed exactly as you would without it**, no
note, no prompt, no setup step.

**Delivery profile.** How much of this engine's budget a story gets is set by the delivery
profile — the canonical contract is
`${CLAUDE_PLUGIN_ROOT}/skills/plan/references/delivery-profiles.md`, and this skill honours
five of its knobs: `understandReaders` (phase 1), `reviewBreadthCeiling`, `verificationDefault`
and `fixFloor` (phase 3), and `storyVerify` (phases 2 and 4). Resolve it ONCE, before phase 1,
and announce it with its source:

- **Passed in the invocation** (`profile: <name>` — the `build-item` path): use it as given, do
  not re-resolve, and announce it as such ("profile: standard — from the invocation"); the
  caller already walked the order and reported the underlying source. The name must be one of
  the three the contract defines; anything else (`profile: standart`) is a stop-and-ask, never
  a guess or a silent fall-through — with an unknown name no column supplies the knobs below.
- **Standalone** (no profile in `$ARGUMENTS`): walk the contract's resolution order — its root
  marker needs `get_item(view: 'full')`, since the default projection omits the description
  and a summary read silently falls through to the config default. Announce the result and
  where it came from ("profile: prototype — from the plan root", "… — from config",
  "… — default").

Then apply `profileOverrides` from config to the individual knobs, within the contract's floors:
no override lowers the breadth below NARROW or removes the auth-boundary security lens, and an
unknown knob name is reported and ignored. Each phase below says what its knob changes; the
floors the contract lists hold under every profile and are marked as such.

Stop and ask ONLY at a genuine fork: an ambiguous or risky review finding, scope that turns out
human- or infra-gated, or a destructive/outward-facing action.

## 1. UNDERSTAND

Build an evidence-backed picture of "done" before writing code. **Provision readers proportional
to the story — don't reflexively fan all six.** The profile's `understandReaders` is the CAP on
that fan-out; the triage below still decides how much of the cap a given story uses.

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

The cap bounds every branch of that triage:

- **`understandReaders` = 0** (`prototype`): no Workflow for ANY story — read the relevant files
  inline, the way the trivial branch already does. "Substantive" then means reading more files,
  not fanning readers; a grounding refresh is still verified with targeted reads.
- **≤ 2 readers** (`standard`): readers only for the angles the spec or grounding refresh does
  not pin — the grounding-refresh branch as written, applied to every non-trivial story. A
  fully pinned spec gets none.
- **Up to the six this phase defines** (`enterprise`): the triage exactly as written.

Announce the count you actually provisioned against the cap.

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
  `commitConventions.messageFormat`, with the tag shaped per `itemTagFormat` (fallback:
  Conventional Commits with scope and the item tag,
  e.g. `fix(subscription): enforce seat-count invariant [I20130]`). AI attribution is
  optional; never invent or reuse attribution metadata. PR bodies get none.
- **Keep checks green as you go**: every command in `verify.typecheck`, every entry in
  `preCommitWiringChecks` (when the repo configures any), and the touched test suite via
  `verify.testSingle`, **widened when the change is broad**. A red type-check, wiring
  check, or test is stop-and-fix, never commit-anyway.
- **The story's green gate is as wide as the profile's `storyVerify` says** — that it must be
  green is a floor; the profile sets only the WIDTH. The per-commit loop above is the
  `prototype` width in full (type-checks plus the touched suites, widened when broad; the full
  suite waits for the release PR). `standard` adds the full `verify.test` before hand-back;
  `enterprise` adds `verify.lint` on top, where the diff touches lintable code. Run the wider
  gate before phase 3 and again after any review fix lands — never only once, early.
- **Generated-file type errors are tolerated** only where config says so — a file matching
  `generated.paths` failing with a pattern in `generated.toleratedTypeErrors`. Everything else
  stops. Fix those by re-running `generated.regenCommand`, never by hand-editing the file.
- **Skip `verify.skipDuringStoryBuilds` suites** when that config list is non-empty — those suites
  are gated elsewhere (at the PR/release boundary their config entries define), so don't run them
  locally during a story build and don't expect their checks here. An empty list means there is
  nothing to skip, and a full `verify.test` run under `standard` or `enterprise` still leaves
  the listed suites out. Exception: if the diff touches one of those suites' own files, run just
  the touched spec directly.
- **Regenerate API artifacts when routes/handlers change** (`generated.regenCommand`) and commit
  the output in its OWN commit — it is build output, not hand-written code, and the next phase
  excludes it from review. Committing it yourself first keeps the pre-push hook's regen a no-op and
  avoids the non-fast-forward divergence from the hook amending after you push.
- Let the git hooks own wiring checks, regen and the commit-amend — don't script them by hand.
  Expect a commit to fail the wiring checks; surface that output and fix the omission.

## 3. ADVERSARIAL REVIEW (before the PR)

The **Claude build-time pass** — the first engine, and the one every profile keeps (the local
CLI engine and the cloud reviewers follow via `review`, as the profile and config allow). It
runs pre-PR so issues never become GitHub threads.

**MANDATORY, at `effort: 'max'`, on every story — no trivial-diff skip**
(`review.reviewDepthPolicy`). Pass `effort: 'max'` on every finder and verifier agent; do not
inherit session effort. The loop front-loads its quality budget here precisely so CI — held until
review settles — runs once on an already-clean diff. A skipped pass just moves the defect to the
expensive, serialized part of the pipeline.

**Breadth scales with risk; existence does not.** The profile's `reviewBreadthCeiling` is the
widest size this rule may pick; size the diff as below, then clamp to the ceiling. Say which
size you picked and, when the ceiling clamped it, say that too:

- **NARROW**: 1–2 finder lenses — **correctness, plus conventions when the diff touches styled
  or typed frontend code** — with batched verification. The security lens joins these when the
  diff touches the auth boundary (the floor below): an addition to NARROW, not a step up.
- **CONTAINED**: 2–3 lenses chosen for the diff's real risk, batched verification (one verifier
  per finder's list, not per finding).
- **HIGH-RISK**: all five lenses, verification grouped by file.

Unsure → go one size up, **never past the ceiling**; a ceiling the contract lets rise for one
story is the contract's exception, not a judgment call here. **Read when** the size is unclear:
`${CLAUDE_PLUGIN_ROOT}/skills/ultracode-build/references/review-fanout.md` — what each breadth
looks like, why verification is grouped, the lesson-routing and verification reasoning.

**FLOORS — no profile or override removes these.** The Claude pass itself always runs, at NARROW
or wider. And **the security lens is added whenever the DIFF touches the auth boundary** — as
the contract defines it — at every breadth, including NARROW under a NARROW ceiling. Decide
that from the diff in hand, not from the plan's theme: a scaffold or runbook story in an auth
plan does not touch the boundary; the login-callback story does.

Run over **the hand-written diff only** — computed against the story's WORKING BASE (the branch the
PR will target) and **excluding generated files**; reviewing generated code wastes finder budget
and produces noise.

**Stage A — finders** (parallel, one per angle). Each returns findings with a `file:line` anchor
and a one-sentence claim. Assign each finding an id (`F1…Fn`) when merging the finders' lists —
Stage B's verdicts are keyed by it.

**Hand each finder the lessons that match ITS angle** as ADDITIONAL named checks — a judgment
read from each lesson's Pattern text (the schema records no angle); a lesson matching no lens
provisioned for this story is dropped for this build. Two imperatives: lessons **EXTEND** a
finder's checklist and never narrow it; and a lesson-derived finding goes through Stage B
verification like any other, with a concrete `file:line` claim about THIS diff. No lessons
file → the finders' base checklists are the whole story.

- **Correctness** — logic bugs, edge cases, off-by-one, null/undefined, swallowed `Result` errors,
  races, wrong state transitions.
- **Security** — missing `Auth.requireAccess`, IDOR / org-scoping gaps, injection, secrets in code,
  over-broad ACLs.
- **Contract-match** — does the code actually satisfy UNDERSTAND's downstream contract?
- **Tests / false-green** — assertions that can't fail, mocked-away behavior under test, missing
  negative/permission cases, a green suite not covering the new path, and a behavioural fix
  verified on ONE path to a state that other paths also reach (a second navigation route, a
  fresh tab, a keyboard shortcut, a retry) — name the unexercised paths as findings.
- **Cleanup / conventions** — `conventionsDoc` violations, dead code, leftover debug, KISS/YAGNI/DRY.

**Stage B — verification.** Fan out by the profile's `verificationGrouping` (contract): at
HIGH-RISK **one verifier per file-group** — the findings anchored in one file, or in a small set
of files one verifier can hold together (at most 5 findings and 3 files per group; split larger
ones) — grouped by `${CLAUDE_PLUGIN_ROOT}/skills/ultracode-build/scripts/group-findings.py`; at
CONTAINED one verifier per finder's list; at NARROW batched. **An auth-boundary finding is never
grouped: it gets its own verifier at every breadth** (Floor 2) — auth-boundary meaning the
security lens raised it, or its anchor file is one the diff's auth-boundary decision named. Every
verifier returns **one verdict per finding id** — CONFIRMED / PLAUSIBLE / REFUTED, each with
likelihood and impact, as a JSON list keyed by id; a return missing any id, or carrying one
verdict for the group, is defective: re-run that group per finding and say so in the report.
`profileOverrides.verificationGrouping: "per-finding"` restores one verifier per finding.
**CONFIRMED** (real and reproducible) / **PLAUSIBLE** (likely real, not fully verifiable from the
diff) / **REFUTED** (the verifier shows why the code is fine). This stage exists precisely so you
do NOT blind-apply finder suggestions — a finding is not actionable until CONFIRMED or PLAUSIBLE.
`verificationDefault` is **REFUTED unless reproducible** under every profile: a verifier starts
from REFUTED and the finding earns its way up — CONFIRMED by reproducing it from the diff,
PLAUSIBLE only by pointing at the concrete mechanism in THIS diff and showing why it is likely
reached. A finder's confidence moves nothing on its own, and "could not rule it out" is
REFUTED. Every CONFIRMED or PLAUSIBLE verdict also carries the two facts the fix floor reads
next: **likelihood** (how readily the defect is reached in real use) and **impact** (what it
costs when it is). **P1** means the impact is a broken acceptance criterion of this story,
corrupted or lost data, or a security hole; a security finding is P1 whatever its likelihood.

**A verdict that rests on having LOOKED — a browser, a running service, a manual run — names
the path it exercised.** The report vocabulary is **"verified X via path Y"**, never a bare
"verified". Before calling a behavioural fix verified, enumerate the ways the state can be
reached and name which routes were NOT tried. **Read when** verifying by looking: the reference
above — scoping what you measure, one clean load per case, stale sessions that mimic defects.

Then act by the profile's `fixFloor` — which verified findings get fixed IN THIS STORY, read
from those verdicts:

- **`p1-security`** (`prototype`): P1 correctness and any security finding. Everything else is
  deferred with a one-line rationale, tagged as below.
- **`likely-important`** (`standard`): findings that are both likely to occur and material if
  they do; a security finding is material by definition, so for it only likelihood is in
  question. The rest is dismissed with a one-line rationale, recorded in the hand-back.
- **`all-confirmed`** (`enterprise`): **fix every CONFIRMED and PLAUSIBLE.**

What is not fixed is either explicitly DEFERRED with a reason and a tag, or DISMISSED with its
rationale — never silently dropped:

- **Has a home** — belongs to a tracked downstream story or sits behind this story's intentional
  seam. Record the rationale and owning item.
- **No home (untracked)** — real, out-of-scope, and NO existing item will pick it up. As PR prose
  it is invisible to the loop forever, so carry it on the hand-back's **untracked-deferral list**
  for `build-item` step 6.5.

**Drop every REFUTED finding** — don't "fix" code the verification stage proved correct. Commit
fixes per `commitConventions.reviewFixFormat` (fallback: `fix(<scope>): <summary> [<itemNumber> review]`); regenerate API artifacts again if routes changed. A genuinely
ambiguous or risky finding is a fork — ask, with your recommendation.

Close the phase with a one-line **review report**: the profile, the breadth picked (and whether
the ceiling clamped it), the lens count (naming the security lens when the auth-boundary floor
added it), the agent count across both stages (**verifiers: G file-groups + A per-finding**), and the tally — raised / fixed / deferred /
dismissed.

## 4. Hand back

Done when the branch holds a built, self-reviewed, all-green story: commits made and pushed,
type-checks / wiring checks green, and the test gate green at the profile's `storyVerify` width.

Report to `build-item`: the item number, a one-line summary, **the profile and its source**,
green-checks confirmation **naming the gate that was run** (the commands, so the caller can see
the width without re-deriving it), the phase-3 review report, and four lists —

- **buildable-now-vs-deferred scope line** (build + review deferrals, each tagged has-a-home vs
  untracked);
- **untracked-deferral list** — load-bearing; step 6.5 turns each into a spliced-in item. Empty is
  fine and normal, but say so explicitly rather than omitting it;
- **dismissed-findings list** — every verified finding the `fixFloor` left unfixed and undeferred,
  each with its one-line rationale, so the PR body can show what was seen and judged rather than
  what was missed. Empty is the normal case under `all-confirmed`; say so rather than omit it;
- **deviations list** — every material divergence from the written spec, not just deferrals: a
  different approach, a false spec assumption (a dependency already shipped, a DTO lacked a field,
  a component already existed), scope cut or added, each with a one-line rationale. This feeds the
  PR body AND the item's as-built reconciliation, so a deviation that only lives in your head ships
  undocumented.

Do NOT open the PR or merge — that is `pr` / `build-item`'s job.
