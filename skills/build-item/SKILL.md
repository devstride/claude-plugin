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
  mid-initiative. Skill text you remember from an earlier iteration — especially through a context
  compaction — is EXPIRED. Re-invoke each composed skill at the iteration that needs it. (Observed live: a
  compacted session kept re-requesting a review through a connector that had been disabled
  months earlier, waiting out timeout after timeout, because the stale in-context copy won.)
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

Resolve it in step 0, once the plan root is known, in the contract's order — first match wins:

1. An explicit profile in `$ARGUMENTS` — the bare word `prototype`, `standard` or `enterprise`
   anywhere in the arguments (`I20100 prototype`, `next under I20100 enterprise`).
2. The root marker in the plan root's description, read with **`get_item(view: 'full')`** — the
   summary projection omits `description`, so a summary read finds no marker and silently falls
   through to the config default. This is the same class of trap as the `relationships` omission
   the one-off classification below guards against: absence of data read as data.
3. `profile` in `.claude/ds-config.json`.
4. `standard`.

A one-off has no plan root, so only (2) is skipped — never (1): `I20110 enterprise` is an
explicit profile and wins; otherwise it resolves from (3), else (4). **Announce the result WITH ITS
SOURCE** — `profile: prototype — from the plan root I20100` — and carry it in the progress
table's `Profile` row. A bare name cannot be checked against the marker or the config by anyone
reading the transcript, and the next session inherits it from handoff memory (step 7).

**A config key that is PRESENT wins over the profile's default** for `epicIntegrationBranches.autoRelease`
and `epicIntegrationBranches.fastStoryMerges.enabled`: they are the operator's decision whenever
they are in the file; the profile supplies a value only for a key that is ABSENT. A present key
that contradicts the profile is honoured AND reported ("profile prototype, but `autoRelease` is
false in config — stopping at release-ready as configured") — following either side silently
hides a disagreement the operator needs to see. **The three `review.*` CI-ordering booleans are
different**: they describe what the repo's workflows SUPPORT (a draft hold, a ready-flip that
releases CI), not a per-run decision. They govern the hold as configured under `standard` and
`enterprise`; under `prototype` the RELEASE PR (step 8) does not use the hold at runtime whatever
they say — `releaseCiOrdering` is unconditional there, per the contract. A base-branch story's
own PR (4b) keeps the configured hold under every profile: it is that story's only cloud gate.

**`profileOverrides` in config pins individual knobs** (the contract's Overrides section). Apply
it to the four knobs this skill owns after resolving the profile and BEFORE any decision reads
them: an entry naming `perStoryPullRequest`, `storyVerify`, `autoRelease` or `releaseCiOrdering`
replaces the profile's default for that knob. It is still a profile-level value, so a PRESENT
dedicated key above still wins over it. Unknown knob names are reported and ignored, never
honoured as something else, and no override lowers a floor. Skipping this step is how a
`prototype` plan with `profileOverrides.autoRelease: false` auto-releases anyway.

**Every decision below branches on the EFFECTIVE value of a knob, never on the profile's NAME.**
Resolve the four knobs once, here — profile default, then override, then a present dedicated
config key — and read only those resolved values in steps 4, 4a, 5a and 8. Wherever a step says
"under `prototype`", it means "when the effective knob says so": a `prototype` plan with
`profileOverrides.perStoryPullRequest` set to standard's value takes 4b, and one with
`releaseCiOrdering` overridden keeps the configured draft hold at step 8. Branching on the name
would make both overrides inert while the text advertises them.

## Progress reporting — emit the table at every step transition

The loop's position is otherwise recoverable only from prose, so a compacted or resumed session has
to re-derive where it is. Render this at each step transition, updating rows in place:

```
| Step | Status |
|---|---|
| 0 · Select | I20110 — one-off → base develop, no epic branch |
| Profile | standard — from `.claude/ds-config.json` (one-off: no root marker) |
| 1 · In Progress | ✅ |
| 2 · Branch | ✅ jane/03-14-26/I20110-… |
| 3 · Build + Claude pass | ✅ 1 finding fixed |
| 4b · PR + review + CI | #42 — draft, CI held (release is `review` step 7) |
| — Codex (local, xhigh) | ✅ 3 findings → fixed |
| — Copilot (cloud) | ⏳ request registered in timeline |
| 5b · Merge | — |
| 6 · Completion ritual | — |
| 6.5 · Findings filed | I20111, I20112 |
| 7 · Sync + close-out | — |
| 8 · Epic release | n/a — one-off |
```

On the **fast path** rows 4 and 5 take their 4a/5a forms, and the cloud rows say what is DEFERRED
rather than going missing — otherwise "no Copilot row" is indistinguishable from "Copilot was
forgotten":

```
| Profile | standard — from the plan root I20100 (marker read with view: 'full') |
| 4a · Fast review (no PR) | epic branch — cloud gate deferred to step 8 |
| — Claude (build, max) | ✅ step 3, 2 findings fixed |
| — Codex (local, xhigh) | ✅ 4 findings → 3 fixed, 1 captured |
| — Local suites | ✅ green (storyVerify: standard) — file/test pass counts recorded in the commit body |
| — Copilot + CI | ⏸ deferred to the epic release PR (step 8) |
| 5a · Fast merge | ✅ merged --no-ff → jane/03-14-26/I20104-attachment-storage |
```

**One row per NUMBERED step, using this skill's own names.** The table's only job is to say where
the loop is, so a row labelled for something the step does not do resumes at the wrong operation.
CI release and settling belong to step 4's delegated review (`review` step 7), NOT to a step of
their own — step 5 is Merge and step 6 is the Completion ritual. Mark step 8 `n/a` on a one-off
rather than dropping the row, so "absent" never has to be told apart from "not reached". The
`Profile` row is the one non-step row besides the engine rows: it names the profile AND its
source, because a resumed session re-derives the review path and the verify width from it.

Rules that make it worth rendering rather than decorative:

- **State EVIDENCE, not intent.** "request registered in timeline" — never "requested". The
  `requestReviews` mutation returns success while silently creating nothing (see `ds-config.json`
  → `_pollTimeoutMinutes_readme`), so a row saying "requested" launders the exact failure the row
  exists to surface. Same for gates: "non-applicable (no path match, base develop, no label)"
  rather than a bare "skipped".
- **Every CONFIGURED engine gets its own row, and an unconfigured one gets an explicit "not
  configured" row.** They run concurrently and are the part most easily
  assumed rather than verified — and a missing row is indistinguishable from a forgotten engine.
- **A missing CI check is not a passing one.** `skipping` and "never ran" render identically in
  `gh pr checks`; say which, and why.
- It is a status render, not a gate. Never let producing it delay the step it describes.

## Working base — epic integration branches (the default)

An "epic integration branch" is the integration branch of the story's **release-unit ancestor** —
the container role (this org's Epic type) whose completion cuts a release, mapped by
`hierarchyRoles` in `.claude/ds-config.json`. Derived automatically in step 0, in precedence order:

1. Explicit override — a branch in `$ARGUMENTS`, or config `integrationBranch` non-null.
2. **Release-unit ancestor found AND `epicIntegrationBranches.enabled`** → that release unit's
   integration branch. Resolve the ancestor by **walking `parentNumber` up from the story and
   fetching each ancestor's work type explicitly** — `get_item` on the ancestor returns a resolved
   `workType` name — then matching it against `hierarchyRoles.releaseUnit` when that config key is
   set; when absent/null, resolve BOTH roles at runtime via `get_work_type_hierarchy`
   (leaf = the bottom childless levels, release unit = the container level directly above them —
   spelling included; the existing rule
   generalizes: never assume the literal "Epic"). That runtime resolution also backs every other
   `hierarchyRoles.leaf` read in this skill (one-off classification, next-unblocked selection,
   step 7 counting). **If NO ancestor matches a CONFIGURED `releaseUnit`, validate the configured
   type actually exists in `get_work_type_hierarchy` before concluding "no release unit"** — a
   renamed work type or a config typo must STOP with a question, never silently route the story
   to `baseBranch` and bypass integration batching.
   **`hierarchy` gives you the ancestor CHAIN, not their work types**: its entries are only
   `{itemNumber, title}` (see `ItemHierarchy`), so a match attempted against it silently finds
   nothing, falls through to `baseBranch`, and ships a story straight to develop outside its epic
   branch. Use `hierarchy` to enumerate ancestors, `get_item` to type them. Inspecting only the
   direct parent misses a release-unit ancestor two levels up. Named per
   `epicIntegrationBranches.pattern`, with the slug built per `epicIntegrationBranches.slugRule`
   when set (it says how to derive the slug from the title — casing, allowed characters, whether
   an execution-order prefix is stripped, how far to truncate — so two runs name the same epic the
   same way instead of each inventing a slug). Resolve: (a) the branch recorded for this epic in handoff
   memory; (b) `git ls-remote --heads origin "*/<epicNumber>-*"` (one match → reuse, several →
   ask); (c) none → create off fresh `baseBranch` and push. The date in the name is the branch's
   CREATION date, never re-minted. Cache per epic within a session. **Announce which branch was
   reused or created** — derivation is otherwise silent, and the operator (and the next session)
   needs to know which branch the epic is accumulating on.
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

Detect AUTOMATICALLY before step 0's plan-root resolution. **A bare plan ROOT is not a candidate
for this check** — it is a scope, so it skips straight to step 0's selection. But a bare root is
SYNTACTICALLY IDENTICAL to a specific item (`I20100` either way), so you must TEST for it, not
assume: **fetch the work type and only apply the one-off heuristic to executable one-day leaf
types (`hierarchyRoles.leaf` — this org's Story/Defect).** A container type (this org: Solution /
Capability / Epic) is a root — resolve it as the plan scope. Without that
test, an unnumbered root with no dependency edges satisfies the heuristic below and gets built as
a one-off. So fetch it as
`get_item(view: 'full', fields: ['number','title','workType','relationships'])` — **the default
summary projection OMITS `relationships`**, so a plan item whose only plan signal is a dependency
edge would look like a one-off and ship straight to develop. Then classify: **no `[N]` title
prefix AND no `blocked_by`/`blocks` edges → one-off** (a plan item always has one or the other). Both signals present → plan mode. Exactly one, in an unusual way →
do not guess: default to plan mode if a root resolves, else state your read and ask.

Deltas — **steps 1–6 run VERBATIM**, because the point is that the inner build loop is identical:

- **Step 0** — the item is given: skip plan-root resolution, ready-set and selection. **SKIP THE
  EPIC-BRANCH DERIVATION TOO — the working base is `baseBranch`, unconditionally.** Do not reason
  from "a one-off has no release-unit ancestor": `/devstride:create-story` and `/devstride:create-defect` both
  offer a release-unit item (this org's Epic) as a parent, so a one-off filed under one DOES
  have a release-unit ancestor. Without this explicit bypass the
  general rule would route it onto that epic's integration branch and strand it there until an
  unrelated epic releases. A one-off ships straight to develop, never an integration branch. Still
  run the gating/scope check and spec validation. **There is no plan root, so the root-marker step is
  skipped: an explicit profile in `$ARGUMENTS` wins, else `profile` in config, else `standard`**
  — announce it with that source. Because the working
  base is `baseBranch`, a one-off always takes step **4b** — the full PR ritual — **under every
  profile**. Fast mode is never available here, and
  the reason is the whole basis of the mode: there is no epic release PR behind a one-off, so its
  own PR is the only place Copilot and CI will ever see the code before it reaches develop.
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
- **DRY-CHAIN / TERMINAL:** zero not-Done, non-gated, unblocked candidates → the loop is DONE.
  Exit cleanly; do NOT loop back to re-ask. Report which: plan complete / N remain but blocked by
  X, Y / N remain but gated on human-infra decisions. Suggest `/devstride:plan <root>` to extend if the
  chain simply ran out; do not invoke it automatically.
- **GATING CHECK** — depends on a human/infra decision that is the user's? Flag it and move to the
  next candidate. **SCOPE CHECK** — what is buildable now vs deferred; record deferrals.
  **VALIDATE THE SPEC** — re-fetch with `view: 'full'` (the default omits `description`) and
  confirm its paths/symbols/assumptions against the codebase.
- **Resolve the delivery profile once the story is SELECTED**, not when the root is — the order
  and the marker are in the Delivery profile section above. The marker step walks the story's
  ancestor chain: the same walk the epic-branch derivation performs (`hierarchy` for the chain,
  `get_item` per ancestor) — fetch those ancestors with `view: 'full'` and take the NEAREST
  container's marker, else the root's, because a descendant with its own marker wins for its
  subtree (the contract's inheritance rule); a summary read finds nothing and falls through to
  config. Resolving from the root before selection cannot see that subtree marker. Announce
  `profile: <name> — from <source>` and fill the table's `Profile` row. Once per iteration —
  never carried over from the previous story, which may sit under a different container.
- Report the item, title, ready-set, the profile with its source, and the
  buildable-now-vs-deferred line.

## 1. Mark In Progress

`update_item` → In Progress lane, resolving the lane id from the item's work-type lane collection
via `get_workspace_context` if needed. Confirm it moved before branching.

## 2. Branch

Invoke **`branch-feature`** with `I<number>-<short-slug>`, and pass it the working base
explicitly so it overrides its own config resolution.

## 3. Build

Invoke **`ultracode-build`** as `I<number> <one-line goal/scope> profile: <name>` — the trailing
`profile: <name>` clause is the form the engine parses (it announces the profile "from the
invocation"); it honours its own knobs from the contract and must not re-resolve the profile
behind you. It returns: the item
number, a one-line summary, green-checks confirmation, the **deferral line**, the **deviations
list** (every material divergence from the written spec, not just deferrals), the
**untracked-deferral list**, and the **dismissed-findings list** (each review finding it chose
not to fix, with its rationale). Carry all four forward — deferrals + deviations into the PR body
(step 4) and the as-built reconciliation (step 6); untracked deferrals into step 6.5; dismissed
findings into the PR body (4b) or the merge-commit body (5a) so every dismissal is visible where
the code lands. Step 6 does not reconcile dismissals — a dismissal is a review disposition, not
a divergence from the spec.

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

The story is not a release; the epic it batches into is. So the cloud half of the ritual —
the configured cloud reviewers, CI, thread bookkeeping — is **deferred to the epic release PR**,
and the story is settled entirely locally. Every LOCAL engine on the resolved roster (see
`review`'s roster resolution) still runs, at full effort, on every story.

**THE FLOOR: fast mode requires ≥ 1 local engine behind the story.** If the resolved roster has
no local CLI engine AND no build-time Claude pass ran for this story (a caller bypassed
`ultracode-build`), route the story through **4b** instead and say why — a fast-merged story
with zero engines behind it is the one outcome this mode must make impossible. **The floor itself
does not move with the profile.** Under `prototype` the local CLI engine does not run on stories
(`localCliEngine` — `review`'s knob), so Claude's build-time pass is the engine behind the story:
the floor is satisfied, not lowered.

- **Claude adversarial** — already ran as `ultracode-build` phase 3 in step 3. Do not re-run it.
- **Local CLI engine (Codex, by default)** — when on the roster, invoke **`review` in local-only mode**
  (say so explicitly; pass the epic branch as
  the base ref **and the resolved profile by name** — `review` owns `localCliEngine` and
  `maxLocalReviewRounds`, so under `prototype` it launches no CLI engine and still runs its
  settle-time steps). It runs `review.localCommand` and returns triaged findings. Use the skill rather
  than invoking the CLI engine directly: the load-bearing flags live there (notably
  `-c mcp_servers.devstride.enabled=false`, without which the review wedges and returns nothing —
  a silent roster narrowing). Unconfigured (`localCommand: null`) → the Claude pass is the local
  gate, per `review`'s degradation ladder; a configured engine whose probe fails is reported
  as this-run degradation. **Invoke `review` in local-only mode EITHER WAY** — even with no
  CLI engine to run, it owns the settle-time steps that must happen once findings are settled;
  skipping the invocation because there is nothing for it to launch drops those steps silently.
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

It opens the PR — as a draft when the repo holds CI on drafts (`review.openPullRequestsAsDraft`,
true by default) **under every profile, `prototype` included**: the contract's
`releaseCiOrdering` applies to the RELEASE PR (step 8) only, and this PR is the story's sole
cloud gate, so the configured hold stands here — with every configured cloud reviewer
requested in the same call (none, if the
configured set is empty), then runs the
review-and-settle loop via `review`. **Review first, CI last**: every CONFIGURED engine
runs at max effort with no trivial-diff skip; in a draft-hold repo CI is held while the PR is a
draft and the ready-flip
releases it — one run, on the final reviewed diff. Never flip a PR ready yourself to start CI early;
that is the waste this ordering removes. This is ADDITIONAL to the build-time pass in step 3.

Ensure every deferral, deviation and dismissed finding (with its rationale) is in the PR body.
`review` returns its triage; out-of-scope
findings with no tracked home come back on the untracked-deferral list for step 6.5.

**The push/ready-flip race is `review` step 7's to prevent** — that is the skill that actually
pushes and flips, so the sequencing and the post-flip verification live there and every caller gets
them (standalone `/devstride:review`, a human-driven `/devstride:pr`, and `/devstride:release` included). In summary:
flipping in the same breath as a push means the flip triggers nothing and **CI never runs**, while
every job reports `skipping` — indistinguishable from a suite being legitimately non-applicable.
`review` returns the verified outcome; step 5 below must not treat a skipped board as green.

## 5. Merge

### 5a. Fast merge (came from 4a)

No PR to merge — integrate locally, then push the epic branch:

- Confirm the tree is clean and every 4a finding is fixed and committed.
- `git checkout <epic branch> && git pull --ff-only`, then merge the story branch with
  `--no-ff` so the story stays a legible unit in the epic's first-parent history — the epic
  release PR body and the close-out counts are both read off those merges. Message:
  `commitConventions.epicMergeFormat` (fallback:
  `merge: <itemNumber> [<N>] <short scope> into <epic-slug> integration`). Its BODY carries the
  dismissed-findings list from step 3 plus any 4a dismissals, each with its rationale — with no
  PR behind the story, that body is the only place a reader can see what was judged and let go.
- Base moved while you were building → merge the refreshed epic branch INTO the story branch
  first, re-run the local suites, and only then merge back. An unresolvable conflict is a
  genuine fork.
- Push the epic branch. **Only once that push SUCCEEDS**, delete the story branch **both locally
  and on the remote** (`git branch -d <story>` and `git push origin --delete <story>`). Order
  matters: if the epic push is rejected (the base moved between merge and push), the merge exists
  only locally, and deleting the remote story branch would destroy the sole remote copy of the
  work. `branch-feature` always
  finishes with `git push -u origin`, so the remote branch DOES exist — deleting only the local
  one leaves a stale remote branch behind for every fast-mode story.
- **Skip the rest of step 5 entirely** — the CI, draft-state and `skipping`-check rules below
  describe a PR that does not exist here. Go to step 6.

### 5b. PR merge (came from 4b)

- **The rebase already happened** in `review` step 7, before the ready-flip, so the CI run
  landed on the final mergeable SHA. Do NOT redo it by reflex — that rewrites the head and
  re-triggers everything. Just CHECK whether the base moved since; only if it did, rebase, push
  via `/devstride:push`, and accept the re-run. An unresolvable conflict is a genuine fork.
  **If you did re-push, the patch may no longer be the one that was reviewed** — apply
  `review` step 7's rule here too: compare the pre- and post-rebase patch, and if it CHANGED,
  re-run the local review streams (re-requesting the cloud reviewer — when one is configured — if the delta is substantive)
  before accepting the new CI run. A conflict resolution or interacting base change that no engine
  saw must not reach develop on the strength of a green re-run alone.
  **Also, when `verify.skipDuringStoryBuilds` is non-empty, RECOMPUTE its applicability from the
  new SHA before judging CI** (an empty list means there is nothing to
  recompute). A rebase or conflict resolution
  can change the final path set, so the pre-rebase decision is stale — and a check that just
  became mandatory would sit absent while the merge step treated the old gate set as
  authoritative.
- **A `skipping` check is not a passing check.** Confirm the applicable jobs actually RAN — see
  step 4's push/flip warning. Reading a skipped board as green is how a PR reaches merge with zero
  CI behind it.
- **Observe greenness, don't assume it.** Normally you are confirming an already-green state.
  Verify the PR is non-draft (a draft means CI never ran — unsettled, not green) and every
  applicable check is successful at the CURRENT head SHA. Re-poll only if you re-pushed. Use the
  same self-terminating background poll as `review` step 7 — never `gh pr checks --watch`.
- **Red CI:** failed to TRIGGER → close+reopen. Flaky/infra → `gh run rerun <id> --failed`, ~2
  tries. Real → reproduce, fix, push, re-poll. Never merge red; never give up after one failure.
- Per-story PRs into an epic branch do not wait on `verify.skipDuringStoryBuilds` checks. On a
  develop-base story PR, any suite in that config list is evaluated per its configured
  applicability; with the list empty there is nothing to evaluate, and an
  absent check is settled, not pending. **Read the config before concluding either** — an
  absent check for a suite the config DOES list is a gate that never ran, not a settled one.
- **Re-check zero unresolved review threads immediately before merging** (the paginated query
  from `review`'s references). `review` verified it at settle time, but a comment posted
  in the gap between settle and merge — a late reviewer, a second Copilot pass — would otherwise
  merge silently unaddressed, and a merged PR showing open review comments reads as an
  unreviewed merge. Non-zero → loop back through `review` steps 3–6 (reply + resolve) first.
- **Merge guard — only when `ci.freezeBaseWhileReleasePrReady` is `true` (the default; an explicit
  `false` disables it, and the merge proceeds with one line saying so):** before ANY merge whose
  TARGET is `release.releaseSource` — normally the same branch as `baseBranch`, but the guard keys
  on the release source, since a merge elsewhere cannot stale the release and a merge INTO the
  release source must be held whatever it is called — here, and the epic release at step 8, look
  for an open, NON-DRAFT pull request with head `release.releaseSource` and base
  `release.productionBranch`. One exists → a release is
  in its CI window; merging beneath it re-runs its merge preview and stales its reviewed diff. Do
  not merge: say which release PR is holding the base, wait for it to merge (poll on a sensible
  interval, bounded by `review.pollTimeoutMinutes`), then merge. A still-draft release PR holds
  nothing — its review has not settled and its CI has not started.
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
- **Reconcile the spec (as-built)** if the implementation deviated materially — deferred scope, a
  different approach, or a false spec assumption:
  1. Re-fetch the description with `view: 'full'`, then `add_comment` it verbatim under
     "📋 Original spec (as planned) — superseded by the description below". Both fields are HTML:
     pass `{ html }`, never Markdown.
  2. `update_item` the description to the as-built spec: an italic as-built note naming **what
     the work actually shipped in**, a **Deviations from the original spec** list with one-line
     rationales, then a concise **As shipped** summary.
     **Cite the artifact that EXISTS for this story's path** — the two paths differ and getting it
     wrong invents a reference: a **4b story has a PR**, so "reflects what shipped in PR #<n>";
     a **4a fast-mode story has none**, so cite its merge SHA and integration branch — "reflects
     what shipped in `<merge-sha>` on `<integration-branch>`" — and let step 8 add the release PR
     link later. Never write a PR number on the fast path: there is nothing to write, and a
     plausible-looking number is a dangling pointer at somebody else's work.
  - Matched the spec with no material deviations → skip; note "shipped as specified".
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
- Update handoff memory: story shipped, remaining work, **the resolved plan root together with
  the delivery profile and its source**, and **the
  epic's integration branch keyed to its epic number** (or "develop — no epic"). The profile
  is recorded WITH the root, never alone: it is a property of the plan, and a resumed session
  must re-resolve it from the same root rather than trust a remembered name.
- **Close-out summary**, computed AFTER 6.5 so spliced items are counted:
  ```
  ✅ Completed [23] I20130 — Enforce seat invariant
  🎚 Profile: standard — from the plan root I20100
  📦 3 stories remaining in Epic "V1 Seat Management" until release-ready
     (12 remaining in the full plan)
  ```
  Count not-Done leaf descendants (`hierarchyRoles.leaf` types — this org's Story/Defect) of **the
  SAME release-unit ancestor step 0 resolved to derive the
  working base** — not merely the story's direct parent. For a story nested below an intermediate
  container, counting the direct parent excludes sibling subtrees under that release unit, so the
  count can reach zero while the release unit still has open work and step 8 would publish a
  PARTIALLY COMPLETE release unit
  to develop. Also count the whole plan root. If the plan is unnumbered (no `[N]` prefixes yet —
  the canonical convention: `${CLAUDE_PLUGIN_ROOT}/skills/plan/references/execution-order-numbering.md`),
  still emit the summary using
  the bare item number and counts, and note that `/devstride:plan <root>` would add execution-order
  numbering. When the release unit hits **zero** and the working base is its integration branch, say
  so and **run step 8 now**, before returning to step 0.
- Return to **step 0** (after step 8 when it ran). On the DRY-CHAIN condition, EXIT and report.

## 8. EPIC RELEASE — epic branch → develop, fully reviewed

Runs when step 7 finds the release unit (this org's Epic) at zero remaining leaves, the working
base is its integration branch,
**and auto-release is on** — which is `epicIntegrationBranches.autoRelease` whenever that key is
PRESENT in config, and the profile's `autoRelease` default (from the contract) ONLY when the key
is ABSENT. A present key wins whatever the profile says, and the contradiction is reported:
"profile prototype, but `autoRelease` is false in config — stopping at release-ready as
configured". With auto-release off, do NOT cut or
merge the release: report the epic as release-ready and stop for an explicit manual release. A
config flag the loop ignores is worse than no flag — the operator believes they disabled
auto-release while the loop merges to develop anyway.
The release unit's whole batch of leaf merges lands on develop as ONE reviewed PR.

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
- **Review-and-settle — and CHECK WHICH SCOPE APPLIES, because fast mode changes it.**
  - **Fast mode was used** (`fastStoryMerges.epicReleaseIsFirstCloudPass`, the default path):
    **this PR is the FIRST pass by the cloud-side roster (when one is configured) or CI over ANY
    of this code.** Review the FULL diff —
    every story in the batch — not just the integration surface. The stories were locally
    reviewed, so expect fewer findings than a cold diff, but the cloud gate has genuinely not run
    yet and treating this as a re-review would let an entire epic reach develop having never been
    cloud-reviewed. That is the one way fast mode could actually cost quality; it is prevented
    here and nowhere else.
  - **Stories took the full 4b ritual** (develop-base work batched onto a branch, or fast mode
    disabled): each story was already fully reviewed at its own PR, so point the review at what
    per-story review COULDN'T see — the cross-story integration surface and the develop-merge
    conflict resolutions — rather than re-reviewing approved diffs.
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
  `${CLAUDE_PLUGIN_ROOT}/skills/release/references/docs-hooks.md`) and invoke that skill in mode
  `update`; relay what it reports. `live: false` is not optional here: the epic has reached the
  base branch, not production, so the skill stages the documentation and the production release
  (`release` step 5b, `live: true`) is what publishes it. An epic hook that published would put
  public docs ahead of the product. **Never release notes here**, under any setting — those are
  the production release's step 5c, and only on the owner's `--release-notes`.
- **Close out**: `add_comment` on the RELEASE-UNIT item (release PR link, list of shipped leaves,
  date), move it to Done if the org tracks lanes at that level, update handoff memory, sync local
  develop.
- **Link the release PR onto each constituent leaf whose as-built note deferred it.** Step 6 tells
  a fast-mode story to cite its merge SHA and say the release PR follows at step 8 — this is where
  that promise is kept. `link_pull_request` (or `add_comment`) the release PR on every leaf in the
  batch. Skip it and every fast-mode story ends pointing at a link that never arrives.
- Surface — never perform — the follow-on owner-cut `develop → master` promotion (`/devstride:release`).
- Out-of-scope findings from this review go through step 6.5 like any other.

IMPORTANT:
- Empty `$ARGUMENTS` means `next`.
- **Serial by design.** The plan's "parallel waves" describe SHAPE, not an instruction to run
  concurrent builds: `branch-feature` aborts on a dirty tree, builds share ONE working tree and
  ONE local DB (concurrent vitest runs corrupt each other's worker databases), and the MCP writes
  to production. Surface the ready-set for a human to fan out manually; keep the loop serial.
- **Injection is part of the loop.** Never let a real out-of-scope finding ship as PR prose only.
- **The release-unit container (this org's Epic) is exactly that — the release unit.** Develop
  only receives a COMPLETE, refreshed, fully-reviewed release unit with every applicable gate
  green — or a one-off that settled the same gate set.
