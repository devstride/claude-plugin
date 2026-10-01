---
name: build-item
description: "Orchestrate one DevStride work item end-to-end: select, branch, build, review, merge, and completion ritual — epic stories batch onto the epic's integration branch in fast develop mode (local engines, no per-story PR) and the fully-reviewed epic release PR carries them to develop; one-off items ship to develop with the full per-story PR ritual, or batch on a configured support train"
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

**Goal:** ONE DevStride one-day leaf item (this org's Story or Defect types) delivered end-to-end —
select → In Progress → branch → build → review → merge → ritual → sync → next. This ORCHESTRATOR
owns ONLY the DevStride glue (selection, lane moves, the completion ritual); it composes the other
delivery skills — **invoke them by name; never re-spell what they do.**

Argument — an item number, or `next`/empty for the next unblocked item; `next under I20100`, or
**`I20100` alone, means "the next unblocked item under this root"** — a bare plan root (any grouping
level) is a SCOPE, never a story to build. An item outside a sequenced plan is auto-detected as a
one-off: $ARGUMENTS

## Hard floors — no profile, override or shortcut removes these

- **The DevStride MCP targets PRODUCTION.** Lane moves, comments and the ritual write live items
  immediately; the MCP cannot exercise branch code.
- **`.claude/ds-config.json` wins over every literal here**; re-read it EVERY iteration. Commands
  (verify/test/lint, regen, local-environment, any pool or secrets CLI a repo documents) come from
  config or `conventionsDoc`, never from memory.
- **Skill freshness.** Skill text remembered from an earlier iteration or across a compaction is
  EXPIRED; re-invoke each composed skill when needed (cost: `references/progress-table.md`).
- **Name the fields you read.** Default projections and `search_items` OMIT `relationships` and
  `description`; read them with `get_item(view: 'full')`. Absence is never data.
- **Never compose an item number.** Every `I#####` in a comment, commit or PR body is
  `get_item`-verified; work needing an item gets it created BEFORE any text cites it.
- **Dates only with the auto-scheduler OFF** — step 6's date write applies
  `${CLAUDE_PLUGIN_ROOT}/skills/rationalize-gantt/references/auto-scheduler-off.md` first.
- **Review first, CI once.** A loop PR stays a draft (`review.openPullRequestsAsDraft`, every
  profile) until every configured engine settles; `review` step 7's ready-flip releases CI once, on
  the final review-settled SHA. Never flip it yourself; a `skipping` or absent check never passes.
- **Safety continuation.** A verified P1 or serious P2 is fixed before merge under every profile,
  re-checked with the cumulative ledger and no numeric cap; no patch change, no progress or an
  unavailable required reviewer while one remains STOPS for human help.
- **Deploy safety travels with the diff.** Migrations are idempotent and rolling-deploy safe;
  reshaped durable events stay readable by both. `ultracode-build`'s focused verifier on auth,
  migration, irreversible-state or deployed-runtime changes fires from the DIFF, not the plan's
  theme, under every profile — `extended` included — as does each matching `review.mandatoryLenses`
  finder. Neither is skippable.
- **Production merges are the owner's.** This loop merges only into the working base or
  `epicIntegrationBranches.releaseTarget`; it surfaces `/devstride:release`, which merges to
  `release.productionBranch` only on the owner's explicit yes.
- **Checkout pool — lease, never mint.** When the repo's `conventionsDoc` or config declares a fixed
  checkout pool, work only in a member held under a lease. Never create a worktree or instance
  unless the owner asks in this conversation; never delete another session's lease. Pool, lease name
  and hand-back come from the repo, never hard-coded; protocol in `ground-truth-at-start.md`.
- **Serial by design.** "Parallel waves" are SHAPE: `branch-feature` aborts on a dirty tree; tests
  share infrastructure `localEnvironment.instanceBoundTo: directory` does NOT isolate; the MCP
  writes production. `localEnvironment` never makes the loop concurrent; a human fans out the
  ready-set.
- **Full-auto through merge.** PAUSE only at a genuine fork: a user's human/infra decision, an
  ambiguous or unverifiable finding, a destructive or outward-facing action. Record every deferral;
  never skip silently.
- **The plan is a HYPOTHESIS.** Validate the spec against the ACTUAL code and correct the item's
  description as the work firms up — the item, not the PR, is the durable source of truth.
- **Develop only receives a COMPLETE release unit** — refreshed, fully reviewed, every applicable
  gate green — or a one-off that settled the same gates. Out-of-scope findings become items (6.5).

## Delivery profile — resolve once per story, announce with its source

Knobs, floors, resolution order and root marker live ONLY in
`${CLAUDE_PLUGIN_ROOT}/skills/plan/references/delivery-profiles.md` — never restate its table. This
skill honours `perStoryPullRequest` (4), `storyVerify` (4a), `autoRelease` and `releaseCiOrdering` (8).

- **Resolve once the story is SELECTED**, by the contract's order: explicit word in `$ARGUMENTS`
  (`prototype`/`standard`/`extended`/`enterprise`) → root marker → config `profile` → `standard`.
  The marker walks the story's ancestors (`hierarchy` for the chain, `get_item` with `view: 'full'`
  each) and takes the NEAREST marker. A one-off skips only the marker step. Never carried over from
  the previous story.
- **Announce it WITH ITS SOURCE** — `profile: extended — from the plan root I20100` — in the
  `Profile` row and handoff memory; pass it **by name**, `profile: <name>`, to `ultracode-build` (3),
  `review` (4a, 4b) and `pr` (4b, 8), which never re-resolve it.
- **Branch on EFFECTIVE knobs, never the name**: profile default → `profileOverrides` → a PRESENT
  dedicated key, resolved before any decision reads them. A present
  `epicIntegrationBranches.autoRelease` or `fastStoryMerges.enabled` wins, its contradiction with
  the profile reported aloud; unknown overrides are reported and ignored; none lowers a floor.
- **The three `review.*` CI-ordering booleans describe what the workflows SUPPORT**: every profile
  uses the supported hold; PR workflows without one are a setup fault.

## Progress table — at every step transition

One row per NUMBERED step in this skill's names (CI release/settle belong to `review` step 7), the
`Profile` row with its source, every configured engine its own row and an unconfigured one an
explicit "not configured" row, each matched `mandatory lens <name>: ran (N findings)`, step 8 `n/a`
on a one-off. **EVIDENCE, not intent**: "request registered in timeline", never "requested";
"non-applicable (no path match, base develop, no label)", never a bare "skipped"; a missing CI
check says `skipping` or never ran, and why. The fast path shows 4a/5a with the deferred cloud rows
visible. A render, never a gate. **Read
`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/progress-table.md` at the first render in a
session or after a compaction.**

## Working base — epic integration branches

Read "the working base" wherever a step says develop; re-derive it per RELEASE UNIT. Precedence:

1. An explicit branch in `$ARGUMENTS`, or config `integrationBranch` non-null.
2. **A release-unit ancestor AND `epicIntegrationBranches.enabled`** → its integration branch. Walk
   `parentNumber` up, typing each ancestor with `get_item`, matching `hierarchyRoles.releaseUnit`
   (`hierarchy` lists `{itemNumber, title}`, never types); never inspect only the direct parent.
   With `hierarchyRoles` absent, resolve BOTH roles via `get_work_type_hierarchy` (leaf = the bottom
   childless levels; release unit = the level above, spelling included — never assume "Epic"); that
   backs every `hierarchyRoles.leaf` read here. A CONFIGURED `releaseUnit` no ancestor matches is
   checked against `get_work_type_hierarchy` — a renamed type or typo STOPS with a question. Name
   per `epicIntegrationBranches.pattern` / `slugRule`, dated at CREATION, never re-minted. Resolve:
   handoff memory → `git ls-remote --heads origin`, kept by an anchored match of that pattern,
   `<epic-number>` (else the slug) filled in, others wildcards (one → reuse, several → ask; none →
   the legacy `*/<epic-number>-*`, a hit → ask) → create off a fresh `baseBranch` and push. Cache
   per epic; **announce reused or created.**
3. **A one-off AND `supportTrain.branch` set** → the train, unless `support-train.md` routes it to
   `baseBranch` (announced).
4. **Otherwise** → `baseBranch`. A disabled flag falls back.

Stories merge into it (why: `references/epic-release.md`), skipping `verify.skipDuringStoryBuilds`
suites; the last leaf's merge triggers step 8. **The working base and the effective
`perStoryPullRequest` pick the path** — integration branch → fast develop mode (4a), the train → 4a
only when `supportTrain.fastMerges` is true, `baseBranch` → the full PR ritual (4b); announce it.
**Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/support-train.md` when
`supportTrain.branch` is set.**

## One-off / no-plan single-shot mode

Detect before plan-root resolution. A bare root LOOKS like an item, so TEST:
`get_item(view: 'full', fields: ['number','title','workType','relationships'])`, and apply the
heuristic only to `hierarchyRoles.leaf` types (a container is the plan scope). **No `[N]` prefix AND
no `blocked_by`/`blocks` edge → one-off**; both → plan mode; exactly one → plan mode if a root
resolves, else state your read and ask. **Steps 1–6 run VERBATIM.** Deltas:

- **Step 0** — no root, ready-set or selection. **SKIP THE EPIC-BRANCH DERIVATION TOO — the working
  base is the support train when configured (precedence 3), else `baseBranch`** — never reason "a
  one-off has no release-unit ancestor". Gating, scope and spec checks still run; the profile skips
  only the marker. **4b under every profile**, its PR its only cloud gate — except 4a on a train
  with `supportTrain.fastMerges` true, whose PR into develop is the full pass. **Read
  `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/epic-release.md` before changing the one-off
  classification or its step-0 delta.**
- **Step 6.5** — follow-ups become their own one-offs (`/devstride:create-story` /
  `/devstride:create-defect`), never `insert-*`; below-floor defects keep the DEFERRED placement
  under the root this item resolves to.
- **Step 7** — no loop, no persisted root: sync, clean tree, close out, TERMINATE; no release
  countdown.

## 0. Select the story

- **Ground truth first.** Hold your checkout under the pool rule, `git fetch --prune origin`, and read
  what OTHER authors landed on the base (and epic) branch since the handoff — say so when another
  session appears active. Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/ground-truth-at-start.md`.
- **Plan root**: `$ARGUMENTS`, else handoff memory; not ONE unambiguous root while several plans are
  open → STOP and ask.
- A given story number IS the story. Otherwise apply
  `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/next-unblocked.md` in full, projection warning
  included. **Never auto-select from the deferred container.** Surface the whole ready-set.
- **DRY-CHAIN / TERMINAL:** no not-Done, non-gated, unblocked candidate → exit cleanly, never
  re-ask, saying which: plan complete / N blocked by X, Y / N gated. Suggest `/devstride:plan <root>`
  only when the chain ran out; never invoke it.
- **GATING CHECK** (a decision that is the user's → flag, next candidate), **SCOPE CHECK**
  (buildable now vs deferred, recorded), **VALIDATE THE SPEC** (re-fetch with `view: 'full'`; confirm
  paths, symbols and assumptions against the code).
- Resolve the profile; report item, title, ready-set, profile with source, buildable-now line.

## 1. Mark In Progress

`update_item` → In Progress (lane id from the work type's lane collection via
`get_workspace_context`); confirm it moved before branching.

## 2. Branch

Invoke **`branch-feature`** with `I<number>-<short-slug>`, passing the working base explicitly.

## 3. Build

Invoke **`ultracode-build`** as `I<number> <goal> profile: <name> review-moment:
<release-deferred|pr-boundary>` (4a vs 4b). It returns the risk-check report and story review
ledger, a verification receipt keyed to the final tree, and four lists — deferrals, deviations,
untracked deferrals, dismissed findings. Deferrals + deviations → PR body (4b) and step 6; untracked
→ 6.5; dismissed → PR body (4b) or merge-commit body (5a), never step 6.

## 4. Review — the working base picks the path, never the diff

Integration branch → **4a** when `fastStoryMerges.enabled` is `true`, or ABSENT under `prototype` (a
present `false` wins, routes to 4b and is reported). `baseBranch` → **4b**, every profile; the train
per `supportTrain.fastMerges`. Never mix: 4a toward develop reaches production never cloud-reviewed.

### 4a. FAST DEVELOP MODE — epic-branch stories, no per-story PR

In-scope cloud reviewers, CI and the full adversarial pass move to the epic release PR. **THE FLOOR:** no
completed `ultracode-build` risk check (immediate-risk verifiers and matched lenses included) or no
valid verification receipt → **4b**, saying why.

- **`review` in LOCAL-ONLY mode** with the epic base, profile and caller ledger: no routine second
  engine (a configured local CLI is no story tax), but it still owns triage, fixes and lessons.
- **Fix every fix-in-story finding it returns** (its `fixFloor` triage; a reasoned deferral is not
  re-imposed) per `commitConventions.reviewFixFormat` (fallback
  `fix(<scope>): <summary> [<itemNumber> review]`); homeless out-of-scope or below-floor findings →
  the untracked-deferral list.
- **Local suites are the gate** (`fastStoryMerges.requireLocalVerifyGreen`), width = the effective
  `storyVerify`. Per `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/verification-receipts.md`,
  an unchanged tree + command set is REUSED; fixes rerun affected checks plus the required gate.
  Commands and counts go in the merge-commit body. Red is a STOP.
- **No PR, no draft, no cloud request, no CI poll** — an absent check is neither pending nor
  skipped. Never open a PR "for the record".

### 4b. FULL PR RITUAL — develop-base stories and one-offs

Invoke **`pr`** in autonomous (driven-by-`build-item`) mode with the working base pre-answered and the
profile by name — `review` owns the cycle target, P1/serious-P2 continuation and fix floor; this loop
owns PR-to-item linking (6). It opens a draft wherever the repo holds CI on drafts, `prototype`
included, requests every in-scope cloud reviewer in the same call and settles through `review`,
which runs the full pass step 3 deferred. Deferrals, deviations and dismissals (with rationale) go
in the PR body. The push/ready-flip race is `review` step 7's: flip-with-push leaves every job
`skipping`, which step 5 never reads as green.

## 5. Merge

### 5a. Fast merge (from 4a)

- Clean tree, every 4a fix committed. `git checkout <epic branch> && git pull --ff-only`; merge the
  story `--no-ff` per `commitConventions.epicMergeFormat` (fallback
  `merge: <itemNumber> [<N>] <short scope> into <epic-slug> integration`), the BODY listing each
  dismissed finding (steps 3 and 4a) with its rationale.
- Base moved → merge the refreshed epic INTO the story, re-run the gate, merge back; unresolvable →
  fork.
- Push. **Only once that push SUCCEEDS** delete the story branch locally AND remotely (why:
  `references/epic-release.md`). Then step 6.

### 5b. PR merge (from 4b)

- **The rebase already happened** in `review` step 7; rebase again only if the base moved, via
  `/devstride:push` (conflict → fork). Compare patches: CHANGED returns to `review` with its
  cumulative ledger, target and safety state, never a fresh budget; tree-identical keeps its
  receipt, else affected checks rerun. Then RECOMPUTE `verify.skipDuringStoryBuilds` applicability
  from the new SHA.
- **Observe greenness**: non-draft, and every applicable check succeeded — actually RAN — at the
  CURRENT head SHA. Re-poll only after a re-push, with `review` step 7's background poll; never
  `gh pr checks --watch`.
- **Red CI**: failed to TRIGGER → `review` step 7.3 (close+reopen, then one empty commit);
  flaky/infra → `gh run rerun <id> --failed`, ~2 tries; real → reproduce, fix, push, re-poll. Never
  merge red; never quit after one failure.
- Slow suites (`verify.skipDuringStoryBuilds`): story PRs into an epic branch never wait on them; on
  develop each follows its applicability; an empty list settles an absent check. **Read the config
  before concluding either.**
- **Zero unresolved threads immediately before merging** (`review`'s paginated query); else back
  through `review` steps 3–6.
- `gh pr merge <n> --merge --delete-branch` — **never `--delete-branch` on a head matching
  `protectedBranches`** (anchored: `branch-patterns.md`).

## 6. Completion ritual

- `update_item` → **Done** (works off-board, unlike `mark_done`); `startDate`/`dueDate` = branch
  creation → merge. **A one-off merged onto the support train is NOT Done** — comment and leave it
  (`support-train.md`); `release` closes it.
- **The item points at its code**: 4b — confirm the PR auto-linked, else `link_pull_request`; 4a —
  `add_comment` the merge SHA and epic branch (the release PR follows at step 8). Never invent a PR
  number.
- **Reconcile as-built** on a material deviation: `add_comment` the `view: 'full'` description
  verbatim under "📋 Original spec (as planned) — superseded by the description below" (HTML: pass
  `{ html }`, never Markdown), then rewrite it: an italic as-built note naming what it shipped in, a
  **Deviations** list with one-line rationales, an **As shipped** summary — citing the artifact that
  EXISTS (4b its PR; 4a its merge SHA + branch). None → "shipped as specified". These are exactly
  step 3/4's deviations.
- **Report** item + `[N]`, lane, dates, PR link or SHA + branch, profile + source, reconciled y/n.

## 6.5 Capture untracked findings as tracked items

- **Below-floor defect → `/devstride:create-defect` DEFERRED**: parent = the
  `defects.deferredContainerTitle` container directly under the plan root (resolved or created), no
  `blocked_by`, no prefix, no delivery, plus the `add_relationship` related-to edge to the item whose
  review produced it (the RELEASE UNIT for a step-8 review). **Never splice a below-floor finding into
  the chain**, under any profile (why: `references/epic-release.md`).
- **Discovered scope → `/devstride:insert-story`**, spliced so selection reaches it.
- A deferral owned by an EXISTING item goes on that item. Report what went where.

## 7. Sync and proceed

- `git checkout <working base> && git pull --ff-only`; **assert a clean tree** — dirty → name the
  drift and STOP; never auto-reset or `git add .`.
- **Handoff memory**: what shipped, what remains, the plan root WITH profile and source (never the
  profile alone), the epic's integration branch keyed to its number (or "develop — no epic").
- **Counts**: not-Done `hierarchyRoles.leaf` descendants of **the SAME
  release-unit ancestor step 0 resolved** — never the direct parent, which can read zero while siblings are open and publish a
  PARTIALLY COMPLETE unit — plus the whole plan root. **The deferred container counts in NEITHER**
  and is never a release unit. Unnumbered plan
  (`${CLAUDE_PLUGIN_ROOT}/skills/plan/references/execution-order-numbering.md`) → bare numbers, noting
  `/devstride:plan <root>` would number it.
- **Human recap.** After a direct pull-request merge (5b), lead with `Merged / Released`: item and
  effect, destination and live state, checks/CI, risk, next action. Otherwise
  `Built / Checked / Next`: outcomes, checks run or skipped, link or SHA, CI, profile, remaining counts, next action.
- Release unit at **zero** on its integration branch → **run step 8 now**; then step 0. DRY-CHAIN →
  exit and report.

## 8. EPIC RELEASE — epic branch → develop, fully reviewed

**Gate**: zero remaining leaves, working base the unit's integration branch, **auto-release on** —
`epicIntegrationBranches.autoRelease` when PRESENT, the profile default only when ABSENT. Off →
cut nothing; report release-ready and stop. **`"ask"` is a third legal value**: ask the owner once
per unit and cut nothing until answered; unanswerable → `false`, SAYING so. **Read
`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/epic-release.md` when step 7 reports the release
unit at zero and before cutting the release PR.** The batch lands as ONE reviewed PR.

- **Refresh**: pull the epic branch, fetch `baseBranch`, merge its captured tip `<baseOid>` — merge,
  NEVER rebase shared story SHAs; non-mechanical conflicts STOP. Push.
- **One verification plan for the merged tree**: aggregate story receipts, invalidating only what the
  refresh or combined tree changed. A `verify.typecheck`/`test`/`lint` command the PR workflows run
  exactly is not run locally (draft-held CI is its one run); a required command CI lacks runs once as
  a pre-ship check on the final reviewed head; `preShipChecks` stay local; a firing
  `verify.skipDuringStoryBuilds` entry stays cloud-only. Record where each runs; never infer coverage
  from a job name.
- **Cut via `/devstride:pr`** autonomously: head = epic branch, base =
  `epicIntegrationBranches.releaseTarget`, flagged **EPIC RELEASE PR** (body leads with the epic and
  lists its stories), with the profile, the verification plan and the aggregate risk-check ledger.
  Full review → uncovered pre-ship checks → ready flip → CI.
- **Review scope.** Fast mode used (`fastStoryMerges.epicReleaseIsFirstCloudPass`) → the FIRST cloud
  pass over ANY of this code: **review the FULL diff**, every story, ledgers only preventing re-raised
  settled findings. Stories took 4b → a computed manifest of cross-story contracts, combined
  behaviour and develop-merge resolutions; cloud may still cover the whole PR. A firing
  `verify.skipDuringStoryBuilds` suite is mandatory, with no story exemption; with the list empty,
  local pre-ship suites remain the callers' step-2b responsibility.
- **Merge** `gh pr merge <n> --merge` once green and settled; delete the
  epic branch **only if `epicIntegrationBranches.deleteBranchAfterRelease`** — false retains it.
- **Docs STAGE, never publish** — only when `docs.updateOnEpicRelease` is true (else silent):
  `docs.updateSkill` null → say none is registered; a name with no `.claude/skills/<name>/SKILL.md`
  → report the dangling hook and its fix (`/devstride:setup docs`), continue; otherwise invoke it in
  mode `update` with the epic payload (`kind: "epic-release"`, release PR, merge commit, each leaf's
  plain-English `summary` and `userFacing` judgement, **`live: false`**, never optional — shape:
  `${CLAUDE_PLUGIN_ROOT}/skills/release/references/docs-hooks.md`), keeping its links exact. **Never
  release notes here.**
- **Close out**: `add_comment` on the RELEASE-UNIT item (release PR, leaves, date), Done if lanes are
  tracked there, update handoff memory, sync develop, and **link the release PR onto every leaf**
  whose as-built note deferred it (`link_pull_request` or `add_comment`).
- **Human recap.** Lead with `Merged / Released`: every item and its effect, where it landed,
  validation/review/CI, docs, whether live, the remaining production action. Surface — never
  perform — the owner-cut promotion (`/devstride:release`). New findings → step 6.5.

