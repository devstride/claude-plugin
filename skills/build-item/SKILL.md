---
name: build-item
description: "Orchestrate one DevStride work item end-to-end: select, branch, build, review, merge, and completion ritual — epic stories batch onto the epic's integration branch in fast develop mode (local engines, no per-story PR) and the fully-reviewed epic release PR carries them to develop; one-off items ship straight to develop with the full per-story PR ritual"
---

Orchestrate ONE DevStride one-day leaf item (this org's Story or Defect types) end-to-end: select → In Progress → branch → build →
review → PR → merge → completion ritual → sync → next. This is the ORCHESTRATOR. It composes
the other delivery skills and owns ONLY the DevStride glue (selection, lane transitions, the
completion ritual). **Invoke them by name; do not re-spell what they do.**

Argument — an item number, or `next`/empty for the next unblocked item. It may also SCOPE selection
to one plan by naming its ROOT (a parent item at any grouping level of the org's hierarchy,
e.g. this org's Module/Capability/Epic): `next under I20100`, or **`I20100`
alone, meaning "the next unblocked item under this root"** — a bare root is a SCOPE, never a story
to build, so resolve it as the plan root and then select within it. A specific item that is not
part of a sequenced plan is auto-detected as a one-off: $ARGUMENTS

## Ground rules

- **Full-auto through merge.** Run the whole loop without pausing between steps. PAUSE only at a
  genuine fork: work gated on a human/infra decision that is the user's (AWS/DNS/SES/Stripe/
  secrets/provisioning), an ambiguous or unverifiable review finding, or a destructive /
  outward-facing action. Record every deferral explicitly rather than silently skipping it.
- **The DevStride MCP targets PRODUCTION.** Lane moves and the completion ritual are real,
  user-visible changes to live items. The MCP cannot exercise branch code.
- **Config**: `.claude/ds-config.json` — re-read it EVERY iteration; it wins over any literal here.
- **Skill freshness.** The on-disk skills and config are the only source of truth, and they evolve
  mid-initiative. Skill text you remember from an earlier iteration — especially through a
  context compaction — is EXPIRED. Re-invoke each composed skill at the iteration that needs it
  (the observed cost of not doing so: `references/progress-table.md`).
- **The plan is a HYPOTHESIS.** Validate the story's spec against the ACTUAL codebase before
  building — paths move, dependencies ship early, stated approaches turn out wrong. Correct the
  item's description rather than faithfully building the wrong thing, and keep it current *as the
  work firms up*, not only at the end. The item is the durable source of truth; the PR is not.

## Delivery profile — resolve it ONCE per iteration, and say where it came from

The delivery profile is the one user-facing choice that sets how much rigor the loop spends per
story. Its knobs, its floors, its resolution order and its root marker are defined ONLY in
`${CLAUDE_PLUGIN_ROOT}/skills/plan/references/delivery-profiles.md` — read that file; never
restate its table. This skill resolves the profile for the run and honours four of its knobs:
`perStoryPullRequest` (step 4), `storyVerify` (step 4a), `autoRelease` and `releaseCiOrdering`
(step 8). The composed skills honour their own knobs, but they must not each re-resolve the
profile — a story built under one profile and reviewed under another is worse than either — so
**pass the resolved profile EXPLICITLY, by name, in the invocation text** of `ultracode-build`
(step 3), `review` (steps 4a and 4b) and `pr` (steps 4b and 8).

Resolve it in step 0, once the plan root is known, by **the contract's resolution order** —
cite it, never restate it — with two build-item specifics: the root-marker step reads the
description with **`get_item(view: 'full')`** (the summary projection omits `description`, so a
summary read silently falls through to the config default — absence of data read as data), and
a ONE-OFF skips only the marker step, never the explicit-argument step (`I20110 enterprise`
still wins; else config `profile`, else `standard`). **Announce the result WITH ITS SOURCE** —
`profile: prototype — from the plan root I20100` — and carry it in the progress table's
`Profile` row; the next session inherits it from handoff memory (step 7).

**A config key that is PRESENT wins over the profile's default** for
`epicIntegrationBranches.autoRelease` and `fastStoryMerges.enabled` — the profile fills only an
ABSENT key, and a present key that contradicts the profile is honoured AND reported ("profile
prototype, but `autoRelease` is false in config — stopping at release-ready as configured").
**The three `review.*` CI-ordering booleans are different**: they describe what the workflows
SUPPORT; under `prototype` the RELEASE PR (step 8) does not use the hold whatever they say,
while a base-branch story's own PR (4b) keeps the configured hold under every profile — its
only cloud gate.

**`profileOverrides` pins individual knobs**: apply it to the four knobs this skill owns after
resolving the profile and BEFORE any decision reads them (a PRESENT dedicated key still wins
over it; unknown names are reported and ignored; no override lowers a floor). Skipping this is
how a `prototype` plan with `profileOverrides.autoRelease: false` auto-releases anyway.
**Every decision below branches on the EFFECTIVE value of a knob, never on the profile's
NAME** — resolve the four knobs once (profile default → override → present dedicated key) and
read only those values in steps 4, 4a, 5a and 8; "under `prototype`" always means "when the
effective knob says so".

## Progress reporting — emit the table at every step transition

Render the table at each step transition, updating rows in place: **one row per NUMBERED step,
in this skill's own names** (CI release/settle belong to `review` step 7, never a row of their
own), the `Profile` row naming the profile AND its source, **every CONFIGURED engine its own
row and an unconfigured one an explicit "not configured" row**, and step 8 `n/a` on a one-off
rather than dropped. **State EVIDENCE, not intent** — "request registered in timeline", never
"requested"; "non-applicable (no path match, base develop, no label)", never a bare "skipped".
**A missing CI check is not a passing one** — say whether it is `skipping` or never ran, and
why. On the fast path, rows 4/5 take their 4a/5a forms and the deferred cloud rows stay
visible. It is a status render, not a gate — never let it delay the step it describes. **Read
`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/progress-table.md` when you render the
table for the first time in a session, or when resuming after a compaction** — it holds both
worked tables and the reasoning.

## Working base — epic integration branches (the default)

An "epic integration branch" is the integration branch of the story's **release-unit ancestor** —
the container role (this org's Epic type) whose completion cuts a release, mapped by
`hierarchyRoles` in `.claude/ds-config.json`. Derived automatically in step 0, in precedence order:

1. Explicit override — a branch in `$ARGUMENTS`, or config `integrationBranch` non-null.
2. **Release-unit ancestor found AND `epicIntegrationBranches.enabled`** → that release unit's
   integration branch. Resolve the ancestor by **walking `parentNumber` up and fetching each
   ancestor's work type explicitly** (`get_item` returns a resolved `workType`), matching
   against `hierarchyRoles.releaseUnit` when set; absent/null → resolve BOTH roles at runtime
   via `get_work_type_hierarchy` (leaf = the bottom childless levels; release unit = the level
   directly above, spelling included — never assume the literal "Epic"). That runtime
   resolution backs every other `hierarchyRoles.leaf` read in this skill (one-off
   classification, selection, step 7 counting). **NO ancestor matches a CONFIGURED
   `releaseUnit` → validate the configured type exists in `get_work_type_hierarchy` before
   concluding "no release unit"** — a renamed type or config typo STOPS with a question, never
   silently routes to `baseBranch`. **`hierarchy` gives the ancestor CHAIN, not work types**
   (entries are `{itemNumber, title}` only) — a match against it silently finds nothing and
   ships the story outside its epic branch; use `hierarchy` to enumerate, `get_item` to type,
   and never inspect only the direct parent. Named per `epicIntegrationBranches.pattern`, slug
   per `epicIntegrationBranches.slugRule` when set (so two runs name the same epic the same
   way). Resolve: (a) handoff memory's branch for this epic; (b)
   `git ls-remote --heads origin "*/<epicNumber>-*"` (one → reuse, several → ask); (c) none →
   create off fresh `baseBranch` and push. The date in the name is the branch's CREATION date,
   never re-minted. Cache per epic per session. **Announce which branch was reused or
   created.**
3. **No release-unit ancestor** (one-off, or a plan with no release-unit tier), **or
   `epicIntegrationBranches.enabled` is false** →
   `baseBranch` (develop). Disabling the flag must genuinely fall back; never route a story
   through a branch mode the operator turned off.

Read "the working base" wherever a step says develop. Stories merge into it, so the shared dev
stage is untouched until the epic completes, and story-level runs SKIP `verify.skipDuringStoryBuilds`
suites. When the release unit's last leaf merges, **step 8 runs automatically**. The working base is
per-RELEASE-UNIT, not per-session — re-derive when the loop walks into the next release unit.

**The working base also selects the review path** (step 4), together with the delivery profile's
`perStoryPullRequest`. Epic integration branch → **fast
develop mode** (always under `prototype`; per `fastStoryMerges.enabled` otherwise — step 4 has
the rule): no per-story PR, the local roster (≥ 1 engine — see step 4a's floor) + green
local suites, local merge, with
the cloud roster and CI deferred to the epic release PR. `baseBranch` → the full per-story PR ritual,
because a one-off gets no later epic release and its own PR is the only cloud gate it will ever
have. Announce which path the story is on when you announce the branch.

## One-off / no-plan single-shot mode

Detect AUTOMATICALLY before step 0's plan-root resolution. **A bare plan ROOT is not a
candidate** — but a bare root is SYNTACTICALLY IDENTICAL to a specific item, so TEST, never
assume: **fetch the work type and apply the one-off heuristic only to executable leaf types
(`hierarchyRoles.leaf`)** — a container type is a root, resolved as the plan scope. Fetch as
`get_item(view: 'full', fields: ['number','title','workType','relationships'])` — **the default
summary projection OMITS `relationships`**, so a plan item whose only signal is a dependency
edge would look like a one-off. Classify: **no `[N]` title prefix AND no `blocked_by`/`blocks`
edges → one-off** (a plan item always has one or the other); both present → plan mode; exactly
one, unusually → default to plan mode if a root resolves, else state your read and ask.

Deltas — **steps 1–6 run VERBATIM**, because the point is that the inner build loop is identical:

- **Step 0** — the item is given: skip plan-root resolution, ready-set and selection. **SKIP
  THE EPIC-BRANCH DERIVATION TOO — the working base is `baseBranch`, unconditionally** — never
  reason from "a one-off has no release-unit ancestor"; a one-off filed under an Epic parent
  DOES have one, and without this bypass it would strand on that epic's branch (the full
  reasoning: `references/epic-release.md`). A one-off ships straight to develop. Still run the
  gating/scope check and spec validation. The root-marker step is skipped: an explicit profile
  in `$ARGUMENTS` wins, else config `profile`, else `standard` — announced with that source. A
  one-off always takes step **4b** — the full PR ritual — **under every profile**: its own PR
  is the only cloud gate it will ever have. **Read
  `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/epic-release.md` before changing the
  one-off classification or its step-0 delta.**
- **Step 6.5** — no plan chain to splice into. Capture follow-ups as their own one-off items
  (`/devstride:create-story` / `/devstride:create-defect`); never `insert-*` into a nonexistent plan.
- **Step 7** — do not loop or persist a plan root. Sync, assert a clean tree, emit the close-out
  for the single item, TERMINATE. Skip the release countdown — a one-off is its own release.

## 0. Select the story

- **Resolve the plan root first**: `$ARGUMENTS`, else the handoff project memory. If neither
  yields ONE unambiguous root and several plans are open, STOP and ask — a wrong root silently
  executes the wrong plan.
- A specific story number IS the story (still run the checks below). Otherwise apply the
  canonical next-unblocked rule — see
  `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/next-unblocked.md` — in full, including its
  projection warning: fetch each candidate's `relationships` explicitly before computing the
  ready-set.
- **Surface the ready-set** (all unblocked, non-gated candidates), not just the pick — the loop
  runs them serially, but the ready-set shows where the parallel waves are.
- **DRY-CHAIN / TERMINAL:** zero not-Done, non-gated, unblocked candidates → DONE. Exit
  cleanly; never loop back to re-ask. Report which: plan complete / N blocked by X, Y / N gated
  on human-infra decisions. Suggest `/devstride:plan <root>` to extend; never invoke it
  automatically.
- **GATING CHECK** — depends on a human/infra decision that is the user's? Flag it and move to the
  next candidate. **SCOPE CHECK** — what is buildable now vs deferred; record deferrals.
  **VALIDATE THE SPEC** — re-fetch with `view: 'full'` (the default omits `description`) and
  confirm its paths/symbols/assumptions against the codebase.
- **Resolve the delivery profile once the story is SELECTED**, not when the root is. The
  marker step walks the story's ancestor chain (`hierarchy` for the chain, `get_item` with
  `view: 'full'` per ancestor) and takes the NEAREST container's marker, else the root's — a
  descendant's own marker wins for its subtree, and resolving from the root before selection
  cannot see it. Announce `profile: <name> — from <source>`; fill the `Profile` row. Once per
  iteration — never carried over from the previous story.
- Report the item, title, ready-set, the profile with its source, and the
  buildable-now-vs-deferred line.

## 1. Mark In Progress

`update_item` → In Progress lane, resolving the lane id from the item's work-type lane collection
via `get_workspace_context` if needed. Confirm it moved before branching.

## 2. Branch

Invoke **`branch-feature`** with `I<number>-<short-slug>`, and pass it the working base
explicitly so it overrides its own config resolution.

## 3. Build

Invoke **`ultracode-build`** as `I<number> <one-line goal/scope> profile: <name>` — the
trailing clause is the form the engine parses; it honours its own knobs and must not
re-resolve the profile behind you. It returns: the item number, a one-line summary,
green-checks confirmation, the **deferral line**, the **deviations list**, the
**untracked-deferral list**, and the **dismissed-findings list**. Carry all four forward —
deferrals + deviations to the PR body (step 4) and the as-built reconciliation (step 6);
untracked deferrals to step 6.5; dismissed findings to the PR body (4b) or the merge-commit
body (5a). Step 6 does not reconcile dismissals — a dismissal is a review disposition, not a
spec divergence.

## 4. Review — fast mode on an epic branch, full PR ritual on develop

**Which path you are on is decided by the WORKING BASE step 0 resolved and the profile's
`perStoryPullRequest`, not by the diff, the item, or how the run feels.** Epic integration branch:
under **`prototype`** → **4a** whenever `fastStoryMerges.enabled` is ABSENT or `true` — fast mode
is the profile's default, and Claude's build-time pass is the ≥ 1 local engine the floor asks
for; a PRESENT `false` wins, routes the story to 4b, and is reported as a contradiction. Under
**`standard` / `enterprise`** →
**4a** iff `epicIntegrationBranches.fastStoryMerges.enabled`, exactly as before; the profile
supplies no value while that key is present. Working base is `baseBranch` → **4b**, under every
profile. Never mix them: the paths differ in where the
CLOUD gate sits, and a story that takes 4a while heading for develop reaches production having
never been cloud-reviewed.

### 4a. FAST DEVELOP MODE — no per-story PR (epic-branch stories)

The story is not a release; the epic it batches into is — the cloud half (cloud reviewers,
CI, thread bookkeeping) is **deferred to the epic release PR** and the story settles entirely
locally, every LOCAL engine on the resolved roster at full effort.

**THE FLOOR: fast mode requires ≥ 1 local engine behind the story.** No local CLI engine AND no
build-time Claude pass (a caller bypassed `ultracode-build`) → route through **4b** and say
why. The floor does not move with the profile: under `prototype` Claude's build-time pass is
the engine behind the story — satisfied, not lowered.

- **Claude adversarial** — already ran as `ultracode-build` phase 3 in step 3. Do not re-run it.
- **Local CLI engine (Codex, by default)** — invoke **`review` in local-only mode** (say so
  explicitly; pass the epic branch as the base ref **and the resolved profile by name** —
  `review` owns `localCliEngine` and `maxLocalReviewRounds`). Use the skill, never the CLI
  directly: the load-bearing flags live there (notably
  `-c mcp_servers.devstride.enabled=false`, without which the review wedges silently).
  Unconfigured → the Claude pass is the local gate; a failed probe is this-run degradation.
  **Invoke `review` in local-only mode EITHER WAY** — it owns the settle-time steps; skipping
  it because there is nothing to launch drops them silently.
- **Fix every finding `review` hands back as fix-in-story before merging** — its `fixFloor`
  triage decides which confirmed findings those are under the profile, and a finding it deferred
  with a rationale is not re-imposed here — committed per
  `commitConventions.reviewFixFormat` (fallback: `fix(<scope>): <summary> [<itemNumber> review]`).
  Out-of-scope and deferred-below-floor findings with no tracked home go on the
  untracked-deferral list for step 6.5, exactly as on 4b.
- **Local suites are the gate** (`fastStoryMerges.requireLocalVerifyGreen`). The gate's WIDTH is
  the profile's `storyVerify` — take it from
  `${CLAUDE_PLUGIN_ROOT}/skills/plan/references/delivery-profiles.md`, not from memory of a fixed
  suite list — and say which width ran; that it must be GREEN is a floor no profile moves.
  **Record the pass counts in the
  commit body** — with no CI run behind the story, that line is the only durable evidence the gate
  ran. Red suites are a STOP, never a "the epic release will catch it": at the epic release the
  failure arrives with N stories of diff to bisect.
- **No PR, no draft, no Copilot request, no CI poll.** An absent check here is not pending and not
  skipped — nothing was ever asked to run. Do not open a PR "just to have a record"; the epic
  release PR is the record, and it lists the constituent stories.

Then go to **step 5 (fast merge)**.

### 4b. FULL PR RITUAL — develop-base stories and one-offs

Invoke **`pr`** in autonomous (driven-by-`build-item`) mode — say so explicitly, pass the
working base as the pre-answered base **and the resolved profile by name** (it hands the profile
on to `review`, which owns the round cap and fix floor), and note that this loop owns PR-to-item
linking (step 6), not `pr`.

It opens the PR — as a draft when the repo holds CI on drafts (`review.openPullRequestsAsDraft`)
**under every profile, `prototype` included**: `releaseCiOrdering` applies to the RELEASE PR
only, and this PR is the story's sole cloud gate — every configured cloud reviewer requested
in the same call, then the review-and-settle loop via `review`. **Review first, CI last**;
never flip a PR ready yourself to start CI early. This is ADDITIONAL to step 3's build-time
pass.

Ensure every deferral, deviation and dismissed finding (with its rationale) is in the PR body.
`review` returns its triage; out-of-scope
findings with no tracked home come back on the untracked-deferral list for step 6.5.

**The push/ready-flip race is `review` step 7's to prevent** — the sequencing and post-flip
verification live there for every caller. In summary: flip-with-push means CI never runs while
every job reports `skipping`. `review` returns the verified outcome; step 5 must not treat a
skipped board as green.

## 5. Merge

### 5a. Fast merge (came from 4a)

No PR to merge — integrate locally, then push the epic branch:

- Confirm the tree is clean and every 4a finding fixed and committed.
- `git checkout <epic branch> && git pull --ff-only`, then merge the story branch `--no-ff` (a
  legible first-parent unit — the release PR body and close-out counts read off these merges).
  Message: `commitConventions.epicMergeFormat` (fallback:
  `merge: <itemNumber> [<N>] <short scope> into <epic-slug> integration`); its BODY carries the
  dismissed-findings list with rationales — the only place a reader sees what was judged and
  let go.
- Base moved while building → merge the refreshed epic branch INTO the story branch first,
  re-run the local suites, then merge back; unresolvable conflict → genuine fork.
- Push the epic branch. **Only once that push SUCCEEDS**, delete the story branch **locally AND
  on the remote** — a rejected epic push means the merge exists only locally, and deleting the
  remote story branch would destroy the sole remote copy; deleting only the local one leaves a
  stale remote branch every time.
- **Skip the rest of step 5** — the CI rules below describe a PR that does not exist here. Go
  to step 6.

### 5b. PR merge (came from 4b)

- **The rebase already happened** in `review` step 7, before the ready-flip. Do NOT redo it by
  reflex; just CHECK whether the base moved since — only then rebase, push via
  `/devstride:push`, and accept the re-run (unresolvable conflict → genuine fork). **A re-push
  may change the reviewed patch**: compare pre-/post-rebase patches, and if CHANGED, re-run
  the local streams (re-requesting the cloud reviewer if the delta is substantive) before
  accepting the new CI run. **Non-empty `verify.skipDuringStoryBuilds` → RECOMPUTE
  applicability from the new SHA before judging CI** — a rebase can change the path set, and a
  check that just became mandatory would sit absent.
- **A `skipping` check is not a passing check.** Confirm the applicable jobs actually RAN — see
  step 4's push/flip warning. Reading a skipped board as green is how a PR reaches merge with zero
  CI behind it.
- **Observe greenness, don't assume it.** Normally you are confirming an already-green state.
  Verify the PR is non-draft (a draft means CI never ran — unsettled, not green) and every
  applicable check is successful at the CURRENT head SHA. Re-poll only if you re-pushed. Use the
  same self-terminating background poll as `review` step 7 — never `gh pr checks --watch`.
- **Red CI:** failed to TRIGGER → `review` step 7.3's escalation (close+reopen, then one empty
  commit). Flaky/infra → `gh run rerun <id> --failed`, ~2
  tries. Real → reproduce, fix, push, re-poll. Never merge red; never give up after one failure.
- Per-story PRs into an epic branch do not wait on `verify.skipDuringStoryBuilds` checks. On a
  develop-base PR, a listed suite is evaluated per its configured applicability; empty list →
  nothing to evaluate, an absent check is settled. **Read the config before concluding
  either** — an absent check for a suite the config DOES list is a gate that never ran.
- **Re-check zero unresolved review threads immediately before merging** (the paginated query
  from `review`'s references) — a comment in the settle-to-merge gap would otherwise merge
  silently unaddressed. Non-zero → back through `review` steps 3–6 first.
- **Merge guard — only when `ci.freezeBaseWhileReleasePrReady` is `true`** (an explicit `false`
  disables it, merge proceeds with one line saying so): before ANY merge whose TARGET is
  `release.releaseSource` — here, and the epic release at step 8 — look for an open, NON-DRAFT
  PR with head `release.releaseSource` and base `release.productionBranch`. One exists → a
  release is in its CI window; do not merge beneath it — say which PR holds the base, wait
  (bounded by `review.pollTimeoutMinutes`), then merge. A still-draft release PR holds
  nothing.
- Merge: `gh pr merge <n> --merge --delete-branch`. **NEVER `--delete-branch` on a PR whose head
  is `develop` or `master`.** The epic release PR is step 8's business.

## 6. Completion ritual

- `update_item` → **Done** lane (works on and off board, unlike `mark_done`).
- `update_item` → `startDate`/`dueDate` = the branch-creation → merge window.
- Confirm the PR auto-linked; else `link_pull_request`. **Fast-mode stories have no PR to link** —
  `add_comment` the story's merge commit SHA and its epic branch instead, and link the epic
  release PR at step 8. Do not leave the item with no pointer to its code, and do not invent a PR
  number for it.
- **Never compose an item number.** Any `I#####` in a comment, commit or PR body must be
  `get_item`-verified first. Work needing an item gets the item created BEFORE any text cites it.
- **Reconcile the spec (as-built)** on any material deviation:
  1. Re-fetch the description with `view: 'full'`; `add_comment` it verbatim under "📋 Original
     spec (as planned) — superseded by the description below" (both fields are HTML: pass
     `{ html }`, never Markdown).
  2. `update_item` the description to the as-built spec: an italic as-built note naming what it
     shipped in, a **Deviations** list with one-line rationales, an **As shipped** summary.
     **Cite the artifact that EXISTS for this path**: a 4b story cites its PR; a 4a story has
     NONE — cite its merge SHA and integration branch and let step 8 add the release PR link.
     Never write a PR number on the fast path.
  - No material deviations → skip; note "shipped as specified".
- The deviations recorded here MUST be the same ones from steps 3 and 4. Never let one ship
  undocumented on the item.
- **Report** the item (with its `[N]` prefix), lane, dates, **the PR link (4b) or the merge SHA +
  integration branch (4a — a fast-mode story has no PR to link)**, **the profile it was built
  under with its source**, and whether the spec was
  reconciled — otherwise nothing confirms the Done move, the date window, the link, the rigor
  the story actually got and the as-built reconciliation actually happened.

## 6.5 Capture untracked findings as tracked items

A real out-of-scope finding living only in a PR body is invisible to step 0 forever. For each
entry on the untracked-deferral list: a new defect → **`/devstride:insert-defect`**; discovered scope →
**`/devstride:insert-story`**, both under the current plan root. They splice it into the dependency chain
so step 0's selection actually reaches it. A deferral belonging to an EXISTING downstream story
goes on that item instead — capture-as-new is only for work with no home. Report what was captured.

## 7. Sync and proceed

- `git checkout <working base> && git pull --ff-only`.
- **Assert a clean tree** (`git status --porcelain`) — `branch-feature` aborts on a dirty tree,
  so stray files silently wedge the loop. Dirty → surface exactly what drifted and STOP. Never
  auto-reset or `git add .`.
- Update handoff memory: story shipped, remaining work, **the resolved plan root WITH the
  delivery profile and its source** (never the profile alone — a resumed session re-resolves it
  from the root), and **the epic's integration branch keyed to its epic number** (or "develop —
  no epic").
- **Close-out summary**, computed AFTER 6.5 so spliced items are counted:
  ```
  ✅ Completed [23] I20130 — Enforce seat invariant
  🎚 Profile: standard — from the plan root I20100
  📦 3 stories remaining in Epic "V1 Seat Management" until release-ready
     (12 remaining in the full plan)
  ```
  Count not-Done leaf descendants (`hierarchyRoles.leaf` types) of
  **the SAME release-unit ancestor step 0 resolved to derive the working base** — never merely the direct parent, which
  excludes sibling subtrees and can read zero while the release unit still has open work,
  publishing a PARTIALLY COMPLETE release unit. Also count the whole plan root. Unnumbered plan
  (no `[N]` prefixes — convention:
  `${CLAUDE_PLUGIN_ROOT}/skills/plan/references/execution-order-numbering.md`) → emit the
  summary with bare numbers and note `/devstride:plan <root>` would add numbering. Release unit
  at **zero** with the working base its integration branch → say so and **run step 8 now**.
- Return to **step 0** (after step 8 when it ran). On the DRY-CHAIN condition, EXIT and report.

## 8. EPIC RELEASE — epic branch → develop, fully reviewed

Runs when step 7 finds the release unit at zero remaining leaves, the working base is its
integration branch, **and auto-release is on** — `epicIntegrationBranches.autoRelease` whenever
that key is PRESENT in config, the profile's default ONLY when it is ABSENT; a present key wins
whatever the profile says, and the contradiction is reported ("profile prototype, but
`autoRelease` is false in config — stopping at release-ready as configured"). Auto-release off →
do NOT cut or merge: report the epic release-ready and stop for an explicit manual release
(why the present key must win: `references/epic-release.md`). **Read
`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/epic-release.md` when step 7 reports the
release unit at zero and before cutting the release PR.** The whole batch lands on develop as
ONE reviewed PR.

- **Refresh from develop**: pull the epic branch, fetch `baseBranch`, capture the fetched tip as
  `<baseOid>`, and **merge that exact OID** — merge, NOT rebase; story SHAs on a shared branch must
  not be rewritten. Resolve conflicts in-loop if safe and mechanical; otherwise STOP. Push.
- **Verify locally**: type-checks and `verify.test` (the repo's full test suite — where the
  profile's `storyVerify` ran less than that per story, this is the batch's first full run, so
  do not skip it on the strength of green stories). Compute the
  release diff against the same merged tip. If `verify.skipDuringStoryBuilds` is non-empty and a
  listed suite's configured applicability fires, its CI check is mandatory on the PR below — do
  NOT also run it locally, a double-run is waste. (With the list empty, local-only suites in
  `preShipChecks` are the callers' step-2b responsibility instead.) Fix failures in-loop before
  cutting the PR.
- **Cut via `/devstride:pr`** in autonomous mode, head = epic branch, base =
  `epicIntegrationBranches.releaseTarget` (a config key naming where completed release units land;
  the shipped default is `baseBranch`, and a repo that stages releases elsewhere sets it there),
  flagged as an
  **EPIC RELEASE PR** so the body leads with the epic and lists the constituent stories, **with
  the resolved profile named in the invocation** (it reaches `review` through `pr`).
  **`releaseCiOrdering`:** under `prototype`, tell `pr` and `review` that the draft hold is OFF
  for this PR — it opens non-draft and CI runs concurrently with the review —
  **unconditionally**, whatever the three `review.*` CI-ordering booleans say: they describe
  what the workflows support, and a prototype run does not use the hold. Under `standard` /
  `enterprise` the booleans govern the hold as configured (the review-first, CI-once ordering
  step 4b describes).
- **Review-and-settle — CHECK WHICH SCOPE APPLIES, because fast mode changes it.**
  - **Fast mode was used** (`fastStoryMerges.epicReleaseIsFirstCloudPass`, the default path):
    **this PR is the FIRST cloud-side pass over ANY of this code — review the FULL diff**,
    every story in the batch, never just the integration surface (why this is the one place
    fast mode's quality is defended: `references/epic-release.md`).
  - **Stories took the full 4b ritual**: each was already reviewed at its own PR — point the
    review at what per-story review COULD NOT see: the cross-story integration surface and the
    develop-merge conflict resolutions.
  - Either way: any suite in `verify.skipDuringStoryBuilds` is decided by its configured
    applicability — a suite that fires is mandatory, with no story-level exemption. With the list
    empty, no slow cloud suite gates the release; local pre-ship suites remain the
    callers' own step-2b responsibility.
- **Merge** `gh pr merge <n> --merge` once green and settled — after the step-4b merge guard
  (no ready release PR is holding the base) — then delete the epic branch —
  **only if `epicIntegrationBranches.deleteBranchAfterRelease`**. It is a destructive remote
  cleanup, so a false value must actually retain the branch.
- **Documentation — opt-in, and it STAGES, never publishes.** With `docs.updateOnEpicRelease`
  absent or `false` → nothing, silently. With it `true`: `docs.updateSkill` `null` → say docs
  were skipped because no docs skill is registered; a name whose `.claude/skills/<name>/SKILL.md`
  is MISSING → report a dangling hook with the fix (`/devstride:setup docs`) and continue — the
  same rule the production release applies; a name that resolves → build the delta payload for
  this epic (`kind: "epic-release"`, the release PR, the merge commit, every constituent leaf with
  a plain-English `summary` and a `userFacing` judgement, and **`live: false`** — shape in
  `${CLAUDE_PLUGIN_ROOT}/skills/release/references/docs-hooks.md`) and invoke that skill in
  mode `update`; relay what it reports. `live: false` is not optional: the epic reached the
  base branch, not production — the skill STAGES; the production release publishes. **Never
  release notes here**, under any setting (why: `references/epic-release.md`).
- **Close out**: `add_comment` on the RELEASE-UNIT item (release PR link, list of shipped leaves,
  date), move it to Done if the org tracks lanes at that level, update handoff memory, sync local
  develop.
- **Link the release PR onto each constituent leaf whose as-built note deferred it** —
  `link_pull_request` (or `add_comment`) on every leaf in the batch; this is where step 6's
  fast-mode promise is kept.
- Surface — never perform — the follow-on owner-cut `develop → master` promotion (`/devstride:release`).
- Out-of-scope findings from this review go through step 6.5 like any other.

IMPORTANT:
- Empty `$ARGUMENTS` means `next`.
- **Serial by design.** The plan's "parallel waves" describe SHAPE, not an instruction to run
  concurrent builds. Three constraints hold whatever the repository's local tooling looks like:
  `branch-feature` aborts on a dirty tree; test execution is serial against SHARED test
  infrastructure (test runners that share containers or databases corrupt each other's state,
  and a per-checkout instance — `localEnvironment.instanceBoundTo: directory` in config —
  isolates dev servers and app data, NOT the test infrastructure); and the MCP writes to
  production. The `localEnvironment` block tells the loop whether an isolated instance exists
  at all; it never makes the loop concurrent. Surface the ready-set for a human to fan out
  manually; keep the loop serial.
- **Injection is part of the loop.** Never let a real out-of-scope finding ship as PR prose only.
- **The release-unit container (this org's Epic) is exactly that — the release unit.** Develop
  only receives a COMPLETE, refreshed, fully-reviewed release unit with every applicable gate
  green — or a one-off that settled the same gate set.
