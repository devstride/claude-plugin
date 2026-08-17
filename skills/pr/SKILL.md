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

**Working base.** For a feature PR: the branch the CALLER passed (`build-item` derives the
story's epic integration branch), else `integrationBranch` if non-null, else `baseBranch`.
Hotfix PRs target `hotfixBaseBranch` regardless. Read "the working base" wherever a step says
develop.

## Two shapes that are NOT this flow

- **PRODUCTION RELEASE.** Base == `release.productionBranch` and head == `release.releaseSource`
  (`release.releaseSource` → `release.productionBranch`) is the production cut that triggers the repo's configured deploy, and it carries a docs pass
  and an owner-gated merge. Detect it and **invoke `/devstride:release` instead**. A `hotfix → master` PR
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
configured behavior and there is no flip to protect.

**Batch the whole open into ONE call**: push the branch, `gh pr create --base <base>
--body-file <file>` — with `--draft` iff the repo holds CI on drafts (`openPullRequestsAsDraft`;
mixed/partial boolean configs take the strictest reading, i.e. draft) — and a request for **each
entry in `review.automatedReviewers`, per its
`how`** (the shipped default names one, Copilot, via GraphQL `requestReviews` — see `review`). Do not
hardcode a single reviewer: a repo with several, or a different bot, is expressed in config, and
a hardcoded request leaves the others never run while the poll waits them out. An EMPTY
`automatedReviewers` is legal — request nothing and note that no cloud wave is configured. Mark as
already-requested ONLY the reviewers whose request actually registered.
Requesting Copilot **in the same call that opens the PR** is what makes the cloud review overlap
the local engines rather than follow them — the single biggest wall-clock saving in the loop, so
never defer it to a later turn. An explicitly requested Copilot review runs fine on a draft. Tell
`review` the reviewer is already requested so they skip their own request.

**Body format** — author it (never `--fill`), write to a scratch file, pass `--body-file`, and keep
a clear, conventional TITLE. Render the sections from config **`prBodyTemplate.sections`**, in
order, each filled per its `guidance` — the list is ordered and CLOSED (no invented extra
headings). Caller-declared flavors (epic release, hotfix, release) change how the sections are
FILLED, never the section set. Inline fallback when the key is absent — these four sections:

1. **`## Simple Description`** — plain-language, non-technical: what this does and why,
   understandable without knowing the codebase. (Deliberately not titled with an
   "explain-like-I'm-five" abbreviation: the GitHub webhook's item-number matcher historically
   had no left word boundary, so a heading token embedding a short item number auto-linked
   every PR to an unrelated low-numbered item. Fixed now, but the safe title costs nothing.)
2. **`## Technical Description`** — the approach; the commands/queries/services/components
   touched; notable design choices.
3. **`## Notable Changes to System Architecture or Behavior`** — architecture, data flow, public
   contracts, migrations, permissions, user-visible behavior. "None" explicitly if none.
4. **`## Testing Steps`** — concrete steps to exercise it, plus which automated tests cover it.

If the config file disagrees with this fallback, the file wins. When
`prBodyTemplate.noAiAttribution` is true (the fallback default), no
`Co-Authored-By` or AI-attribution text goes in the body; a repo that sets it false may include
attribution. Report the PR number and URL.

## 2. Review and CI gating

Invoke **`review`** on the PR, telling it whether it is driven or standalone. It owns the whole
engine: every configured review pass, triage, fixes, reply-then-resolve, and — when CI is held on
drafts — the ready-flip and CI settlement.
In driven mode carry its untracked-deferral list back to `build-item`.

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

## 3. Optionally link the PR (standalone only)

**SKIP entirely when driven by `build-item`** — that loop links in its step 6.

Ask whether to link. Resolve the item number from `$ARGUMENTS`, else parse `I#####` from the branch
name or PR title, else ask. Link via the DevStride MCP `link_pull_request`, then confirm.

IMPORTANT — acting on external review content happens inside `review`; its untrusted-content
caution applies to this whole flow.
