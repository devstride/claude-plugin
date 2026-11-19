---
name: build-item
description: "Orchestrate one DevStride work item end-to-end: select, branch, build, review, merge, and completion ritual — epic stories batch onto the epic's integration branch in fast develop mode (local engines, no per-story PR) and the fully-reviewed epic release PR carries them to develop; one-off items ship to develop with the full per-story PR ritual, or batch on a configured release train"
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

**Session model.** Read `${CLAUDE_PLUGIN_ROOT}/skills/plan/references/session-models.md` once per top-level run, role `runner`, first.

**Goal:** ONE DevStride one-day leaf item delivered end-to-end, then the next. This ORCHESTRATOR
owns ONLY the loop: selection, the run of one item's Build workflow, and what follows it. Each
step of that run is a skill the step runner names — **invoke them by name; never re-spell what
they do.**

Argument — an item number, or `next`/empty for the next unblocked item; `next under I20100`, or
**`I20100` alone, means "the next unblocked item under this root"** — a bare plan root (any grouping
level) is a SCOPE, never a story to build. `--board-root I<n>` is set aside first (Active Agents).
An item outside a sequenced plan is auto-detected as a one-off: $ARGUMENTS

## Hard floors — no profile, override or shortcut removes these

- **The DevStride MCP targets PRODUCTION.** Status moves, comments and the ritual write live items
  immediately; the MCP cannot exercise branch code.
- **`.claude/ds-config.json` wins over every literal here**; re-read it EVERY iteration. Commands
  (verify/test/lint, regen, local-environment, any pool or secrets CLI a repo documents) come from
  config or `conventionsDoc`, never from memory.
- **Skill freshness.** Skill text remembered from an earlier iteration or across a compaction is
  EXPIRED; re-invoke each composed skill when needed (cost: `references/progress-table.md`).
- **Name the fields you read.** Default projections and `search_items` OMIT `relationships` and
  `description`; read them via `get_item(view: 'full')`. Absence is never data.
- **Never compose an item number.** Every `I#####` in a comment, commit or PR body is
  `get_item`-verified; work needing an item gets it created BEFORE any text cites it.
- **Dates only with the auto-scheduler OFF** — the completion step's date write applies
  `${CLAUDE_PLUGIN_ROOT}/skills/rationalize-gantt/references/auto-scheduler-off.md` first.
- **Review first, CI once.** A loop PR stays a draft (`review.openPullRequestsAsDraft`, every
  profile) until every configured engine settles; `review` step 7's ready-flip releases CI once, on
  the final review-settled SHA. Never flip it yourself; a `skipping` or absent check never passes.
- **Safety continuation.** A verified P1 or serious P2 is fixed before merge under every profile,
  re-checked with the cumulative ledger and no numeric cap; no patch change, no progress or an
  unavailable required reviewer while one remains STOPS for human help.
- **Deploy safety travels with the diff.** Migrations are idempotent and rolling-deploy safe;
  reshaped durable events stay readable by both. `risk-check`'s focused verifier on auth,
  migration, irreversible-state or deployed-runtime changes fires from the DIFF, not the plan's
  theme, under every profile, as does each matching `review.mandatoryLenses`
  finder. Neither is skippable.
- **Production merges are the owner's.** This loop merges only into the working base or
  `routing.py release-target`'s branch (a plan release: its `from`); it surfaces `/devstride:release`, which merges to
  `release.productionBranch` only on the owner's explicit yes.
- **Checkout pool — lease, never mint.** When the repo's `conventionsDoc` or config declares a fixed
  checkout pool, work only in a member held under a lease — with `pool.checkout` set, taken by
  **`lease-checkout`** and returned by **`return-checkout`** on the lifecycle in
  `checkout-pool-commands.md`; otherwise pool, lease name and
  hand-back come from the repo, never hard-coded (`ground-truth-at-start.md`). Never create a
  worktree or instance unless the owner asks in this conversation; never delete another session's
  lease.
- **Serial by design.** "Parallel waves" are SHAPE (`references/next-unblocked.md`):
  `localEnvironment` never makes the loop concurrent.
- **Full-auto through merge.** PAUSE only at a genuine fork: a user's human/infra decision, an
  ambiguous or unverifiable finding, a destructive or outward-facing action. Record every deferral;
  never skip silently.
- **The plan is a HYPOTHESIS.** Validate the spec against the ACTUAL code and correct the item's
  description as the work firms up.
- **Develop only receives a COMPLETE release unit** (refreshed, fully reviewed, every applicable
  gate green) or a one-off that settled the same gates. Out-of-scope findings:
  `capture-findings`.
- **Required steps are the runner's, not memory's.** The step runner issues each step in order and
  never issues the merge without a current risk check (of the story as it now stands: any later
  commit that changes it, a gate or review fix included, is screened again first), current green
  local checks and a current review; a stale proof is re-earned, never waived.

## Delivery profile — resolve once per story, announce with its source

Knobs, floors, resolution order and root marker live ONLY in
`${CLAUDE_PLUGIN_ROOT}/skills/plan/references/delivery-profiles.md`. This
skill honours `perStoryPullRequest` (the review moment, Working base), `autoRelease` and
`releaseCiOrdering` (8); the run's steps read the rest (`storyVerify` in `local-checks`, `fixFloor`
in `risk-check` and `review`).

- **Resolve once the story is SELECTED**, in the contract's order (explicit word → root marker →
  config `profile` → `extended`; an unknown word → `standard`, said so). The marker walks the
  story's ancestors (`get_item` with `view: 'full'` each) and takes the NEAREST. A one-off skips
  only the marker step. Never carried over from the last story.
- **Announce it WITH ITS SOURCE** in the
  `Profile` row and handoff memory; pass it **by name**, `profile: <name>`: to every step through
  the run's context, and to `pr` at step 8. None of them re-resolves it.
- **Branch on EFFECTIVE knobs, never the name**: profile default → `profileOverrides` → a PRESENT
  dedicated key, resolved before any decision reads them. A present
  `epicIntegrationBranches.autoRelease` or `fastStoryMerges.enabled` wins, its contradiction with
  the profile reported aloud; unknown overrides are reported and ignored; none lowers a floor.

## Progress table — at every step transition

The step rows are the runner's: `workflow.py status`'s `table`, one row per step of the run (CI
release/settle belong to `review` step 7). Around them: step 0's row, the `Profile` row with its
source, a row per configured engine (an unconfigured one: "not configured"), each matched
`mandatory lens <name>: ran (N findings)`, step 8 `n/a` on a one-off. **EVIDENCE, not intent**:
"request registered in timeline", never "requested"; "non-applicable" with its reason, never a bare
"skipped"; a missing CI check says `skipping` or never ran, and why. The fast path shows the
deferred cloud rows visible. A render, not a gate. **Read
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
   checked with `get_work_type_hierarchy` — a renamed type or typo STOPS with a question. Name
   per `epicIntegrationBranches.pattern` / `slugRule`, dated at CREATION, never re-minted. Resolve:
   handoff memory → `git ls-remote --heads origin` → the helper below (`create` → off a fresh
   `baseBranch`, pushed). Cache per epic; **announce reused or created.**
3. **A one-off AND `releaseTrain.branch` set** → the train, unless `release-train.md` routes it to
   `baseBranch` (announced); a train missing beside one other `train/*` branch rides that one.
4. **Otherwise** → `baseBranch`. A disabled flag falls back.

**This precedence is code**: `python3 ${CLAUDE_PLUGIN_ROOT}/skills/build-item/scripts/routing.py
target` (pass `oneOff`, and `roles` when resolved); follow its answer.

**Plan scope.** The profile's marker walk also records each ancestor's `Release scope:` line; **read
`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plan-scope.md` when one says `plan`.**

Stories merge into it (`references/epic-release.md`), skipping `verify.skipDuringStoryBuilds`
suites; the last leaf's merge triggers step 8. **The working base and the effective
`perStoryPullRequest` pick the review moment, never the diff**, announced with the path and passed
as the run's `reviewMoment`: an integration branch → `release-deferred` (the fast local review, no
per-story pull request) when `fastStoryMerges.enabled` is `true`, or ABSENT under `prototype` (a
present `false` wins, gives `pr-boundary` and is reported); the train → `release-deferred` only if
`releaseTrain.fastMerges` is true; `baseBranch` → `pr-boundary` (the full pull-request review),
every profile. `route` is `epic-release` on an integration branch, `train` on the release train,
`develop-pr` on `baseBranch`.
**Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/release-train.md` when
`releaseTrain.branch` is set** (legacy too).

## One-off / no-plan single-shot mode

Detect before plan-root resolution. TEST: `get_item(view: 'full', fields: ['number','title','workType','relationships'])`, and apply the
heuristic only to `hierarchyRoles.leaf` types. **No `[N]` prefix AND no `blocked_by`/`blocks` edge →
one-off**; both → plan mode; exactly one → plan mode if a root resolves, else state your read and
ask. **The same workflow runs, with `oneOff` true.** Deltas:

- **Step 0** — no root, ready-set or selection. **SKIP THE EPIC-BRANCH DERIVATION TOO — the working
  base is the release train when configured (precedence 3), else `baseBranch`**. The merged-or-Done guard, gating, scope and spec checks
  still run; the profile skips only the marker. **`pr-boundary` under every profile** — except
  `release-deferred` on a train with `releaseTrain.fastMerges` true. **Read
  `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/epic-release.md` before changing the one-off
  classification or its step-0 delta.**
- **Step 7** — no loop, no persisted root: sync, clean tree, close out, TERMINATE; no release
  countdown.

## 0. Select the story

- **Ground truth first.** Hold your checkout under the pool rule (**`lease-checkout`** once per run
  when `pool.checkout` is set, kept across iterations), `git fetch --prune origin`, and read
  what OTHER authors landed on the base (and epic) branch since the handoff — say so when another
  session appears active. Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/ground-truth-at-start.md`.
- **Plan root**: `$ARGUMENTS`, else handoff memory; not ONE unambiguous root while several plans are
  open → STOP and ask.
- **`needsYou.label` set** → read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/needs-you.md`
  here (a given item too) and at an unattended PAUSE.
- **Release scope**: once the root resolves, BEFORE selection, read any `Release scope:` line on it,
  its ancestors and the grouping items above each release unit (`view: 'full'`). The nearest one
  above a unit decides, any case: `plan` → read
  `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plan-scope.md` now; `epic` or none → default;
  another value → STOP.
- **Active Agents** (`activeAgents` set, plan mode only): at EVERY pickup, after each merge and at
  every terminal exit (step 0's, step 7's, a STOP — before it exits), apply
  `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/active-agents.md`. Never asks; fails open.
- **An unfinished run first**, for a given story number or the story the handoff names as in
  progress, in this order. (1) `claims` set → invoke `claim-story` with the item and its mode
  before the runner: `HELD` → never adopt; item 6's held exit. Any other verdict → go on (the
  run's own claim step renews it). (2) `resume` with the item (The run, item 2). (3) The merge row in
  `status` `done` with the verdict `MERGE: LANDED` → the run carries on from its own position,
  whatever the item's status says: it still owes completion, capture and
  sync. Otherwise (`MERGE: REFRESHED` included: its merge is not
  reached), the landing test's answer for a merge row `issued` or stopped (its `commit`: the
  stop's or the handed-back merge's): (i) exactly it → `done` on that attempt, so completion
  runs; (ii) landed, but the check cannot prove how → for a person, who checks what landed after
  it, as `run-stops.md` says; (iii) nothing landed, or the merge not reached → the run carries
  on (a stopped merge: back on the story branch, `resume` with `"landed": false`), unless the item
  is already merged or Done without this run's merge: then `resume` with `"close": true`, tell a
  person what finished it and that it was never checked or reviewed here, then the next rule.
- A given story number IS the story; merged or Done → never started, no run (`next-unblocked.md`).
  Otherwise apply `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/next-unblocked.md` in full
  (projection warning too). **Never auto-select from the deferred container.** Surface the
  whole ready-set.
- **DRY-CHAIN / TERMINAL:** no selectable candidate → exit cleanly, never re-ask, saying which:
  plan complete (then **Closing**, `deferred-container.md`) / N landed, awaiting their release (gate on →
  step 8 for it, then step 0) / N blocked by X, Y / N gated. Suggest `/devstride:plan <root>` only
  when the chain ran out; never invoke it.
- **Every exit from step 0** (DRY-CHAIN/TERMINAL, ambiguous root, a given item merged or Done, any
  other stop before the run starts) → **`return-checkout`** first when this run leased, and a claim
  the unfinished-run check took is released, also when the gating check passes over that story
  (`release_claim`, outcome `released`: `references/story-claims.md`).
- **GATING CHECK** (a decision that is the user's → flag, next candidate), **SCOPE CHECK**
  (buildable now vs deferred, recorded), **VALIDATE THE SPEC** (re-fetch with `view: 'full'`; confirm
  paths, symbols and assumptions against the code).
- Resolve the profile; report item, title, ready-set, profile with source, buildable-now line.
- The claim runs as the workflow's first step (`claim-story`, mode `select`, `named` or `resume`;
  `references/story-claims.md`).

## The run

Every command is `python3 -B "${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/scripts/workflow.py"
<command>` with one JSON object on stdin (a file or a here-document, never inside quotes), and
every `next`, `done`, `status` and `resume` names the `item`: a session holding two open runs is
refused one that does not. **Read
`${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/references/workflow-runner.md` in full before the first
command, and again after a compaction**: the commands, the answers, the stops and resuming.

1. **The context**, built once the story is selected: `item`, `goal` (its one-line goal), `profile`
   (`name` and `source`), `workingBase`, `oneOff`, `route`, `releaseUnit` (the release-unit ancestor
   step 0 resolved; null for a one-off), `reviewMoment` (Working base), `branchSlug`
   (`I<number>-` plus `routing.py slug` of the title) and `mode` (`select`, `named` or `resume`).
2. **`resume` with the item first** (a named or handed-off story after step 0's claim check; a
   selected one straight away): it finds this session's open
   run, or adopts the newest unfinished one another session left for the item in this repository
   (a cleared conversation, a crash), re-bound to this checkout (`adoptedFrom` names the one it
   came from: say it), and hands back its current step. Any command refused `wrong-branch` (a `resume`,
   `next` or `done` of an adopted run off its story branch, named) → `git fetch origin
   "+refs/heads/<branch>:refs/remotes/origin/<branch>"` (it fails, changing nothing, for a
   branch only here); then `git checkout <branch>` when it exists here, else `git checkout -b
   <branch> origin/<branch> && git config branch.<branch>.remote origin && git config
   branch.<branch>.merge refs/heads/<branch>`; `git rev-parse --abbrev-ref HEAD`
   printing it; then the same request again. The branch held by another worktree (`git worktree list`), or absent
   here and on the remote → STOP, naming what a person must do: free it there, or push it from the
   checkout that has it.
   Refused `no-run` or `run-other-repository` → **`start`** with
   `definitionFile` `${CLAUDE_PLUGIN_ROOT}/workflows/build.json` and that context. A `start` refused
   `run-open` means a run exists: `resume` it; only the excluded-paths re-route replaces one. Any other refusal (exit 2) or a
   runner failure (exit 1) → say its line and STOP; never build without the runner.
3. **For each `run` answer**: send the story claim heartbeat with `heartbeat.phase` and the
   ship-intent update from `heartbeat.shipIntent` (each only when configured and not null, each
   failing open, `references/story-claims.md` and `references/ship-intent.md`; a heartbeat's own
   stop stops the run); invoke the named skill (`claim-story`, `story-lifecycle`, `branch-feature`,
   `ultracode-build`, `risk-check`, `local-checks`, `review-story`, `merge-story`,
   `capture-findings`, `sync-base`) through the Skill tool with `argument` unchanged — plus, when the
   payload carries a person's `answer` and the argument does not, ` answer: <it>` after it; then
   `done` with `stepId`, `attempt` and the skill's WHOLE answer as `output`. Its answer is the next
   action. A step already acted on before an interruption (a merge that landed) is reported with
   `done`, never run again.
4. **Reports.** Forward every `reports` object, in order: **read
   `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/workflow-reports.md` in full before the
   first forward of a run, or after a compaction**, and send each exactly as it says, unless
   `workflows` is `null`: then report nothing. A report never gates, delays or stops a step; a
   failed one is dropped, silently.
5. **`stopped`**: say the reason in plain words and what can be done about that kind of stop. A
   question (`needs-person`), attended → ask it and, once the person replies, `resume` with their
   reply as `answer`; unattended with `needsYou.label` set → `references/needs-you.md`. A red local
   check (`LOCAL CHECKS: FAIL`) is the build's to fix: fix the named check on the story branch as
   the build step would, commit, then `resume` (the runner screens and checks the new commit).
   **Any other stop, and every answer carrying `mayHaveLanded`: read
   `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/run-stops.md` in full before acting on it**:
   a merge stop (landed or not), a train one-off moved off the train, and every other stop, which
   waits for this session with the lease kept.
6. **`finished`, outcome `held`**: a claim held by another agent or a release hold. A story the
   loop SELECTED → the next candidate (step 0), lease kept: selection passes over a release-held
   one until the hold lifts (`next-unblocked.md`). A named or resumed story, or a one-off, has no
   next candidate: a terminal exit, through step 7's terminal exit (its check, then
   **`return-checkout`**). A claim held → name the holder (nothing was built: the claim comes
   first). A release hold → the item stays in progress; push the story branch (`git push origin
   <branch>`), then report "held: <reason>" and what lifts it (`release-holds.md`).
7. **`finished`, outcome `completed`** → step 7.

## 7. Sync and proceed

- After a completed run, its last step (`sync-base`) left the checkout on the working base with a
  clean tree. **Terminal exit or hand-over only: `return-checkout`, after its own check**: `git
  checkout <working base> && git pull --ff-only`, then `git status --porcelain` empty — dirty →
  name the drift and STOP, lease kept, nothing reset or staged. The check is repeated
  here because a terminal exit may follow a run that never reached its sync (a release hold, a
  hand-over).
- **Handoff memory**: what shipped, what remains, the plan root WITH profile and source (never the
  profile alone), the epic's integration branch keyed to its number (or "develop — no epic").
- **Counts**: `hierarchyRoles.leaf` descendants neither Done nor landed, of **the SAME
  release-unit ancestor step 0 resolved** — never the direct parent (why:
  `references/epic-release.md`) — plus the whole plan root. **The deferred container counts in
  NEITHER** and is never a release unit; a plan root at zero runs its **Closing**. Unnumbered plan
  (`${CLAUDE_PLUGIN_ROOT}/skills/plan/references/execution-order-numbering.md`) → bare numbers, noting
  `/devstride:plan <root>` would number it.
- **Human recap.** After a direct pull-request merge onto `baseBranch`, lead with `Merged / Released`: item and
  effect, destination and live state, checks/CI, risk, next action. Otherwise
  `Built / Checked / Next`: outcomes, checks run or skipped, link or SHA, CI, profile, remaining counts, next action.
- `release.autoStart.enabled` → its trigger 4 (`auto-start.md`), lease kept.
- Release unit at **zero** on its integration branch → **run step 8 now**; then step 0. Plan scope
  with the plan at zero → `plan-scope.md`'s plan release. DRY-CHAIN →
  exit and report.

## 8. EPIC RELEASE — epic branch → develop, fully reviewed

**Gate**: zero remaining leaves, working base the unit's integration branch, no release hold on the
unit, an ancestor or a leaf it carries (`references/release-holds.md`; held → wait, said), **auto-release on** —
`epicIntegrationBranches.autoRelease` when PRESENT, the profile default only when ABSENT. Off →
cut nothing; report release-ready and stop — after the owner merges it, one
`/devstride:build-item <root>` run marks its stories Done (plan scope: landed, `plan-scope.md`). **`"ask"` is a third legal value**: ask
the owner once per unit, cutting nothing until answered; unanswerable → `false`, SAYING so. **Read
`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/epic-release.md` when step 7 reports the release
unit at zero and before cutting the release PR.**

The release target is `routing.py release-target`'s `branch` (`ask` → ask the owner which is live, set `releaseTrain.branch` or cut over, run it again; plan scope: `plan-scope.md`).

**Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/epic-release-steps.md` in full before
acting on a release that fires, or on step 0's recovery close-out** — refresh, verification, the release PR cut, review,
merge, close-out, docs and recap live there. New
findings → invoke `capture-findings` with the release unit.
