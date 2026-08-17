---
name: doctor
description: Check that this repo and machine are set up correctly for the delivery loop — git, gh, the plugin, the DevStride connection, the config file, the CI draft gate and the merge gates — and report exactly what is missing and the command that fixes it. Read-only.
---

Diagnose whether the delivery loop will actually work here, and say precisely what to fix if it will
not. Run it after installing, after changing `.claude/ds-config.json`, or any time the loop behaves
in a way you did not expect.

**This skill is READ-ONLY.** It runs inspection commands and reads files. It never installs
anything, never writes config, never edits a workflow, never touches git, and never calls a
DevStride write tool. That is what makes it safe as the first thing anyone runs.

Optional argument — a section name (`env`, `plugin`, `devstride`, `config`, `ci`, `gates`) to check
just one: $ARGUMENTS

## Why this skill exists

**Every prerequisite of this loop fails silently.** Not one of them announces its own absence — each
produces a confusing downstream symptom instead of an error, usually much later, usually mid-run:

| What is wrong | What you actually see |
|---|---|
| `gh` missing or not logged in | The loop gets as far as opening a pull request, then fails |
| Signed out of DevStride | "I can't find any DevStride tools" — no prompt, no auth error |
| A typo in `ds-config.json` | Nothing. The key reads as absent and the skill improvises |
| Workflows not gated on draft | CI runs on open and again after every fix — the run-once design just never engages |
| `verify.test` unset with fast merges on | Items merge with **no mechanical gate at all** |

So the value here is not the checks themselves — it is turning silence into a sentence.

## How to report

Walk every section, even after a failure. Someone with three problems should learn all three in one
run, not discover them one restart at a time.

For each check emit one line: **PASS**, **FAIL**, or **N/A** (with the reason it does not apply).
Then, for every FAIL, three things — never a bare cross:

1. **What is wrong**, concretely.
2. **What it breaks** — the symptom they would otherwise be debugging.
3. **The exact command or edit that fixes it.**

Finish with a one-line verdict: ready, ready-with-warnings (naming them), or not-ready (naming the
blocking failures). If a check cannot be run at all, say so and why — never report an unrun check as
a pass.

## 1. Environment (`env`)

- **git** — `git --version`, and confirm the working directory is inside a repo
  (`git rev-parse --is-inside-work-tree`). Not a repo → everything downstream is N/A; say that and
  stop the section.
- **A remote** — `git remote -v`. No remote means nothing can be pushed or reviewed.
- **gh present** — `gh --version`. Missing → the entire delivery half is unavailable: no pull
  requests, no review threads, no ready-flip. Fix: install GitHub CLI (`brew install gh` on macOS,
  or see cli.github.com).
- **gh authenticated** — `gh auth status`. This is the one people miss, because an *installed* `gh`
  looks like a working `gh`. Fix: `gh auth login`.
- **gh has enough scope** — the delivery skills do more than read: they open pull requests, reply to
  and resolve review threads, and mark pull requests ready. `gh auth status` prints the token
  scopes; `repo` and `read:org` are the working minimum, and a repo whose workflows the loop edits
  also needs `workflow`. Fix: `gh auth refresh -s repo,read:org`.
- **Forge** — if the remote is not GitHub, say plainly that the delivery half assumes GitHub and
  GitHub Actions and has no adapter for other forges. The planning half still works.

## 2. Plugin install (`plugin`)

- **Installed and enabled** — `claude plugin list`. Report the installed version.
- **Marketplace registered** — `claude plugin marketplace list`.
- **Version currency** — compare the installed version against the newest published release. Read it
  from the repo's **tags**, not its releases — this project tags every release but does not create
  GitHub Release objects, so a `releases` query returns empty and would read as "up to date":
  ```bash
  git ls-remote --tags https://github.com/devstride/claude-plugin \
    | awk '{print $2}' | sed 's|refs/tags/||' | grep -v '\^{}' | sort -V | tail -1
  ```
  Behind → **updating is two commands, and one alone silently does nothing**:
  ```bash
  claude plugin marketplace update devstride
  claude plugin update devstride@devstride
  ```
  then restart. Note that the update command needs the fully-qualified `devstride@devstride`, and
  acts on the `user` scope unless given a matching `--scope`.
- **Repo-level declaration** — if the repo has `.claude/settings.json` with `extraKnownMarketplaces`
  / `enabledPlugins`, say what it does and what it does **not**: it registers and enables, it does
  **not install**. Every teammate still runs `claude plugin install devstride@devstride` once. If
  the repo's `.gitignore` excludes `.claude/`, check the settings file is actually committed
  (`git check-ignore -v .claude/settings.json`) — an ignored settings file silently reaches nobody.

## 3. DevStride connection (`devstride`)

- **A server exists and is CONNECTED** — `claude mcp list`, looking for a DevStride entry. The
  bundled one appears as `plugin:devstride:devstride`; a plain `devstride` entry is one the user or
  project configured.
- **Not connected → this is the big one.** Say explicitly: *until you sign in, the skills have no
  DevStride tools at all, and nothing will prompt you — the symptom is missing tools, not an
  authorization error.* Fix: run `/mcp` and connect, which opens a browser sign-in.
- **More than one connected** — flag it. Two authenticated DevStride servers expose identically
  named tools and the skills call tools by bare name, so they cannot tell them apart; that is how
  work meant for one organization lands in another. Fix: keep exactly one signed in
  (`claude mcp logout <name>` for the other).
- **Do not call a DevStride tool to test this.** Presence and connection state are enough, and a
  write would violate this skill's read-only contract.

## 4. Config file (`config`)

- **Present and parses** — read `.claude/ds-config.json`. Absent is legal, not an error: every key
  has a shipped default. Say which defaults are therefore in force, and that the loop will run but
  will not know this repo's commands.
- **Every key it contains is one the skills read** — this is the check that catches typos, and it is
  the whole reason this section exists. An unrecognized key is almost always a misspelling of a real
  one, and it fails *silently*: nothing errors, the real key reads as absent, and the skill
  improvises. Compare against the keys under `${CLAUDE_PLUGIN_ROOT}/skills/` and name any that
  match nothing, with the nearest real key as the likely intent.
- **Commands resolve** — for each configured command (`verify.*`, `review.localCommand`,
  `generated.regenCommand`, `preShipChecks[].command`), check the first token exists
  (`command -v`). A command that is not installed fails at the worst moment.
- **`conventionsDoc` exists** — if set, the file must be present; the build engine reads it to write
  code in this repo's style, and a missing one quietly costs you that.

## 5. The CI draft gate (`ci`)

Only applies when `review.openPullRequestsAsDraft` is true (the default). N/A otherwise — say so.

The loop opens pull requests as drafts so review settles before CI spends anything, then marks them
ready to release CI once. **That only works if this repo's own workflow jobs are gated on the draft
condition** — and nothing outside this check will ever tell you they are not.

- Read the workflow files (`ci.workflowGlobs`, default `.github/workflows/*.y*ml`) and report which
  pull-request-triggered jobs lack a draft condition such as
  `if: github.event.pull_request.draft == false`.
- Ungated jobs → CI fires on open and again on every review-fix push. Nothing errors; you simply pay
  for CI repeatedly and lose the run-once guarantee. Fix: add that `if:` to each pull-request job.
- **`ci.gateJobName`** — if set, confirm a job of that name exists; the loop uses it to prove the
  flip actually released CI. If unset, note that the loop falls back to detecting a new workflow run.

## 6. Merge gates (`gates`)

The point of this section: **find out whether anything actually checks the code before it merges.**

- **Fast merges** — when the working base is an integration branch and
  `epicIntegrationBranches.fastStoryMerges.enabled` is on (the default), an item has **no pull
  request and no CI**. Its local suites are then its *only* mechanical gate.
- So in that mode, **`verify.test` and `verify.typecheck` must be set.** If either is missing, say
  plainly: *code will merge to your integration branch with nothing mechanically checking it.* Fix:
  set them, or set `epicIntegrationBranches.enabled: false` to get a pull request per item instead.
- **Review roster** — report which engines are configured (`review.localCommand`,
  `review.automatedReviewers`). An empty roster is legal and means the built-in adversarial pass is
  the only review; say so rather than implying breakage.
- **`preShipChecks`** — if any entry exists, confirm its command resolves, since these run at the
  ship boundary and nothing in CI covers them.

## Closing

Print the verdict, then — if anything failed — the fix commands as a single copy-pasteable block in
the order they should be run. Someone should be able to go from a failing report to a working setup
without reading the explanations again.

IMPORTANT:
- **Never emit a command you have not confirmed exists.** Check flags with `--help` before printing
  a fix. A confidently-wrong command is worse than no suggestion, because it will be trusted.
- **Never "fix" anything.** If a fix is obvious and safe, still only print it. Users run this to
  understand their setup, and a skill that quietly mutated their config or workflows could not be
  recommended as the safe first step.
