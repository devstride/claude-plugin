---
name: doctor
description: Check that this repo and machine are set up correctly for the delivery loop — git, gh, the plugin, the DevStride connection, the config file, the CI draft gate and the merge gates — and report exactly what is missing and the command that fixes it. Read-only.
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

Optional argument — a section name (`env`, `plugin`, `devstride`, `config`, `ci`, `gates`) to check
just one: $ARGUMENTS

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
- **Version currency** — read the newest published release from the repo's **tags**, not its
  releases: this project tags every release but does not create GitHub Release objects, so a
  `releases` query returns empty and would read as "up to date".
  ```bash
  git ls-remote --tags https://github.com/devstride/claude-plugin \
    | awk '{print $2}' | sed 's|refs/tags/||' | grep -v '\^{}' | sed 's/.*--v//' \
    | sort -V | tail -1
  ```
  **Strip the `devstride--v` prefix before comparing** — the tag is `devstride--v0.6.0` while
  `claude plugin list` prints `0.6.0`, and comparing the two shapes reports every up-to-date install
  as behind. Behind → **updating is two commands, and one alone silently does nothing**:
  ```bash
  claude plugin marketplace update devstride
  claude plugin update devstride@devstride
  ```
  then restart. The update command needs the fully-qualified `devstride@devstride` and acts on the
  `user` scope unless given a matching `--scope`.
- **Repo-level declaration** — if `.claude/settings.json` declares the marketplace and plugin, say
  what that does and does **not** do: it registers and enables, it does **not install**. Every
  teammate still runs `claude plugin install devstride@devstride` once.
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
  has a shipped default. Say which defaults are therefore in force.
- **Unrecognized keys — report as a WARNING, not a typo accusation.** List keys you do not
  recognize and let the user judge. **Exclude by convention**: any key whose leaf name starts with
  `_` (the `_*_readme` documentation convention, used pervasively in real configs) and `$schema`.
  Check against the published [configuration reference](https://docs.devstride.com/developer-experience/agentic-skills/configuration-reference),
  **not** by grepping skill prose — several real keys are descriptive and appear in no skill, so a
  prose grep flags valid configuration as misspelled and buries the one genuine typo in the noise.
  Where a key is one edit away from a real one, offer that as a possibility, not a verdict.
- **Commands resolve** — for each configured command (`verify.*` — note `verify.typecheck` is an
  **array**, so iterate it — `review.localCommand`, `generated.regenCommand`,
  `preShipChecks[].command`): split on `&&` and `;`, take the first token of **each** segment, and
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
exempt it, and do not advise gating it.

Two separate checks, and **the first is the one everyone misses**:

- **`ready_for_review` must be in `on.pull_request.types`.** GitHub's default types are
  `[opened, synchronize, reopened]` — **`ready_for_review` is not among them.** So a workflow with a
  perfect draft `if:` and default types creates **no workflow run at all** when the loop marks a
  pull request ready: the condition is never even evaluated. The loop then waits for a run that will
  never exist. FAIL with: add `ready_for_review` to `on.pull_request.types`.
- **Jobs gated on the draft condition** — match against `ci.draftGateCondition` (the config names
  the expression; default `github.event.pull_request.draft == false`) and accept equivalent forms
  such as `if: ${{ !github.event.pull_request.draft }}`. **A job is also gated if every job in its
  `needs` closure is** — real workflows gate one cheap job and fan the result out, and a skipped
  dependency skips its dependents, so flagging those is a false FAIL on a correctly-gated repo.
  Ungated → CI fires on open and again on every review-fix push; nothing errors, you simply pay
  repeatedly and lose the run-once guarantee.
- **`ci.gateJobName`** — if set, confirm a job with that **display name** (`name:`) or key exists;
  the loop uses it to prove the flip released CI. Unset → note the fallback to detecting a new run.

## 6. Merge gates (`gates`)

The point: **find out whether anything actually checks the code before it merges.**

- **When fast merges apply.** They apply when the resolved working base is an **epic integration
  branch** and `epicIntegrationBranches.fastStoryMerges.enabled` is on (the default). Such an item
  gets no pull request and no CI of its own, so its local suites are the only gate *it* receives —
  the cloud engines and CI are deferred to the release pull request, not removed.
- **So in that mode, `verify.test` and `verify.typecheck` must be set.** If either is missing, say
  plainly: *code merges to the integration branch with nothing locally checking it.*
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

## Closing

Print the verdict, then — if anything failed — the fixes in the order they should be applied,
separating commands from manual edits. Someone should get from a failing report to a working setup
without rereading the explanations.

IMPORTANT:
- **Never emit a command you have not confirmed exists.** Check flags with `--help` first. A
  confidently wrong command is worse than no suggestion, because it will be trusted and it wastes
  the run it was meant to save.
- **Never "fix" anything** — see the note at the top. Print, do not run.
