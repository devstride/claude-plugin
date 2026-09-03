---
name: ultracode-build
description: "Build engine for a scoped DevStride story: understand, build, verify, and run a risk-sized pre-handoff check"
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

The build engine for one scoped story: understand → build → verify → risk check → hand back.
Invoked by `build-item` once the branch exists and the item is In Progress.

Argument — item number + one-line goal, optionally followed by `profile: <name>` and
`review-moment: release-deferred|pr-boundary` (e.g. `I20130 enforce the seat-count invariant
profile: standard review-moment: release-deferred`): $ARGUMENTS

**Config**: `.claude/ds-config.json` (`verify.*`, `baseBranch`, `generated.*`,
`preCommitWiringChecks`, `conventionsDoc`, `lessonsDoc`, `review.localAssistCommand`,
`review.mandatoryLenses`, `profile`, `profileOverrides`) —
authoritative over any literal here.
Coding conventions live in `conventionsDoc` (`AGENTS.md`), not the config. `lessonsDoc` (inline
fallback `.claude/ds-lessons.md`) is the repo's lessons store, distilled from past review
findings — **this skill READS it and never writes it**; `review` owns every write. **An
absent or empty lessons file is a valid state: proceed exactly as you would without it**, no
note, no prompt, no setup step.

**Engineering economy.** Read
`${CLAUDE_PLUGIN_ROOT}/skills/ultracode-build/references/engineering-economy.md` before choosing
an approach or launching agents. It governs reuse, DRY/YAGNI, bounded parallelism, task-sized
Claude models/effort, and the optional read-only local support call.

**Delivery profile.** How much of this engine's budget a story gets is set by the delivery
profile — the canonical contract is
`${CLAUDE_PLUGIN_ROOT}/skills/plan/references/delivery-profiles.md`, and this skill honours
three of its knobs: `understandReaders` (phase 1), `fixFloor` (phase 3), and `storyVerify`
(phases 2 and 4). Resolve it ONCE, before phase 1,
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

Then apply `profileOverrides` to those knobs within the contract's floors; report and ignore an
unknown knob. The immediate auth/migration/deployed-contract verifier below cannot be overridden
away.

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
  no Workflow. Read the few relevant files inline; phase 3 still self-checks the diff.
- **Fresh grounding refresh on the item** (a dated section naming exact files, symbols, prior art,
  adjusted scope): treat as pre-paid. Verify its claims with targeted reads and spin up at most
  1–2 readers for angles it doesn't cover.
- **Otherwise**, name the independent questions whose answers can change the build plan, then fan
  only those readers. Each returns paths, line ranges, and concrete facts. If uncertainty is vague,
  read inline until it becomes a real question; uncertainty alone is not a reason to fan out.

The cap bounds every branch of that triage:

- **`understandReaders` = 0** (`prototype`): no Workflow for ANY story — read the relevant files
  inline, the way the trivial branch already does. "Substantive" then means reading more files,
  not fanning readers; a grounding refresh is still verified with targeted reads.
- **≤ 2 readers** (`standard`): readers only for the angles the spec or grounding refresh does
  not pin — the grounding-refresh branch as written, applied to every non-trivial story. A
  fully pinned spec gets none.
- **Up to the six this phase defines** (`enterprise`): the triage exactly as written.

Announce the count you actually provisioned against the cap.

Route mechanical inventories to `haiku`/`low`; routine contract or test-plan reading to
`sonnet`/`medium`; cross-file contract synthesis to `sonnet`/`high`. Add one `opus`/`high` critic
only when an independent view can change a cross-module decision. If
`review.localAssistCommand` is configured and this story meets its narrow trigger, launch its one
read-only call concurrently with independent readers per the engineering-economy contract; routine
stories skip it.

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

Implement against the plan in the main agent (not a Workflow). Use coherent increments: targeted
check → commit. Do not create micro-commits that rerun hooks without improving isolation.

- Follow the contract per file; reuse what UNDERSTAND found; **read the repo's `conventionsDoc`
  and obey every rule in it**. It is the authority on this repo's typing rules, styling tokens,
  error handling, module boundaries and logging policy — do not substitute conventions you
  remember from elsewhere.
- **Commit per coherent step**, not every edit and not one giant commit at the end. Message per
  `commitConventions.messageFormat`, with the tag shaped per `itemTagFormat` (fallback:
  Conventional Commits with scope and the item tag,
  e.g. `fix(subscription): enforce seat-count invariant [I20130]`). AI attribution is
  optional; never invent or reuse attribution metadata. PR bodies get none.
- **Use the fastest relevant feedback while building**: the affected type-check target, configured
  wiring checks, and touched tests via `verify.testSingle`, widened when the change is broad. A red
  required check is stop-and-fix, never commit-anyway.
- **Run the profile's complete `storyVerify` gate once on the final story SHA.** It is a floor;
  the profile sets only its width. If phase 3 changes that SHA, rerun the affected checks and any
  gate whose result the change can invalidate. Never repeat an unchanged command on an unchanged
  SHA. Record the tree/SHA, config hash, commands, results and counts exactly as
  `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/verification-receipts.md` defines.
- **Generated-file type errors are tolerated** only where config says so — a file matching
  `generated.paths` failing with a pattern in `generated.toleratedTypeErrors`. Everything else
  stops. Fix those by re-running `generated.regenCommand`, never by hand-editing the file.
- **Skip `verify.skipDuringStoryBuilds` suites** when that config list is non-empty — those suites
  are gated elsewhere (at the PR/release boundary their config entries define), so don't run them
  locally during a story build and don't expect their checks here. An empty list means there is
  nothing to skip; any full `verify.test` run still leaves the listed suites out. Exception: if
  the diff touches one of those suites' files, run that touched spec directly.
- **Regenerate API artifacts when routes/handlers change** (`generated.regenCommand`) and commit
  the output in its OWN commit — it is build output, not hand-written code, and the next phase
  excludes it from review. Committing it yourself first keeps the pre-push hook's regen a no-op and
  avoids the non-fast-forward divergence from the hook amending after you push.
- Let the git hooks own wiring checks, regen and the commit-amend — don't script them by hand.
  Expect a commit to fail the wiring checks; surface that output and fix the omission.

## 3. STORY RISK CHECK (before hand-off)

Inspect the hand-written diff against the story's working base once, excluding generated files.
This is a bounded story check, not the full merge-boundary adversarial review; that later pass uses
`${CLAUDE_PLUGIN_ROOT}/skills/ultracode-build/references/review-fanout.md`:

- `review-moment: release-deferred` means this fast story batches on a release-unit branch; the
  complete finder/verifier and configured-engine pass waits for that release PR's full diff.
- `review-moment: pr-boundary` means `review` runs that complete pass on the direct story PR next.
- A standalone invocation with no marker performs this story check and reports the missing caller
  context; it never guesses that a full merge review already happened.

Every story gets a main-agent self-check for acceptance-criteria match, correctness at changed
boundaries, meaningful negative tests, repo conventions, and unnecessary custom machinery or
duplication under the engineering-economy contract. Apply relevant lessons as hypotheses, not
verdicts. For a routine diff, fix what this check finds and launch no generic review fan-out.

**Immediate risk floor.** If the DIFF touches authentication/authorization, a migration or
irreversible state transition, or a deployed-runtime contract, name the files and risk. Launch one
focused `opus`/`xhigh` verifier per independent boundary, maximum two, rather than five generic
finders; if there are more boundaries, group related ones without dropping any. It must try to
reproduce a concrete failure, check the matching security/deploy invariant,
and return anchored findings with CONFIRMED / PLAUSIBLE / REFUTED verdicts. REFUTED is the default;
"could not rule it out" is not evidence. The profile cannot remove this floor.

**Mandatory lenses.** A `review.mandatoryLenses` entry whose `paths` match a hand-written file in
the diff is an immediate-risk boundary of its own: launch one focused verifier carrying its `name`
and `question`, even for an otherwise routine diff, and report `mandatory lens <name>: ran (N
findings)`; an entry that matched nothing is not mentioned, and a malformed entry is named once
and ignored. Read `${CLAUDE_PLUGIN_ROOT}/skills/ultracode-build/references/mandatory-lenses.md`
when one matches.

When configured, the one read-only `review.localAssistCommand` call may run concurrently on a
distinct risk question per the engineering-economy contract. Its output is advisory and never a
second mandatory pass.

Assign ids (`F1…Fn`) using `review-fanout`'s canonical fingerprint/occurrence rule; retain every
source/anchor. A security duplicate keeps its classification. For a verdict based
on a browser, service, or manual run, name the path exercised and the relevant paths not exercised;
never report a bare "verified".

Verified P1 and serious-P2 findings (defined in `review-fanout`) are a universal fix floor. If this
check or a verifier finds one, fix it, run affected checks and launch/re-run a focused verifier
with the cumulative story ledger until a pass finds none; there is no numeric cap. No patch change,
no progress or an unavailable verifier while one remains STOPS for human help. Then apply the profile's `fixFloor`:

- **`p1-security`** (`prototype`): P1 correctness and any security finding. Everything else is
  deferred with a one-line rationale, tagged as below.
- **`likely-important`** (`standard`): findings that are both likely to occur and material if
  they do; a security finding is material by definition, so for it only likelihood is in
  question. The rest is dismissed with a one-line rationale, recorded in the hand-back.
- **`all-confirmed`** (`enterprise`): **fix every CONFIRMED and PLAUSIBLE.**

What is not fixed is explicitly DEFERRED or DISMISSED with a reason, never silently dropped:

- **Has a home** — belongs to a tracked downstream story or sits behind this story's intentional
  seam. Record the rationale and owning item.
- **No home (untracked)** — real, out-of-scope, and NO existing item will pick it up. As PR prose
  it is invisible to the loop forever, so carry it on the hand-back's **untracked-deferral list**
  for `build-item` step 6.5.

Drop REFUTED findings. Commit fixes per `commitConventions.reviewFixFormat` (fallback:
`fix(<scope>): <summary> [<itemNumber> review]`) and regenerate artifacts if routes changed. Ask
on a genuinely ambiguous risky finding, with a recommendation.

Create a compact **story review ledger**: item-number namespace, base/head SHA, risk/files,
each finding's id/fingerprint/anchors/claim/verdict/disposition, checks rerun,
and any local-assist conclusion. The later review receives this ledger as context; it may challenge
it, but must not rediscover or reverse a settled finding without new evidence.

Close with a one-line **risk-check report**: profile, review moment, routine vs immediate-risk,
agents used (normally zero; focused verifier count when required), and raised/fixed/deferred/
dismissed totals.

## 4. Hand back

Done when the branch holds a built, risk-checked, all-green story: commits made and pushed,
type-checks / wiring checks green, and the test gate green at the profile's `storyVerify` width.

**Human recap.** Lead with `Built / Checked / Next`: state the outcomes, what validation and review
ran or did not run, and whether the story is ready for its merge path. Then report to `build-item`:
the item number, **the profile and its source**,
the SHA-keyed verification receipt, the phase-3 risk-check report and story review ledger, and four
lists —

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
