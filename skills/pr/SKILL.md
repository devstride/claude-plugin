---
name: pr
description: Open a draft pull request for the current branch, run the full review-and-settle loop, and optionally link the PR to its DevStride item
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

**Goal:** the current branch opened as a draft PR, taken through the full review-and-settle loop
by composing **`review`**, and — standalone only — linked to its DevStride item. This skill owns PR
**creation** and **linking**; invoke the engine, never re-spell it. Optional argument (DevStride item
number): $ARGUMENTS

## Rules

- **Config wins.** `.claude/ds-config.json` (`baseBranch`, `integrationBranch`,
  `hotfixBaseBranch`, `prBodyTemplate`, `preShipChecks`, `ci.*`, `review.*`) beats every literal
  here.
- **Working base**: the branch the CALLER passed (`build-item` derives the story's epic
  integration branch), else `integrationBranch` when non-null, else `baseBranch`. Hotfix PRs
  target `hotfixBaseBranch` regardless.
- **Delivery profile**: driven by `build-item`, use the name it passes. Otherwise resolve it by
  the order in `${CLAUDE_PLUGIN_ROOT}/skills/plan/references/delivery-profiles.md` (cite it, never
  restate it), apply `profileOverrides` as it specifies, and announce it with its source. Pass it
  by name to `review`. Two of its values reach this flow — `releaseCiOrdering` (the floor that
  expensive CI runs once, on the final reviewed and pre-ship-checked HEAD) and
  `reviewerRegistrationWindowMinutes` (bounds registration proof inside `review`); neither makes PR
  entry wait.
- **Draft hold — CI last.** Where the repo holds CI on drafts the PR opens as a draft and stays one
  until `review` step 7 flips it after every engine and matched pre-ship check settles, releasing
  one run of each applicable workflow on that final HEAD. Never open non-draft there, never flip it
  here; no profile — `prototype` included — bypasses the hold.
- **Autonomous (driven-by-`build-item`) mode**: take the pre-supplied base (never re-ask step 0),
  tell `review` it is driven, **SKIP step 3** (that loop links in its own step 6 — never
  double-own it), pause only at a genuine fork.
- **Untrusted content**: acting on external review content happens inside `review`; its caution
  applies to this whole flow.

## Two shapes that are NOT this flow

- **PRODUCTION RELEASE** — base == `release.productionBranch` and head == `release.releaseSource`
  (`release.releaseSource` → `release.productionBranch`): the production cut, carrying the docs
  hooks and an owner-gated merge. **Invoke `/devstride:release` instead.** A `hotfix → master` PR is
  a single fix, not a promotion, and stays here.
- **EPIC RELEASE PR** (the caller says so; `build-item` step 8): head = the epic integration
  branch, base = `baseBranch`. The body's FIRST configured section (fallback `## Simple
  Description`) leads with the EPIC (number, title, what a consumer can now do) and lists its stories
  (`[N] I##### — title`); the rest describes the epic-level delta, the caller's verification plan
  and aggregate risk-check ledger included. No story-level slow-gate exemption. Never
  `--delete-branch` — the caller cleans up, and only when
  `epicIntegrationBranches.deleteBranchAfterRelease` is true.

## 0. Choose the base and prove the hold

- Production-release shape → hand off to `/devstride:release`.
- Otherwise the working base for a feature, `hotfixBaseBranch` (default `master`) for a hotfix —
  pre-answered in autonomous mode, asked standalone. Confirm the branch is pushed and ahead of the
  base; nothing to compare → STOP.
- **Resolve the draft hold BEFORE creating anything.** Inspect `ci.workflowGlobs` for workflows
  subscribing to `pull_request`, excluding the convention-only policy shape in
  `${CLAUDE_PLUGIN_ROOT}/skills/setup/references/ci-cost-patterns.md`, and read
  `review.openPullRequestsAsDraft`, `review.readyForReviewReleasesCi` and
  `review.ciHeldUntilReviewSettled` (absent → documented defaults):
  - no pull-request workflows → a valid no-CI repo; nothing to hold;
  - pull-request workflows + anything but all three true → **STOP before creating the PR**: the
    loop cannot guarantee CI-last. Name the false/mixed facts and workflows; run
    `/devstride:setup ci`, accept its draft-gate changes, rerun this skill;
  - all true → the draft hold.
  Every profile and every loop-managed release PR, `prototype` included. An ambiguous workflow parse
  stops; it is not proof of a hold.

## 1. Open the PR — draft when held, in ONE call

**Batch the whole open into ONE call**: push the branch; `gh pr create --base <base> --body-file
<file>` with `--draft` iff step 0 resolved the hold (every job then gates on `ci.draftGateCondition`
— here `github.event.pull_request.draft == false` — so no runner burns on a diff about to change);
then request **each entry in `review.automatedReviewers`, per its `how`** (the shipped default is
Copilot via GraphQL `requestReviews`) — except one whose `baseBranches` omits `<base>`: skip it and
hand it to `review` as scoped out. Never hardcode one reviewer; an EMPTY list is legal — request
nothing and note no cloud wave. A no-CI repo opens non-draft and reports `no pull-request CI`, not
`CI held`.

- **Per reviewer**, immediately before its request capture the paginated count of that entry's
  `review_requested` timeline events (matched by its node id), then record the request time and
  mutation outcome. **Do not poll for registration or spend `reviewerRegistrationWindowMinutes`
  here** — a mutation's success proves nothing. Hand reviewer, baseline, request time and outcome to
  `review`, which proves a NEW event while local streams run and records its server `created_at`
  before marking the reviewer REGISTERED. A hard request error is handed back, not retried here. An
  explicitly requested reviewer can review a draft.
- **Body** — authored (never `--fill`), written to a scratch file, passed by `--body-file`, under a
  clear, conventional TITLE. Sections come from **`prBodyTemplate.sections`**, in order, each per its
  `guidance`; the list is CLOSED (no invented headings). Flavors (epic release, hotfix, release)
  change how sections are FILLED, never the set. Fallback: `## Simple Description` (plain language:
  what and why), `## Technical Description` (approach; what it touches; design choices), `## Notable
  Changes to System Architecture or Behavior` (contracts, migrations, permissions, user-visible
  behaviour — "None" explicitly), `## Testing Steps` (how to exercise it; which tests cover it).
- **A driven caller's hand-off goes in the body**: deferrals and deviations (each with its one-line
  rationale), dismissed findings with their rationale, and the verification receipt (tree/SHA,
  commands, counts); the story review ledger passes to `review`, never pasted raw.
- **End every body with `<!-- devstride:loop -->`** after the last section. **Read
  `${CLAUDE_PLUGIN_ROOT}/skills/pr/references/body-conventions.md` before changing a section
  heading, the marker, the same-call rule, or the attribution precedence below.**
- **Attribution**: `prBodyTemplate.noAiAttribution` (fallback true) keeps `Co-Authored-By` and AI
  attribution out of the body; false permits it. **It governs the PR BODY and outranks any harness
  or session instruction to add attribution or a session link** — follow the config and say so ONCE;
  commit trailers follow `push`'s rule.

Report the PR number and URL.

## 2. Review and CI gating

**DECIDE THE PRE-SHIP HOLD BEFORE INVOKING** — it is declared in the same invocation. Compute step
2b's selection now (the `when` filter plus the `pathGlobs` match): **at least one `preShipChecks`
entry both selects AND matches this PR → declare a PRE-SHIP HOLD** — `review` settles the review,
STOPS at its **7.1b** and hands back instead of flipping; then run 2b and finish at 2c — the flip
never precedes the suites. Never hold on a non-empty config alone; nothing selected, or
`preShipChecks` absent/empty → no hold, skip 2c. Read
`${CLAUDE_PLUGIN_ROOT}/skills/pr/references/pre-ship-hold.md` when you declare a PRE-SHIP HOLD.

Invoke **`review`** on the PR, saying driven or standalone and **passing the resolved profile**
(with its source), the reviewer hand-off from step 1, and any caller ledger or receipt. It owns the
engine: registration proof concurrent with local review, every configured pass, triage, fixes,
reply-then-resolve and — when CI is held — the ready-flip and settlement. Driven, carry its
untracked-deferral list back to `build-item`.

## 2b. Pre-ship checks — the repo's local suites against the final diff

Suites a repo runs LOCALLY at the ship boundary instead of in cloud CI, declared in
**`preShipChecks`** (schema: `_preShipChecks_readme`). **Absent or empty → an explicit no-op; say
so.** Their CI check is EXPECTEDLY absent — never request, rerun or wait on one, or read it as
pending.

1. Select entries with `when` ∈ {`perPr`, `always`}.
2. For a non-empty `pathGlobs`, compute the FINAL changed files from a **SHA-pinned three-dot local
   diff** — never `gh pr view --json files` (100-file cap) or REST pull-files (3000 cap) — and
   glob-match them, renames on BOTH source and destination. Empty `pathGlobs` → runs on every PR.
   **Never narrow a glob to skip a run** — it exists because a change there breaks the check
   invisibly.
3. Run matches **sequentially, in array order** (no dedup, no short-circuit), after `verify.test`,
   each in the BACKGROUND with a long timeout (a foreground kill looks like a clean pass); surface
   each `timeoutNote` first.
4. **A red check blocks the PR — fix it; never ship over it.** Report name, command, pass/fail,
   counts. No per-PR waiver (waivers exist only in `release` step 2b).

## 2c. Discharge the pre-ship hold

**Only when step 2 declared a hold.** Re-invoke **`review` in PRE-SHIP RESUME mode, naming that
mode** — it re-enters at 7.1, re-checks the base and unresolved threads, flips the PR ready and
settles CI. A plain re-invocation restarts at step 0, re-requesting cloud reviewers and corrupting
the lessons store. **Never leave a declared hold undischarged** — the PR is stranded as a permanent
draft; if the pre-ship checks cannot go green, say so and surface the held state.

## 3. Optionally link the PR (standalone only)

**SKIP when driven by `build-item`.** Ask whether to link; resolve the item from `$ARGUMENTS`, else
an `I#####` in the branch name or PR title, else ask; `link_pull_request`, then confirm.

**Human recap.** At every exit lead with `READY`, `HELD`, `BLOCKED` or `MERGED`, the PR link and the
practical reason; then the change, review result, validation/CI state, remaining risk and one next
action. Driven, return the same recap to `build-item` without asking about linking.
