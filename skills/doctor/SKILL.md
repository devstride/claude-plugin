---
name: doctor
description: Check that this repo and machine are set up correctly for the delivery loop — git, gh, the plugin, the DevStride connection, the config file, the CI draft gate and CI cost mechanics, the merge gates and the documentation hooks — and report exactly what is missing and the command that fixes it. Read-only.
---

Diagnose whether the delivery loop will actually work here, and say precisely what to fix if it will
not. Run it after installing, after changing `.claude/ds-config.json`, or any time the loop behaves
in a way you did not expect.

**This skill is READ-ONLY.** It runs inspection commands and reads files. It never *mutates* git
state — no commit, checkout, fetch-that-writes, push, branch or config change — never installs or
updates anything, never edits a workflow, and never calls a DevStride write tool.

> **Every "Fix:" below is text to PRINT, not a command to run.** You are diagnosing. Even when a fix
> looks safe and obvious, report it and stop. Being helpful here means telling the user what is
> wrong; running the repair is what makes this skill unsafe to recommend as the first thing anyone
> tries.

Optional argument — a section name (`env`, `plugin`, `devstride`, `config`, `ci`, `gates`, `docs`) to
check just one: $ARGUMENTS

## Why this skill exists

**Every prerequisite of this loop fails silently.** Not one announces its own absence — each
produces a confusing downstream symptom instead of an error, usually much later:

| What is wrong | What you actually see |
|---|---|
| `gh` missing or not logged in | The loop gets as far as opening a pull request, then fails |
| Signed out of DevStride | "I can't find any DevStride tools" — no prompt, no auth error |
| A typo in `ds-config.json` | Nothing. The key reads as absent and the skill improvises |
| Workflows missing `ready_for_review` | The ready-flip creates **no run at all**; the loop waits forever |
| Workflow jobs not gated on draft | CI runs on open and again after every fix — the run-once design never engages |
| `verify.test` unset with fast merges on | Items merge with no LOCAL gate — and under fast mode the local suites are the only gate the item itself gets |
| `profile: prototype` beside a hand-set `autoRelease: false` | The loop stops at release-ready and the profile looks ignored. It is not — the explicit key wins, and nothing says so |

The value is not the checks. It is turning silence into a sentence.

## How to report

Walk every section, even after a failure. Someone with three problems should learn all three in one
run, not one restart at a time.

Each check emits **PASS**, **FAIL**, or **N/A** (with the reason). Every FAIL carries three things —
never a bare cross:

1. **What is wrong**, concretely.
2. **What it breaks** — the symptom they would otherwise be debugging.
3. **The exact command or edit that fixes it.** If a check genuinely has no command fix, say what to
   change and where; never leave a FAIL without a next action.

Finish with a verdict: ready, ready-with-warnings (naming them), or not-ready (naming the blockers).
If a check could not be run, say so — never report an unrun check as a pass.

## 1. Environment (`env`)

- **git** — `git --version`; confirm you are inside a repo (`git rev-parse --is-inside-work-tree`).
  Not a repo → the rest is N/A; say so and stop the section.
- **An `origin` remote** — `git remote get-url origin`. Check `origin` **by name**: the delivery
  skills hardcode it (`git push -u origin`, `git fetch origin`, `git ls-remote --heads origin`), so a
  fork checkout whose remotes are `upstream`/`fork` passes a generic "has a remote" test and then
  fails at the loop's first push. If other remotes exist but `origin` does not, say which.
- **gh present** — `gh --version`. Missing → the whole delivery half is unavailable: no pull
  requests, no review threads, no ready-flip. Fix: install GitHub CLI (`brew install gh`, or
  cli.github.com).
- **gh authenticated** — `gh auth status`. The one people miss, because an *installed* `gh` looks
  like a working one. Fix: `gh auth login`.
- **gh scopes, for the ACTIVE account** — `gh auth status` may list several accounts with different
  scopes; read the one marked active. `repo` and `read:org` are the working minimum, plus `workflow`
  if the loop will edit workflow files. Fix: `gh auth refresh -s repo,read:org` — **and include
  `workflow` in that same list when that is the missing scope** (`-s repo,read:org,workflow`), since
  a user who runs the shorter form stays broken in exactly the way you just described. `refresh`
  adds scopes and keeps existing ones.
  **If auth comes from `GH_TOKEN`/`GITHUB_TOKEN`**, say so: `gh auth refresh` cannot refresh an
  environment token. The fix there is to unset the variable or reissue the token with the scopes.
- **Forge** — if `origin`'s URL is not GitHub, say plainly that the delivery half assumes GitHub and
  GitHub Actions and has no adapter for other forges. The planning half still works.

## 2. Plugin install (`plugin`)

- **Installed and enabled** — `claude plugin list` (prefer `--json` if parsing). Report the version.
- **`claude plugin list` reads DISK, not this session.** A session serves whatever it loaded at
  startup, so the two can disagree: a just-installed plugin will not be active until a restart, and
  a just-removed one may still be running. Say which you are reporting, and never tell someone whose
  loop is visibly working that the plugin "is not installed" without that caveat.
- **Marketplace registered** — `claude plugin marketplace list`. Absent → the plugin cannot update.
  Fix: `claude plugin marketplace add devstride/claude-plugin`.
- **Version currency** — the recipe is `${CLAUDE_PLUGIN_ROOT}/skills/doctor/references/version-currency.md`
  (tags not Releases; strip the `devstride--v` prefix; `sort -V`; the installed id and scope from
  `claude plugin list --json`, never assumed; both update commands, then restart). Run it and
  report installed vs newest. Behind → print the two commands with the id and scope you read.
- **Learned reviewer latency** — read `${XDG_CACHE_HOME:-~/.cache}/devstride-plugin/reviewer-latency.json` and report
  per reviewer id: samples, p50, p95, and the bound `review` derives under this repository's
  `pollTimeoutMinutes` — or "cold — the wait uses `pollTimeoutMinutes`" below the script's sample minimum.
  Informational, never a FAIL; the schema and the doctor line's format are in
  `${CLAUDE_PLUGIN_ROOT}/skills/review/references/reviewer-latency.md`.
- **Session-start check** — read the per-repository record
  `${XDG_CACHE_HOME:-~/.cache}/devstride-plugin/repo-<sha1 of the repo root, first 12 hex>.json`
  (schema in the same reference; compute the key from `git rev-parse --show-toplevel`) and report `checkedAt`, `running`, `newest`, `mode` and
  `result` as one line. Absent → the check has never run here: say so, and say why it might be
  (plugin older than 1.2.0, hooks disabled, or `DEVSTRIDE_PLUGIN_UPDATE_CHECK=0`). `mode` comes
  from the repository's `plugin` config block — `notify` is the default; `auto-update` applies
  releases at session start and asks for a restart; `pinned` reports and never nags. A
  `result` of `unreachable` on the last run is informational, not a FAIL: the check stays
  silent offline by design and records it here instead.
- **Repo-level declaration** — if `.claude/settings.json` declares the marketplace and plugin, say
  what that does and does **not** do: it registers and enables, it does **not install**. Every
  teammate still runs `claude plugin install <id>` once — and **build that id from the
  `enabledPlugins` key you just read**, rather than printing a literal. A repository may enable
  either marketplace entry, and telling someone to install `devstride@devstride` when their
  repository declares `ds@devstride` leaves them with a plugin that does not match what the project
  enabled.
  **Then check the file actually reaches them — two different questions, two commands.**
  `git ls-files --error-unmatch .claude/settings.json` proves it is TRACKED; `git check-ignore -v
  .claude/settings.json` shows whether an ignore rule matches. Run the trackedness check
  *unconditionally*: a file that is unignored but simply never committed produces no ignore output
  and would otherwise be reported as shared while reaching nobody.

## 3. DevStride connection (`devstride`)

- **A server exists and is CONNECTED** — `claude mcp list`. The bundled one appears as
  `plugin:devstride:devstride`; a plain `devstride` entry is one you or your project configured.
- **Not connected → the big one.** Say explicitly: *until you sign in, the skills have no DevStride
  tools at all, and nothing will prompt you — the symptom is missing tools, not an authorization
  error.* Fix: run `/mcp` and connect (browser sign-in).
- **More than one connected** — flag it, and give the right reason. The two servers expose the same
  tool set under **different namespaces** (`mcp__devstride__*` vs
  `mcp__plugin_devstride_devstride__*`), and nothing in the skills pins which namespace to use — so
  a call can land in either organization. Do not say the tools are identically named; they are
  namespaced, and the reason is what a reader will repeat.
  **The fix depends on how the server authenticates.** `claude mcp logout <name>` clears stored
  **OAuth** credentials only — it is a no-op against a server authenticated by API-key headers,
  which stays connected and keeps serving tools. For those, the fix is `claude mcp remove <name>`,
  or removing the entry from whichever config declares it. Check with `claude mcp get <name>`.
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

  Check that each effective value exists on `origin`, and that `protectedBranches` contains the
  effective base, release source and production branches. Explicit configured names win even when
  they are unconventional; naming heuristics must never overwrite or warn against a valid explicit
  choice.

  When an absent key falls back to a branch that does not exist, apply setup's exact-name candidate
  vocabulary to the enumerated remote heads: production-role candidates are `main`, `master`,
  `production`, `prod`; pre-production development-role candidates are `develop`, `development`,
  `staging`, `stage`, `canary`, `test`, `testing`, `qa`; `trunk` is a possible single-trunk branch.
  Match whole names only — `production-fix` is not `production`, and `contest` is not `test`.

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
  `verify.typecheck` is set — the other two profiles decide that key per repository, so `false`
  under them is a decision, not a contradiction. A present key that differs is **informational, not a FAIL**: the explicit key
  wins, by contract. But say which key, which value, and what the profile would have written —
  `profile prototype, but autoRelease is false in config — the loop stops at release-ready as
  configured` — because someone who chose `prototype` for its speed and meets a release-ready stop
  otherwise debugs the wrong thing. A present `review.localCommand` under `prototype` is **not** a
  contradiction and must not be reported as one: the contract says it names the engine without
  scheduling it — that engine still reviews release and pull-request paths, and simply gets no
  rounds on fast-mode stories. `profileOverrides`, when present, is the operator pinning
  knobs on purpose: report as a WARNING any name in it that is not a knob in the contract's table
  (the skills ignore unknown names rather than honouring them as something else), and nothing
  else about it.
- **Unrecognized keys — report as a WARNING, not a typo accusation.** List keys you do not
  recognize and let the user judge. **Exclude by convention**: any key whose leaf name starts with
  `_` (the `_*_readme` documentation convention, used pervasively in real configs) and `$schema`.
  Check against the published [configuration reference](https://docs.devstride.com/developer-experience/agentic-skills/configuration-reference),
  **not** by grepping skill prose — several real keys are descriptive and appear in no skill, so a
  prose grep flags valid configuration as misspelled and buries the one genuine typo in the noise.
  Where a key is one edit away from a real one, offer that as a possibility, not a verdict.
  `profile` and `profileOverrides` are recognized keys — they belong to the delivery-profile
  contract — whether or not the published reference lists them yet.
- **`localEnvironment`** — report the block. Absent means the shipped default is in force: every
  command `null`, `instanceBoundTo: none` — so `branch-hotfix` will ask before touching a database
  and `build-item` treats the current checkout as the only environment. Present: report
  `instanceBoundTo` and each command's resolution per the rule below. `instanceBoundTo: directory`
  with a `null` `create` is a WARNING — it claims isolated instances exist and gives the loop no
  way to make one. Under `instanceBoundTo: directory`, a `recreate` that is null **or absent** —
  every config written before the key existed omits it — alongside a non-null `migrate` is also a
  WARNING: those commands go forward,
  so `branch-hotfix` has no command that brings an instance BACK to a production base. It will
  then either migrate forward (only where the schema is known not to have diverged) or STOP and
  ask, so this is a gap in what the loop can do unattended, not a guaranteed wrong schema. Name
  the config key; the reasoning is in `config-defaults.md` under Local environment. **Do not warn
  under `branch` binding** — there the hotfix branch selects its own instance, so no backward
  transition happens and the gap does not arise.
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

- **`on.pull_request.types` must carry all four events the loop depends on** — `opened`,
  `synchronize`, `reopened`, `ready_for_review` — and each covers a different way a run gets
  created. GitHub's defaults are the first three, so **`ready_for_review` is not among them**: a
  workflow with a perfect draft `if:` and no `types` list creates **no workflow run at all** when
  the loop marks a pull request ready. The condition is never even evaluated, and the loop waits for
  a run that will never exist.
  **Declaring `types` explicitly REPLACES the defaults rather than adding to them**, which is the
  second half of the trap: a list naming only `ready_for_review` fixes the flip and breaks
  everything after it — a fix push starts nothing, and close-and-reopen has no `reopened` to fire on.
  **`opened` looks droppable and is not.** Under the hold the loop's own pull requests open as
  drafts, so that event only ever produces a skipped run *for them* — which is exactly why someone
  eventually deletes it. But `review` also runs standalone on a pull request somebody else opened,
  and on a **non-draft** one it skips the ready-flip entirely and settles against the CI it assumes
  is already running. Without `opened` there is no such run and never will be, so it waits forever.
  FAIL with: declare all four. A fifth, `converted_to_draft`, is optional — with per-pull-request
  `concurrency` on, the run it creates cancels the one a mistaken non-draft open started; suggest it
  when concurrency is present and it is missing.
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
  - on workflows that also run on `push` to the production branch, a tree-identical skip against
    the base branch (a promotion merge has the same tree the base just tested — re-testing it is
    pure cost; one repository measured this at half its test minutes). **Judge it on whether it
    CAN FIRE, not on whether the step exists.** Pattern C is the authority on the condition: the
    merge-promotion path reads `HEAD^2`, so that parent must be in the checkout — any depth of 0
    or 2+, or a deepening fetch in the step (`--deepen`, `--unshallow`; judge the effect, not the
    flag). Without it the skip is *present but inert*: it still fires while the base tip has not
    moved, via the fallback path, and silently stops as soon as it has. Report it at the same
    WARNING level, naming what is missing — it looks like it works, which is why a step-exists
    test calls it done while `ci-audit` shows the minutes unexplained. A step in a job with NO
    checkout is a separate, harsher finding: `git rev-parse` fails and takes the gate job — and
    everything that `needs` it — down on every production push;
  - a draft-convention check that fails a non-draft pull request opened by a person (INFO, not a
    warning — it is a courtesy to humans, not a gate).
  Fix for all three: `/devstride:setup ci`, which shows each change as a diff.
- **Run-once in practice.** Run the last seven days through the `ci-audit` skill's method (executed
  runs per workflow per pull request, post-merge push minutes, release pull requests re-run by a
  moving base) and report the ratio `Σ executed PR runs ÷ Σ distinct workflows that executed per
  pull request` — `1.0` is the design; above it, name the pull requests, workflows, causes. This is the number the whole draft-hold arrangement exists to
  produce, and the only way to know it is to measure it.

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
- **Give the fix that matches their config.** Setting `epicIntegrationBranches.enabled: false` only
  works when the working base is being derived per-epic. **An explicit `integrationBranch` value
  takes precedence over that flag entirely**, so with one set, flipping the flag changes nothing.
  Check `integrationBranch` first and say which case applies: set the verify commands, or clear
  `integrationBranch` **and** disable epic branches.
- **Review roster** — report which engines are configured (`review.localCommand`,
  `review.automatedReviewers`). An empty roster is legal and means the built-in adversarial pass is
  the only review; say so rather than implying breakage.
- **`preShipChecks`** — if any entry exists, confirm its command resolves (same segment-splitting as
  §4); these run at the ship boundary and nothing in CI covers them.

## 7. Documentation hooks (`docs`)

The plugin never edits documentation itself; it invokes local skills named in `docs.updateSkill` and
`docs.releaseNotesSkill` (contract: `${CLAUDE_PLUGIN_ROOT}/skills/release/references/docs-hooks.md`).
A repository with neither set has no documentation system registered — report that as **N/A**, not
as a failure, and say what it means: the release skill's docs pass reports itself skipped, and
`--release-notes` reports itself unavailable.

- **Each named skill exists** — `.claude/skills/<name>/SKILL.md`. Missing → FAIL: the release skill
  will report a dangling hook and run without docs. Fix: `/devstride:setup docs`. Also check the
  path is not gitignored (`git check-ignore`); a skill that exists only on one machine is the
  commonest way this fails on a fresh clone.
- **Each skill's `check` mode passes** — invoke it by name with `check`. It is read-only by contract
  (a checkout present, clean and on its branch; a directory present; a service reachable), so it is
  safe to run from a read-only skill. Relay its verdict and fix verbatim. A skill with no `check`
  mode is a FAIL naming the template to rebuild it from.
- **A legacy `release.docsRepo` block, whether or not a `docs` block exists beside it** → FAIL: the
  release skill never acts on it, so whatever it described is not being updated unless a `docs`
  hook covers the same thing. Fix: `/devstride:setup docs` (it migrates the block into a local
  skill and removes it).
- **`release.deployVerification`** — if set, its first token resolves (same rule as §4). Do not run
  it: it only means something against a real merge commit. If unset, say the release skill will ask
  the owner to confirm the deploy before writing release notes — that is a legitimate configuration,
  not a gap.
- **Say what the release-notes default is**, because it is the part people expect to be the other
  way round: notes are written only when the owner passes `--release-notes`; nothing in the loop
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
