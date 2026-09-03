---
name: doctor
description: Diagnose delivery-loop prerequisites read-only — environment, plugin, DevStride, config, CI, merge gates and docs — then offer only approved safe repairs.
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

Diagnose whether this checkout can run the delivery loop and give exact repairs. Optional section:
`env`, `plugin`, `devstride`, `config`, `ci`, `gates`, or `docs`: $ARGUMENTS
With a repo root, run §4's status-line check on every invocation regardless of section; otherwise N/A.

**Two-phase contract:**

- **Phase 1 is READ-ONLY.** Inspect and report every requested check before fixing anything. Do not
  commit, checkout, write-fetch, push, create branches, change config, install/update, edit
  workflows, or call a DevStride write tool. Every "Fix:" below is text to print.
- **Phase 2 starts only after the complete report and an explicit yes.** First read
  `${CLAUDE_PLUGIN_ROOT}/skills/doctor/references/repairs.md`; its eligibility tiers are fixed.
  Write only under this repo's `.claude/`, except the separately confirmed personal-status-line
  cleanup in `repairs.md`; never repair workflows, git state, DevStride records, or stages.

## How to report

**Human recap.** Walk every requested section after failures. For each result say **PASS**,
**FAIL**, or **N/A**, then `Found:` in plain words. A failure adds `Why it matters:` and `Fix:`
with the exact command or edit. After any repair add `Changed:` and `Result:`. Never pass an unrun
check. End `ready`, `ready-with-warnings` (name them), or `not-ready` (name blockers), plus one
next action. For each failure symptom, read
`${CLAUDE_PLUGIN_ROOT}/skills/doctor/references/silent-failures.md` (also the rationale for §4–§6).

## 1. Environment (`env`)

- **git** — `git --version`; confirm you are inside a repo (`git rev-parse --is-inside-work-tree`).
  Not a repo → the rest is N/A; say so and stop the section.
- **An `origin` remote** — `git remote get-url origin`, checked **by name** because delivery skills
  hardcode it. Other remotes but no `origin` → say which.
- **gh present** — `gh --version`. Missing → the whole delivery half is unavailable: no pull
  requests, no review threads, no ready-flip. Fix: install GitHub CLI (`brew install gh`, or
  cli.github.com).
- **gh authenticated** — `gh auth status`. Fix: `gh auth login`.
- **gh scopes, for the ACTIVE account** — read the account marked active (`gh auth status`
  can list several). Minimum `repo` + `read:org`, plus `workflow` if the loop edits workflow
  files. Fix: `gh auth refresh -s repo,read:org` — **including `workflow` in the SAME list
  when that is the missing scope**. Auth from `GH_TOKEN`/`GITHUB_TOKEN` → say so: `refresh`
  cannot touch an environment token; unset it or reissue with the scopes.
- **Forge** — non-GitHub `origin`: delivery assumes GitHub/Actions; planning still works.

## 2. Plugin install (`plugin`)

- **Installed and enabled** — parse `claude plugin list --json`; report its disk version. Also name
  the running version (disk and runtime differ until reload/restart).
- **Marketplace registered** — `claude plugin marketplace list`. Absent → the plugin cannot update.
  Fix: `claude plugin marketplace add devstride/claude-plugin`.
- **Version currency** — run
  `${CLAUDE_PLUGIN_ROOT}/skills/doctor/references/version-currency.md`: use its strict shared tag
  helper (not Releases) and report installed/newest. If behind, tell the user to invoke
  `/devstride:update` separately and stop; Doctor must not invoke this explicit-only command. If the
  skill is unavailable, print exact id/scope bootstrap commands, then reload and check for errors.
- **`python3` on PATH** — the session-start hook, the reviewer wait script and the cost harness
  run in python3; without it the wait exits at once with a usage-error `RESULT`. FAIL with a
  platform install hint.
- **Learned reviewer latency** — from
  `${XDG_CACHE_HOME:-~/.cache}/devstride-plugin/reviewer-latency.json`, report each reviewer's
  samples, p50, p95, and derived bound under this repo's `pollTimeoutMinutes`; below the sample
  minimum report `cold — the wait uses pollTimeoutMinutes`. INFO only; schema/format:
  `${CLAUDE_PLUGIN_ROOT}/skills/review/references/reviewer-latency.md`.
- **Session-start check** — read the per-repository record
  `${XDG_CACHE_HOME:-~/.cache}/devstride-plugin/repo-<first-12-hex sha1 of repo root>.json`; derive
  the root with `git rev-parse --show-toplevel` and use the schema in `version-currency.md`. On one
  line report `checkedAt`, `running`, `newest`, `mode`, `result`, `install`, `statusLine`. Absent:
  say never run here (pre-1.2.0 plugin, disabled hooks, or
  `DEVSTRIDE_PLUGIN_UPDATE_CHECK=0`). Modes: `notify` fallback; `auto-update` only for a repo-bound
  project/local install; `pinned` never updates. Shared user copies hand off to update, managed
  copies to their administrator, and ambiguous copies to Doctor. Explain every result using the
  reference. A verified disk change needs plugin reload (restart only if reload fails).
- **Repo declaration** — `.claude/settings.json` enables but does not install. Print the one-time
  `claude plugin install <id>` using its actual `enabledPlugins` id. Always run both
  `git ls-files --error-unmatch .claude/settings.json` (tracked?) and
  `git check-ignore -v .claude/settings.json` (ignored?); an untracked file reaches nobody.

## 3. DevStride connection (`devstride`)

- **A server exists and is CONNECTED** — `claude mcp list`. The bundled one appears as
  `plugin:devstride:devstride`; a plain `devstride` entry is one you or your project configured.
- **Not connected.** Say: until sign-in, skills have no DevStride tools and nothing prompts; the
  symptom is missing tools, not an auth error. Fix `/mcp` and browser sign-in.
- **More than one connected** — FAIL: different namespaces (`mcp__devstride__*` and
  `mcp__plugin_devstride_devstride__*`) leave calls able to reach either organization. Inspect with
  `claude mcp get <name>`; OAuth uses `claude mcp logout <name>`, API-key headers require
  `claude mcp remove <name>`.
- **Do not call a DevStride tool to test this.** Presence and connection state are enough.

## 4. Config file (`config`)

- **Present and parses** — read `.claude/ds-config.json`. Absence is legal: report shipped defaults,
  but do not call ready until the effective branches pass below.
- **Branch roles resolve.** Even for `doctor config`, find the repo/origin and run read-only
  `git ls-remote --heads origin` (never fetch). If unavailable, use normalized local and
  `refs/remotes/origin/*` names, label them possibly stale, and never PASS an unconfirmed branch.

  Resolve all four effective values, including inline fallbacks when their keys are absent:

  | Role | Config key | Inline fallback |
  |---|---|---|
  | normal work base | `baseBranch` | `develop` |
  | release source | `release.releaseSource` | `develop` |
  | production | `release.productionBranch` | `master` |
  | hotfix base | `hotfixBaseBranch` | `master` |

  Require every value on `origin`; require effective base, release source, and production in
  `protectedBranches`. Explicit valid names win without heuristic warnings. Only when an absent
  key's fallback is missing, match whole remote-head names: production = `main`, `master`,
  `production`, `prod`; development = `develop`, `development`, `staging`, `stage`, `canary`,
  `test`, `testing`, `qa`; `trunk` may be a single trunk.

  - One development + one production candidate: print the four-key mapping (base/release source on
    development; production/hotfix on production).
  - Multiple candidates for either role: list them as ambiguous; never pick first.
  - One production candidate or `trunk` plus topic branches only: suggest all four on that trunk,
    requiring confirmation.
  - Development only: suggest base/release source only; never infer production from staging,
    canary, test, or QA.

  A missing effective branch FAILs. For an absent-key fallback include the candidate mapping; for
  an explicit name identify its key and never replace it heuristically. Print suggested JSON; Phase
  2 may offer `/devstride:setup`, or the user can edit all four keys, then rerun `doctor config`.
  If shipped fallbacks exist, PASS and report them.
- **Delivery profile — the effective one, and its source.** Read `profile` and report it as one
  line: `profile: <name> — from .claude/ds-config.json`, or `profile: standard — key absent, shipped
  default`. The contract behind the word is
  `${CLAUDE_PLUGIN_ROOT}/skills/plan/references/delivery-profiles.md`; read its resolution order,
  and say that a plan root's own marker or an explicit skill argument outranks the file at run time
  — this reports the repository's default, not what a particular plan will run under, and it never
  calls a DevStride tool to find out. A value that is not one of the three names is a FAIL: the
  skills read it as absent and fall through to `standard` without a word. Fix: set it to
  `prototype`, `standard` or `enterprise`, or run `/devstride:setup`.
  **Then the contradictions.** Compare `epicIntegrationBranches.autoRelease` and
  `review.pollTimeoutMinutes` with the profile's values in
  `${CLAUDE_PLUGIN_ROOT}/skills/setup/references/config-defaults.md`, and
  `epicIntegrationBranches.fastStoryMerges.enabled` against `prototype` only, and only when
  `verify.typecheck` is set. A present key that differs is **informational, not a FAIL** — the
  explicit key wins by contract — but say which key, which value, and what the profile would
  have written (`silent-failures.md` holds why). A present `review.localCommand` under
  `prototype` is NOT a contradiction — it names the engine without scheduling it.
  `profileOverrides`: report as a WARNING any name that is not a knob in the contract's table;
  nothing else.
- **Unrecognized keys — report as a WARNING, not a typo accusation.** List keys you do not
  recognize and let the user judge. **Exclude by convention**: any key whose leaf name starts with
  `_` (the `_*_readme` documentation convention, used pervasively in real configs) and `$schema`.
  Check against the published [configuration reference](https://docs.devstride.com/developer-experience/agentic-skills/configuration-reference),
  **not** by grepping skill prose — several real keys are descriptive and appear in no skill.
  Where a key is one edit away from a real one, offer that as a possibility, not a verdict.
  `profile` and `profileOverrides` are recognized keys whether or not the published reference
  lists them yet.
- **`localEnvironment`** — report the block. Absent → the shipped default is in force (every
  command `null`, `instanceBoundTo: none`): `branch-hotfix` asks before touching a database.
  Present → report `instanceBoundTo` and each command's resolution per the rule below.
  WARNINGS: `instanceBoundTo: directory` with a `null` `create` (claims isolated instances,
  gives no way to make one); and under `directory`, a null **or absent** `recreate` beside a
  non-null `migrate` (those commands go forward — `branch-hotfix` then has no backward path
  and will migrate forward only where safe, else STOP and ask; reasoning in `config-defaults.md`). **Never warn under
  `branch` binding** — no backward transition happens there.
- **`stage`** — absent, or `resolve: null` → **N/A, not a failure**: this repository deploys no
  per-environment infrastructure. Present → run `resolve` ONCE from the
  repository root and report what it printed; empty output is "no stage bound here", never an
  error. A non-zero exit WITH output, or output spanning several lines, is a FAIL — consumers read
  one line and treat empty as absent, so a noisy command silently renders the wrong stage. Report
  `productionStages`, and WARN when the resolved stage is in it: this checkout points at
  production. **Never infer a stage from the branch name, and never report
  `localEnvironment.instanceName` as one** — different axes; `silent-failures.md` §4 has why.
- **Status line / personal settings** — run the helper as `inspect --local <repo-root>` and
  `inspect --user <repo-root>`; it lives at
  `${CLAUDE_PLUGIN_ROOT}/skills/doctor/scripts/statusline-override.py`. Read shared settings too;
  user settings use `CLAUDE_CONFIG_DIR`, else `~/.claude`. Never print a personal command.
  Precedence is managed > CLI > local > shared project > user. Resolve accessible
  `disableAllHooks`; effective `true` FAILs and blocks cleanup. Known managed/CLI disables also
  block cleanup but remain report-only. Local masking and invalid personal JSON FAIL; after shared
  works, a user fallback is INFO.

  Require the canonical shared pair regular, unignored, committed in `HEAD`, clean in index/tree,
  and rendering non-empty output from `bash .claude/statusline.sh`. No shared/personal setting is
  N/A; one shared half FAILs. Phase 2 repairs shared first, then asks separately per personal key.
  After removal restart, rerun `doctor config`, inspect `/status`, and report rendered segments.
  Only structural `stage` absence becomes a question; never ask about transient model, effort,
  branch, or PR blanks. Details:
  `${CLAUDE_PLUGIN_ROOT}/skills/setup/references/statusline-segments.md`.
- **Commands resolve** — for each configured command (`verify.*` — note `verify.typecheck` is an
  **array**, so iterate it — `review.localCommand`, `review.localAssistCommand`,
  `generated.regenCommand`,
  `preShipChecks[].command`, each non-null `localEnvironment.*` command, and `stage.resolve`): split on `&&` and `;`, take the first token of **each** segment, and
  skip shell builtins (`cd backend && pnpm test` starts with `cd`, which always resolves). A
  single-word command that does not resolve may be a shell alias or
  function rather than a real gap — report "not on PATH (may be an alias)" rather than a flat FAIL.
- **`conventionsDoc` exists** — if set, the file must be present; the build engine reads it, and
  a missing one quietly costs you that.

## 5. The CI draft gate (`ci`)

**Applicability comes from workflows plus all three draft-hold flags** —
`review.openPullRequestsAsDraft`, `readyForReviewReleasesCi`,
`ciHeldUntilReviewSettled`. No PR workflows + all false is N/A. PR workflows + all false is a
**FAIL**: the loop cannot keep cloud CI behind review; fix `/devstride:setup ci`. **Mixed values
are also a config FAIL** — runtime takes the strictest safe behavior, but the guarantee is not
legible until all three and the workflows agree.

Scope the audit to workflows with an `on: pull_request` trigger. A workflow triggered only by
`pull_request_review` or `pull_request_review_comment` is PR-related but must run on drafts —
exempt it, and do not advise gating it. Likewise a **convention-only workflow** — the shape is
defined once, under pattern D of
`${CLAUDE_PLUGIN_ROOT}/skills/setup/references/ci-cost-patterns.md`, and covers both the
`opened`-only and the `opened` + `converted_to_draft` + `ready_for_review` forms. It is a policy
notice, not a CI gate: remove it from the population before the four-events, concurrency and
draft-gate checks; list it under INFO as present.

Two separate checks, and **the first is the one everyone misses**:

- **`on.pull_request.types` must carry all four of `opened`, `synchronize`, `reopened`,
  `ready_for_review`** — GitHub's defaults omit `ready_for_review` (the ready-flip then creates
  NO run at all), an explicit list REPLACES the defaults (naming one event breaks the rest),
  and `opened` is required (standalone review on a non-draft PR settles against CI that was
  never created without it). FAIL with: declare all four. `converted_to_draft` is optional —
  suggest it when `concurrency` is present. The full evidence:
  `${CLAUDE_PLUGIN_ROOT}/skills/setup/references/detector-evidence.md` §A5.
- **Jobs gated on the draft condition** — match against `ci.draftGateCondition` (the config names
  the expression; default `github.event.pull_request.draft == false`) and accept equivalent forms
  such as `if: ${{ !github.event.pull_request.draft }}`. **A job is also gated if ANY job it
  `needs` is gated** — real workflows gate one cheap job and fan the result out, and GitHub's default
  job condition requires every dependency to *succeed*, so one skipped dependency skips the
  dependent. Requiring the whole closure to be gated is the wrong test and false-FAILs exactly the
  layout this rule exists for: a gated job beside an ungated utility job, both feeding the expensive
  one. The exception is a job that opts out of that default with `if: always()` or similar — it runs
  regardless, so it is genuinely ungated.
  Ungated → CI fires on open and again on every review-fix push; nothing errors, you simply pay
  repeatedly and lose the run-once guarantee.
- **`ci.gateJobName`** — if set, confirm a job with that **display name** (`name:`) or key exists;
  the loop uses it to prove the flip released CI. Unset → note the fallback to detecting a new run.
- **The CI-cost mechanics** (`${CLAUDE_PLUGIN_ROOT}/skills/setup/references/ci-cost-patterns.md`),
  each a WARNING when missing, never a FAIL — CI is correct without them, just more expensive:
  - a top-level `concurrency:` block with `cancel-in-progress: true` on every pull-request
    workflow (a superseded run is cancelled instead of finished);
  - on workflows that also run on `push` to the production branch, a tree-identical skip
    against the base branch (a promotion merge has the tree the base just tested). **Judge it
    on whether it CAN FIRE, not on whether the step exists** — pattern C holds the condition:
    the merge-promotion path reads `HEAD^2`, which must be in the checkout (depth 0 or 2+, or
    a deepening fetch; the effect, not the flag); otherwise it is *present but inert* — report
    at the same WARNING level, naming what is missing. A step in a job with NO checkout is a
    separate, harsher finding: it fails the gate job and everything that `needs` it on every
    production push (why these shapes matter: `silent-failures.md`);
  - a draft-convention check that fails a non-draft pull request opened by a person (INFO, not a
    warning — it is a courtesy to humans, not a gate).
  Fix for all three: `/devstride:setup ci`, which shows each change as a diff.
- **Run-once in practice.** Run the last seven days through the `ci-audit` skill's method and
  report `Σ executed PR runs ÷ Σ distinct workflows that executed per pull request` — `1.0` is
  the design; above it, name the pull requests, workflows, causes. Measured, never assumed.

## 6. Merge gates (`gates`)

The point: **find out whether anything actually checks the code before it merges.**

- **When fast merges apply.** They apply when the resolved working base is an **epic integration
  branch** and `epicIntegrationBranches.fastStoryMerges.enabled` is on (the default). Such an item
  gets no pull request and no CI of its own, so its local suites are the only gate *it* receives —
  the cloud engines and CI are deferred to the release pull request, not removed.
- **The effective profile's story gate and epic gate must be runnable.** Read `storyVerify` and
  its release-boundary width from
  `${CLAUDE_PLUGIN_ROOT}/skills/plan/references/delivery-profiles.md`. Type-check/touched-suite
  story gates need `verify.typecheck` and, where available, `verify.testSingle`; the epic's full
  gate needs `verify.test` unless an exact matching CI job owns it. Enterprise additionally needs
  lint where applicable. Name the missing command and which boundary would otherwise be unchecked.
- **Give the fix that matches their config**: check `integrationBranch` FIRST — an explicit
  value takes precedence over `epicIntegrationBranches.enabled` entirely, so with one set,
  flipping the flag changes nothing. Say which case applies: set the verify commands, or clear
  `integrationBranch` **and** disable epic branches.
- **Review roster** — report `review.localCommand`, optional `review.localAssistCommand`, and
  `review.automatedReviewers`. An empty configured roster is legal: the built-in merge-boundary
  pass remains. Hold every engine to the contract in
  `${CLAUDE_PLUGIN_ROOT}/skills/setup/references/review-engines.md` — **never fault one for being
  unrecognised**; apply a catalogued engine's extras (Codex: a literal effort tier is an
  optimization warning). A legacy base-only command may omit placeholders (` --base <value>` is
  appended), but WARN that contextual follow-ups will be skipped. `/devstride:setup review`
  migrates.
- **`review.mandatoryLenses`** — absent or `[]` → N/A. Each entry needs `name`, `paths` (a
  non-empty array) and `question`; anything else → FAIL naming the entry (the skills ignore it
  aloud). WARN a glob with no `/`, or a bare `*`/`**`: it matches every file, so the lens runs on
  every diff. Contract: `${CLAUDE_PLUGIN_ROOT}/skills/ultracode-build/references/mandatory-lenses.md`.
- **`preShipChecks`** — if any entry exists, confirm its command resolves (same segment-splitting as
  §4); these run at the ship boundary and nothing in CI covers them.

## 7. Documentation hooks (`docs`)

The plugin never edits documentation itself; it invokes local skills named in `docs.updateSkill` and
`docs.releaseNotesSkill` (contract: `${CLAUDE_PLUGIN_ROOT}/skills/release/references/docs-hooks.md`).
Neither set → **N/A**, not a failure: the release skill's docs pass reports itself skipped and
`--release-notes` reports itself unavailable.

- **Each named skill exists** — `.claude/skills/<name>/SKILL.md`; missing → FAIL (a dangling
  hook; fix `/devstride:setup docs`). Also `git check-ignore` the path (a gitignored skill
  exists on one machine only).
- **Each skill's `check` mode passes** — invoke it with `check` (read-only by contract); translate
  its verdict and fix into **Found / Why it matters / Fix**, keeping exact command/path evidence.
  No `check` mode → FAIL naming the template to rebuild from.
- **A legacy `release.docsRepo` block**, with or without a `docs` block beside it → FAIL: the
  release skill never acts on it. Fix: `/devstride:setup docs` (migrates and removes it).
- **`release.deployVerification`** — if set, its first token resolves (§4's rule); never run
  it. Unset → the release skill asks the owner to confirm the deploy; not a gap.
- **`release.postDeployCheckSkill`** — set → `.claude/skills/<name>/SKILL.md` must exist
  (missing → FAIL, a dangling hook; contract:
  `${CLAUDE_PLUGIN_ROOT}/skills/release/references/post-deploy-check.md`). Unset → N/A; the close-out
  reports `not configured`.
- **Say the release-notes default** — notes only on `--release-notes`; the loop never decides a
  release "deserves" one.

## Closing — the report, then the offer

Print the verdict, then ordered fixes, separating commands from manual edits.

Only then follow `references/repairs.md`: one numbered offer list, **one batch question**, ordered
repairs, and rerun each Phase 1 check. Name failures not offered. Leave writes unstaged/uncommitted
and say so. Non-interactive invocation prints the list and repairs nothing.

IMPORTANT:
- **Never emit a command you have not confirmed exists.** Check flags with `--help` first. A
  confidently wrong command is worse than no suggestion, because it will be trusted and it wastes
  the run it was meant to save.
- **Never repair during Phase 1, and never repair what `repairs.md` does not list.** The
  classification is the safety property. Widening it in the moment — because a fix looks obviously
  right — is exactly how a diagnostic becomes a thing nobody dares run first.
