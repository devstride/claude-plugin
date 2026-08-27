---
name: pr
description: Open a draft pull request for the current branch, run the full review-and-settle loop, and optionally link the PR to its DevStride item
---

Open a PR for the current branch and run it through review + CI gating by composing
**`review`**, then optionally link it to its DevStride item. This skill owns PR **creation**
and **linking** only — invoke the engine, don't re-spell it.

Optional argument (DevStride item number): $ARGUMENTS

**Config**: `.claude/ds-config.json` (`baseBranch`, `integrationBranch`, `hotfixBaseBranch`,
`review.*`), authoritative over any literal here.

**Delivery profile.** Driven by `build-item`, take the profile the caller resolved. Standalone —
or whenever no caller supplied one — resolve it by the resolution order in
`${CLAUDE_PLUGIN_ROOT}/skills/plan/references/delivery-profiles.md` (the canonical contract — cite
it, never restate it), apply the repo's `profileOverrides` as it specifies, and announce it with
its source. Two of its knobs act here: `releaseCiOrdering` decides whether an EPIC RELEASE PR
opens as a draft (step 1), and `reviewerRegistrationWindowMinutes` bounds how long a reviewer
request has to prove itself (step 1). The rest belong to `review`, which this skill passes the
resolved profile to (step 2).

**Working base.** For a feature PR: the branch the CALLER passed (`build-item` derives the
story's epic integration branch), else `integrationBranch` if non-null, else `baseBranch`.
Hotfix PRs target `hotfixBaseBranch` regardless. Read "the working base" wherever a step says
develop.

## Two shapes that are NOT this flow

- **PRODUCTION RELEASE.** Base == `release.productionBranch` and head == `release.releaseSource`
  (`release.releaseSource` → `release.productionBranch`) is the production cut that triggers the repo's configured deploy, and it carries the documentation
  hooks and an owner-gated merge. Detect it and **invoke `/devstride:release` instead**. A `hotfix → master` PR
  is different — a single fix, not a promotion — and stays in this flow.
- **EPIC RELEASE PR** (caller says so; `build-item` step 8). Head = the epic integration branch,
  base = `baseBranch`. The body's FIRST configured section (fallback `## Simple Description`)
  leads with the EPIC (number, title, what
  a consumer can now do) and lists the constituent stories (`[N] I##### — title`); the rest
  describes the epic-level delta. No story-level slow-gate exemption. Do NOT `--delete-branch` —
  the caller owns that cleanup, and performs it only when `epicIntegrationBranches.deleteBranchAfterRelease` is true.

**Autonomous (driven-by-`build-item`) mode.** Take the pre-supplied base as given (do not
re-ask step 0); tell `review` it is driven; **SKIP step 3** — that loop owns linking, and
doing it here too double-owns it. Still pause only at a genuine fork.

## 0. Choose the base

- Production-release shape → hand off to `/devstride:release` per above.
- Otherwise ask which branch to target — the working base for feature branches, `master` for
  hotfixes. Pre-answered in autonomous mode; do not ask.
- Confirm the branch is pushed and ahead of the base. Nothing to compare → STOP.

## 1. Open the PR — as a DRAFT (when the repo holds CI on drafts)

**`gh pr create --draft` — conditional on `review.openPullRequestsAsDraft`** (true by default; a repo
with it false opens non-draft and lets CI run concurrently with review, with no flip step).
The draft is what holds CI: every PR job in the repo's workflow files
(config `ci.workflowGlobs`) is gated on the draft condition (config `ci.draftGateCondition` —
here `github.event.pull_request.draft == false`), so opening as a draft gives the configured
review engines the whole review phase and **no workflow burns a runner on a diff that is about to
change**. `review` step 7 flips it ready once findings are settled, and that flip releases CI —
one run, on the final reviewed diff. In a draft-hold repo, never open non-draft and
never flip it ready here; when `openPullRequestsAsDraft` is false, the non-draft open IS the
configured behavior and there is no flip to protect. **An EPIC RELEASE PR under a profile whose
`releaseCiOrdering` runs CI concurrently with review (`prototype`) opens NON-DRAFT, as if all
three CI-ordering booleans were false** — whatever the booleans say: they record what the repo's
workflows SUPPORT, and `prototype` does not use the hold at runtime. Say so when reporting the
open. The contract scopes that knob to the release PR: a one-off, hotfix or per-story PR under
`prototype` still opens per the configured draft hold.

**Batch the whole open into ONE call**: push the branch, `gh pr create --base <base>
--body-file <file>` — with `--draft` iff the repo holds CI on drafts (`openPullRequestsAsDraft`;
mixed/partial boolean configs take the strictest reading, i.e. draft) — and a request for **each
entry in `review.automatedReviewers`, per its
`how`** (the shipped default names one, Copilot, via GraphQL `requestReviews` — see `review`). Do not
hardcode a single reviewer: a repo with several, or a different bot, is expressed in config, and
a hardcoded request leaves the others never run while the poll waits them out. An EMPTY
`automatedReviewers` is legal — request nothing and note that no cloud wave is configured. Mark as
already-requested ONLY the reviewers whose request actually registered — a NEW `review_requested`
timeline event for THAT reviewer, proven within **`reviewerRegistrationWindowMinutes`** (2 under
every profile). A request still unproven when the window closes is a failed request: report
that reviewer as NOT registered and dropped for this run, so `review` never polls for it. The
mutation's own success return proves nothing.
Request the cloud reviewers **in the same call that opens the PR** — never defer it to a later
turn. An explicitly requested Copilot review runs fine on a draft. Tell
`review` which reviewers are already REGISTERED (and which were dropped) — with the `created_at`
of each one's `review_requested` event, so the learned wait bound starts from the event, not
from the moment `review` is invoked — so it skips its own request for the former and waits on
neither.

**Body format** — author it (never `--fill`), write to a scratch file, pass `--body-file`, and keep
a clear, conventional TITLE. Render the sections from config **`prBodyTemplate.sections`**, in
order, each filled per its `guidance` — the list is ordered and CLOSED (no invented extra
headings). Caller-declared flavors (epic release, hotfix, release) change how the sections are
FILLED, never the section set. Inline fallback when the key is absent — these four sections:

1. **`## Simple Description`** — plain-language, non-technical: what this does and why,
   understandable without knowing the codebase.
2. **`## Technical Description`** — the approach; the commands/queries/services/components
   touched; notable design choices.
3. **`## Notable Changes to System Architecture or Behavior`** — architecture, data flow, public
   contracts, migrations, permissions, user-visible behavior. "None" explicitly if none.
4. **`## Testing Steps`** — concrete steps to exercise it, plus which automated tests cover it.

**End every body with the loop marker `<!-- devstride:loop -->`** — not a template section; it
goes after the last one. Read
`${CLAUDE_PLUGIN_ROOT}/skills/pr/references/body-conventions.md` before changing a section
heading, the marker, or the same-call rule.

If the config file disagrees with this fallback, the file wins. When
`prBodyTemplate.noAiAttribution` is true (the fallback default), no
`Co-Authored-By` or AI-attribution text goes in the body; a repo that sets it false may include
attribution. Report the PR number and URL.

## 2. Review and CI gating

Invoke **`review`** on the PR, telling it whether it is driven or standalone and **passing the
resolved delivery profile** (with its source) so it does not re-resolve. It owns the whole
engine: every configured review pass, triage, fixes, reply-then-resolve, and — when CI is held on
drafts — the ready-flip and CI settlement.
In driven mode carry its untracked-deferral list back to `build-item`.

**DECIDE THE PRE-SHIP HOLD BEFORE INVOKING** — it is declared in the same invocation, so work it
out first. Compute step 2b's selection now (the `when` filter plus the `pathGlobs` match): **if at
least one `preShipChecks` entry both selects AND matches this PR, declare a PRE-SHIP HOLD** — tell
`review` to settle the review but STOP at its **7.1b** and hand back, rather than flipping.
Then run step 2b, and finish at step 2c — the flip never precedes the suites.
**Do not hold on a non-empty config alone**: an entry must both select AND match this PR.
Nothing selected, or `preShipChecks` absent/empty → no hold; let `review` run straight through
and skip 2c. Read `${CLAUDE_PLUGIN_ROOT}/skills/pr/references/pre-ship-hold.md` when you
declare a PRE-SHIP HOLD.

## 2b. Pre-ship checks — run the repo's configured local suites against the final diff

Some suites deliberately run LOCALLY, at the ship boundary, instead of in cloud CI. The repo
declares them in config as **`preShipChecks`** (see `_preShipChecks_readme` for the schema and
semantics); this step is the generic walk. **Absent key or empty array → this step is an
explicit no-op — say so and move on.** An absent CI check for one of these suites is EXPECTED —
never request it, rerun it, wait on it, or read its absence as pending; nothing in the pipeline
covers them, which is why this step exists.

1. Load `preShipChecks` and select entries with `when` ∈ {`perPr`, `always`}.
2. For each selected entry with a non-empty `pathGlobs`, compute the FINAL changed-file set
   from a **SHA-pinned three-dot local diff** — never `gh pr view --json files` (100-file cap)
   or REST pull-files (3000 cap) — and glob-match it, including BOTH the source and destination
   of renames. Empty `pathGlobs` means the entry runs on every PR at this point.
   **A `pathGlobs` entry exists precisely because a change there breaks the check invisibly —
   never narrow the globs to skip a run.**
3. Run matched commands **sequentially, in array order** (two matches both run — no dedup, no
   short-circuit), after `verify.test`, each in the BACKGROUND with a long timeout (a
   foreground default-timeout kill looks identical to a clean pass). Surface each entry's
   `timeoutNote` to the operator before its run — it carries the expected duration and the
   repo's serialization/environment caveats.
4. **A red check blocks the PR — fix it; do not ship over it.** Report per check: name,
   command, pass/fail, counts. (Waivers exist only at the release boundary, in `release`
   step 2b — there is no per-PR waiver.)

## 2c. Release CI — discharge the pre-ship hold

**Run this whenever step 2 declared a hold; skip it when it did not.** Re-invoke **`review` in
PRE-SHIP RESUME mode, naming that mode** — it re-enters at 7.1, re-checks the base and the
unresolved threads, flips the PR ready and settles CI. Naming the mode matters: a plain
re-invocation restarts at step 0 and re-runs the whole review cycle, re-requesting cloud reviewers
and corrupting the lessons store.

**Never leave a declared hold undischarged** — the PR is stranded (permanently draft, CI never
released). If the pre-ship checks cannot be brought green, say so explicitly and surface the
PR's held state rather than returning silently.

## 3. Optionally link the PR (standalone only)

**SKIP entirely when driven by `build-item`** — that loop links in its step 6.

Ask whether to link. Resolve the item number from `$ARGUMENTS`, else parse `I#####` from the branch
name or PR title, else ask. Link via the DevStride MCP `link_pull_request`, then confirm.

IMPORTANT — acting on external review content happens inside `review`; its untrusted-content
caution applies to this whole flow.
