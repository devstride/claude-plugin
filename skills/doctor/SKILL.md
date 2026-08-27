---
name: doctor
description: Check that this repo and machine are set up correctly for the delivery loop — git, gh, the plugin, the DevStride connection, the config file, the CI draft gate and CI cost mechanics, the merge gates and the documentation hooks — and report exactly what is missing and the command that fixes it. Read-only.
---

Diagnose whether the delivery loop will actually work here, and say precisely what to fix if
it will not — after installing, after changing `.claude/ds-config.json`, or when the loop
behaves unexpectedly.

**This skill is READ-ONLY.** It runs inspection commands and reads files. It never *mutates* git
state — no commit, checkout, fetch-that-writes, push, branch or config change — never installs or
updates anything, never edits a workflow, and never calls a DevStride write tool.

> **Every "Fix:" below is text to PRINT, not a command to run.** Even when a fix looks safe
> and obvious, report it and stop — running the repair is what would make this skill unsafe to
> recommend as the first thing anyone tries.

Optional argument — a section name (`env`, `plugin`, `devstride`, `config`, `ci`, `gates`, `docs`) to
check just one: $ARGUMENTS

## How to report

Walk every section, even after a failure. Someone with three problems should learn all three in one
run, not one restart at a time.

Each check emits **PASS**, **FAIL**, or **N/A** (with the reason). Every FAIL carries three things —
never a bare cross:

1. **What is wrong**, concretely.
2. **What it breaks** — the symptom they would otherwise be debugging.
3. **The exact command or edit that fixes it.** If a check genuinely has no command fix, say what to
   change and where; never leave a FAIL without a next action.

Finish with a verdict: ready, ready-with-warnings (naming them), or not-ready (naming the
blockers). If a check could not be run, say so — never report an unrun check as a pass.
**Every prerequisite of this loop fails silently — the value is turning silence into a
sentence. Read `${CLAUDE_PLUGIN_ROOT}/skills/doctor/references/silent-failures.md` when
writing the "what it breaks" line of a FAIL** — it holds the symptom table and the extended
reasoning behind §4–§6.

## 1. Environment (`env`)

- **git** — `git --version`; confirm you are inside a repo (`git rev-parse --is-inside-work-tree`).
  Not a repo → the rest is N/A; say so and stop the section.
- **An `origin` remote** — `git remote get-url origin`, checked **by name**: the delivery
  skills hardcode it, and a fork checkout with only `upstream`/`fork` passes a generic
  has-a-remote test then fails at the first push. Other remotes but no `origin` → say which.
- **gh present** — `gh --version`. Missing → the whole delivery half is unavailable: no pull
  requests, no review threads, no ready-flip. Fix: install GitHub CLI (`brew install gh`, or
  cli.github.com).
- **gh authenticated** — `gh auth status`. The one people miss, because an *installed* `gh` looks
  like a working one. Fix: `gh auth login`.
- **gh scopes, for the ACTIVE account** — read the account marked active (`gh auth status`
  can list several). Minimum `repo` + `read:org`, plus `workflow` if the loop edits workflow
  files. Fix: `gh auth refresh -s repo,read:org` — **including `workflow` in the SAME list
  when that is the missing scope**. Auth from `GH_TOKEN`/`GITHUB_TOKEN` → say so: `refresh`
  cannot touch an environment token; unset it or reissue with the scopes.
- **Forge** — if `origin`'s URL is not GitHub, say plainly that the delivery half assumes GitHub and
  GitHub Actions and has no adapter for other forges. The planning half still works.

## 2. Plugin install (`plugin`)

- **Installed and enabled** — `claude plugin list` (prefer `--json` if parsing). Report the version.
- **`claude plugin list` reads DISK, not this session** — a session serves what it loaded at
  startup, so the two can disagree (installed-but-not-restarted; removed-but-still-running).
  Say which you are reporting.
- **Marketplace registered** — `claude plugin marketplace list`. Absent → the plugin cannot update.
  Fix: `claude plugin marketplace add devstride/claude-plugin`.
- **Version currency** — the recipe is `${CLAUDE_PLUGIN_ROOT}/skills/doctor/references/version-currency.md`
  (tags not Releases; strip the `devstride--v` prefix; `sort -V`; the installed id and scope from
  `claude plugin list --json`, never assumed; both update commands, then restart). Run it and
  report installed vs newest. Behind → print the two commands with the id and scope you read.
- **`python3` on PATH** — the session-start hook, the reviewer wait script and the cost harness all
  run their logic in python3; without it the wait exits at once with a usage-error `RESULT`. FAIL
  with the install hint for the platform.
- **Learned reviewer latency** — read `${XDG_CACHE_HOME:-~/.cache}/devstride-plugin/reviewer-latency.json` and report
  per reviewer id: samples, p50, p95, and the bound `review` derives under this repository's
  `pollTimeoutMinutes` — or "cold — the wait uses `pollTimeoutMinutes`" below the script's sample minimum.
  Informational, never a FAIL; the schema and the doctor line's format are in
  `${CLAUDE_PLUGIN_ROOT}/skills/review/references/reviewer-latency.md`.
- **Session-start check** — read the per-repository record
  `${XDG_CACHE_HOME:-~/.cache}/devstride-plugin/repo-<sha1 of the repo root, first 12 hex>.json`
  (schema in `${CLAUDE_PLUGIN_ROOT}/skills/doctor/references/version-currency.md`; key from `git rev-parse --show-toplevel`) and report `checkedAt`, `running`, `newest`, `mode` and
  `result` as one line. Absent → the check has never run here: say so, and say why it might be
  (plugin older than 1.2.0, hooks disabled, or `DEVSTRIDE_PLUGIN_UPDATE_CHECK=0`). `mode` comes
  from the repository's `plugin` config block — `notify` is the default; `auto-update` applies
  releases at session start and asks for a restart; `pinned` reports and never nags. A
  `result` of `unreachable` on the last run is informational, not a FAIL: the check stays
  silent offline by design and records it here instead.
- **Repo-level declaration** — `.claude/settings.json` registers and enables, it does **not
  install**: every teammate still runs `claude plugin install <id>` once, and **the id comes
  from the `enabledPlugins` key you just read**, never a printed literal (a repo may enable
  either marketplace entry). **Then check the file reaches them — two questions, two
  commands**: `git ls-files --error-unmatch .claude/settings.json` (TRACKED — run this
  unconditionally; an uncommitted file shows no ignore output and reaches nobody) and
  `git check-ignore -v .claude/settings.json`.

## 3. DevStride connection (`devstride`)

- **A server exists and is CONNECTED** — `claude mcp list`. The bundled one appears as
  `plugin:devstride:devstride`; a plain `devstride` entry is one you or your project configured.
- **Not connected → the big one.** Say explicitly: *until you sign in, the skills have no DevStride
  tools at all, and nothing will prompt you — the symptom is missing tools, not an authorization
  error.* Fix: run `/mcp` and connect (browser sign-in).
- **More than one connected** — flag it, with the right reason: the two servers expose the
  same tools under **different namespaces** (`mcp__devstride__*` vs
  `mcp__plugin_devstride_devstride__*`) and nothing pins which one a call uses, so it can land
  in either organization. **The fix depends on the auth**: `claude mcp logout <name>` clears
  OAuth only — a no-op against API-key headers; those need `claude mcp remove <name>` (check
  with `claude mcp get <name>`).
- **Do not call a DevStride tool to test this.** Presence and connection state are enough; a write
  would violate the read-only contract.

## 4. Config file (`config`)

- **Present and parses** — read `.claude/ds-config.json`. Absent is legal, not an error: every key
  has a shipped default. Say which defaults are therefore in force — but do not call the repository
  ready until those effective branch names have been checked against `origin` below.
- **Branch roles resolve on the connected repository.** Run the minimal read-only repository-root
  and `origin` probes even when the user invoked `/devstride:doctor config` by itself; do not require
  them to run the whole environment section first. Enumerate the actual remote heads with
  `git ls-remote --heads origin` (read-only; never `fetch`). If the network check cannot run, fall
  back to normalized local and
  `refs/remotes/origin/*` names, label that evidence possibly stale, and do not turn an unconfirmed
  branch into a PASS.

  Resolve all four effective values, including inline fallbacks when their keys are absent:

  | Role | Config key | Inline fallback |
  |---|---|---|
  | normal work base | `baseBranch` | `develop` |
  | release source | `release.releaseSource` | `develop` |
  | production | `release.productionBranch` | `master` |
  | hotfix base | `hotfixBaseBranch` | `master` |

  Check each effective value exists on `origin`, and that `protectedBranches` contains the
  effective base, release source and production branches. **Explicit configured names win even
  when unconventional** — heuristics never overwrite or warn against a valid explicit choice.
  When an ABSENT key falls back to a branch that does not exist, apply setup's exact-name
  candidate vocabulary to the enumerated heads (production-role: `main`, `master`,
  `production`, `prod`; development-role: `develop`, `development`, `staging`, `stage`,
  `canary`, `test`, `testing`, `qa`; `trunk` a possible single trunk; whole names only).

  - Exactly one development candidate and one production candidate → print the concrete suggested
    four-key mapping, with base/release source on the former and production/hotfix on the latter.
  - More than one candidate for either role → list the matches and say the role is ambiguous. Never
    pick the first list entry.
  - One production candidate or `trunk` plus only topic branches → suggest the single-trunk mapping
    for all four roles, but say it needs confirmation.
  - One development candidate with no production candidate → suggest only the base and release
    source; never promote staging, canary, test or QA to production by name alone.

  Any nonexistent effective branch is a FAIL: feature checkout, hotfix creation or release will
  target a ref that is not there. For an absent-key fallback, include the candidate mapping above.
  For an explicit configured name, identify the invalid key but do not silently replace the user's
  choice with a heuristic. Fix: run `/devstride:setup` to confirm and write detected roles, or edit
  the four keys explicitly and re-run `/devstride:doctor config`. Doctor remains read-only — it
  prints suggested JSON but never writes it. If the shipped fallback refs do exist, PASS and report
  them; a user can still run setup to make the roles explicit.
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
  **not** by grepping skill prose — several real keys are descriptive and appear in no skill, so a
  prose grep flags valid configuration as misspelled and buries the one genuine typo in the noise.
  Where a key is one edit away from a real one, offer that as a possibility, not a verdict.
  `profile` and `profileOverrides` are recognized keys — they belong to the delivery-profile
  contract — whether or not the published reference lists them yet.
- **`localEnvironment`** — report the block. Absent → the shipped default is in force (every
  command `null`, `instanceBoundTo: none`): `branch-hotfix` asks before touching a database.
  Present → report `instanceBoundTo` and each command's resolution per the rule below.
  WARNINGS: `instanceBoundTo: directory` with a `null` `create` (claims isolated instances,
  gives no way to make one); and under `directory`, a null **or absent** `recreate` beside a
  non-null `migrate` (those commands go forward — `branch-hotfix` then has no backward path
  and will migrate forward only where safe, else STOP and ask; a gap in the unattended loop,
  not a guaranteed wrong schema; reasoning in `config-defaults.md`). **Never warn under
  `branch` binding** — no backward transition happens there.
- **Commands resolve** — for each configured command (`verify.*` — note `verify.typecheck` is an
  **array**, so iterate it — `review.localCommand`, `generated.regenCommand`,
  `preShipChecks[].command`, and each non-null `localEnvironment.*` command): split on `&&` and `;`, take the first token of **each** segment, and
  skip shell builtins. Checking only the very first token is vacuous for the commonest shape:
  `cd backend && pnpm test` starts with `cd`, which always resolves, so the check would pass on a
  machine with no `pnpm` at all. A single-word command that does not resolve may be a shell alias or
  function rather than a real gap — report "not on PATH (may be an alias)" rather than a flat FAIL.
- **`conventionsDoc` exists** — if set, the file must be present; the build engine reads it to write
  code in this repo's style, and a missing one quietly costs you that.

## 5. The CI draft gate (`ci`)

**Applicability comes from all three draft-hold flags** — `review.openPullRequestsAsDraft`,
`readyForReviewReleasesCi`, `ciHeldUntilReviewSettled`. All false is a CI-runs-on-draft repo: N/A.
**Mixed values are not N/A** — `review` and `pr` fall back to the strictest configured behaviour, so
a pull request may still open as a draft; audit the gate and report the mixed configuration.

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
- **So in that mode, the profile's story gate must be runnable.** WHICH commands that needs is the
  effective profile's `storyVerify` (§4 resolved the profile; the contract is
  `${CLAUDE_PLUGIN_ROOT}/skills/plan/references/delivery-profiles.md`): under `prototype`,
  `verify.typecheck` plus `verify.testSingle` — `verify.test` is not required, because that gate is
  type-checks and the touched suites, and `setup` deliberately enables fast merges on exactly that
  shape; under `standard` and `enterprise`, `verify.test` and `verify.typecheck` both. Requiring
  the wider pair under `prototype` would FAIL the very config `setup` just wrote. If a required
  command is missing, say plainly: *code merges to the integration branch with nothing locally
  checking it* — and name the commands THAT profile needs.
- **Give the fix that matches their config**: check `integrationBranch` FIRST — an explicit
  value takes precedence over `epicIntegrationBranches.enabled` entirely, so with one set,
  flipping the flag changes nothing. Say which case applies: set the verify commands, or clear
  `integrationBranch` **and** disable epic branches.
- **Review roster** — report which engines are configured (`review.localCommand`,
  `review.automatedReviewers`). An empty roster is legal and means the built-in adversarial pass is
  the only review; say so rather than implying breakage. A `localCommand` with neither placeholder is the
  pre-placeholder shape — say so (` --base <value>` is appended); `<context>` WITHOUT `<base>` is a
  config error.
- **`preShipChecks`** — if any entry exists, confirm its command resolves (same segment-splitting as
  §4); these run at the ship boundary and nothing in CI covers them.

## 7. Documentation hooks (`docs`)

The plugin never edits documentation itself; it invokes local skills named in `docs.updateSkill` and
`docs.releaseNotesSkill` (contract: `${CLAUDE_PLUGIN_ROOT}/skills/release/references/docs-hooks.md`).
A repository with neither set has no documentation system registered — report that as **N/A**, not
as a failure, and say what it means: the release skill's docs pass reports itself skipped, and
`--release-notes` reports itself unavailable.

- **Each named skill exists** — `.claude/skills/<name>/SKILL.md`; missing → FAIL (a dangling
  hook; fix `/devstride:setup docs`). Also `git check-ignore` the path — a skill on one machine
  only is the commonest fresh-clone failure.
- **Each skill's `check` mode passes** — invoke it with `check` (read-only by contract); relay
  its verdict and fix verbatim. No `check` mode → FAIL naming the template to rebuild from.
- **A legacy `release.docsRepo` block**, with or without a `docs` block beside it → FAIL: the
  release skill never acts on it. Fix: `/devstride:setup docs` (migrates and removes it).
- **`release.deployVerification`** — if set, its first token resolves (§4's rule); never run
  it. Unset → say the release skill will ask the owner to confirm the deploy — legitimate, not
  a gap.
- **Say the release-notes default** — notes only on `--release-notes`; nothing in the loop
  decides a release "deserves" one.

## Closing

Print the verdict, then — if anything failed — the fixes in the order they should be applied,
separating commands from manual edits. Someone should get from a failing report to a working setup
without rereading the explanations.

IMPORTANT:
- **Never emit a command you have not confirmed exists.** Check flags with `--help` first. A
  confidently wrong command is worse than no suggestion, because it will be trusted and it wastes
  the run it was meant to save.
- **Never "fix" anything** — see the note at the top. Print, do not run.
