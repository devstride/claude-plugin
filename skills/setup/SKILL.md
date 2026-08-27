---
name: setup
description: Set the delivery loop up for this repository — inspecting it for everything answerable without asking (package manager, verify commands, CI provider and draft gating, branches, review engines), mapping your DevStride work types onto the loop's roles, asking only about what is left, and writing .claude/ds-config.json, which a re-run merges into rather than overwrites.
user-invocable: true
disable-model-invocation: true
---

Set the delivery loop up for **this** repository and **this** DevStride organization, in one guided
session. Run it after installing the plugin, and again whenever the repository changes shape.

Seven phases: inspect what the repository can answer (A), report it (B), map the organization's work
types onto the loop's roles (C), ask only about what is left (D), write the config (E) — or, on a
repository that already has one, merge into it without destroying anything (F) — and then prove the
result by running it (G).

Optional argument: $ARGUMENTS

- **`validate`** — skip straight to Phase G and check the config that is already there. Nothing is
  inspected for a rewrite, nothing is asked, nothing is written. Use it after hand-editing the file,
  or to find out why the loop is behaving oddly. **Run A1 first even so**: Phase G reads the config
  at a repository-relative path and runs commands that assume the repository root, so a validate
  invoked from a subdirectory would otherwise read a file that is not there and run commands in the
  wrong directory.
- **A detector name** — `ecosystem` (A2–A3), `verify` (A4), `ci-inspect` (A5), `branches` (A6),
  `engines` (A7) — to inspect and report just that part. (`ci-inspect`, not `ci`: the bare word
  is the write mode below, and one token must mean one thing.)
- **`docs`** — the documentation-hooks mode, and the one narrowed run that WRITES: run A1 and A8,
  ask Phase D's three documentation questions (plus `release.deployVerification`), then write
  **only** the `docs` block and `release.deployVerification` into the config (creating the file
  with just those keys if none exists; merging per Phase F otherwise, including the legacy
  `release.docsRepo` migration), scaffold the local skills (Phase E2), and run Phase G's
  documentation check (7) alone. Every other key is untouched. This is how a repository
  registers its documentation system after the fact, and how a pre-1.0 config migrates.
- **`ci`** — the CI-cost mode, the second narrowed run that WRITES, and the only mode that touches
  a workflow file: run A1 and A5, detect which of the four mechanics in
  `${CLAUDE_PLUGIN_ROOT}/skills/setup/references/ci-cost-patterns.md` each pull-request workflow
  already carries (the draft gate, per-pull-request `concurrency`, the tree-identical skip on
  production-branch pushes, the human draft-convention check), show the **exact diff** for each
  missing one, and apply only the diffs the user accepts — nothing else in the file is rewritten.
  Then write `ci.freezeBaseWhileReleasePrReady` and `ci.expectedRunsPerPullRequest` if absent.
  **When the draft-gate diffs were accepted and the three `review.*` CI-ordering booleans are
  `false`, propose flipping them `true` as part of the same change** — a gate the workflows now
  carry does nothing while `pr` still opens non-draft and `review` never flips; installing the
  mechanism without enabling the ordering is a run-once setup that runs every time. Then run
  Phase G's CI checks. Offer `/devstride:ci-audit` first when the user wants numbers
  before changing anything.
- **Nothing** — the full run: inspect, ask, write, scaffold, validate.

**Run each one's prerequisites too, silently
— A1 always, and A2–A3 before A4**, which cannot compose a command without knowing the package
manager or find workspace scripts without knowing the layout. A narrowed run reports fewer keys; it
must never report worse ones.

**A narrowed detector run stops after Phase B and writes nothing.** It has only looked at part of
the repository, so it has nothing to say about the rest — and a write would fill every key the
skipped detectors would have answered with a default, silently replacing real settings with
guesses. Say that a full `/devstride:setup` is what writes the file.
**`docs` and `ci` are the exceptions by design**: each writes exactly the keys its own questions answer (and, for `ci`, the accepted
workflow diffs) and nothing else, so neither can replace a setting it never asked about.

**The write boundary — the whole of it.** This skill writes `.claude/ds-config.json`; in
Phase E2 only, the local documentation skills it scaffolds at `.claude/skills/<name>/SKILL.md`,
never overwriting a file that exists; and in the `ci` mode only, the pull-request workflow files
under `ci.workflowGlobs` — each change shown as a diff and applied only on an explicit yes.
Nothing else, ever. Not application code, not `CLAUDE.md`, not permission settings, not a
`.gitignore`, and no workflow edit outside `setup ci`. It never mutates git state — no commit, checkout, branch, fetch, push
or `git config` write — never installs anything, and never calls a DevStride **write** tool; the only
organization calls it makes are reads.

**Phases A through D are strictly read-only**, and nothing is written until every question has been
answered and the result confirmed. Up to that point a run must leave `git status --porcelain`
byte-identical to how it found it. If a detector seems to need a write, it is the wrong detector.

## Why detection comes before questions

Every question the user answers by hand is friction at the worst possible moment — the first ten
minutes with a new tool, before it has done anything for them. Nearly every value in this config is
already sitting in the repository: the lockfile knows the package manager, `package.json` knows the
test command, git knows the branches, `PATH` knows which review engines exist.

So the rule is **detect before you ask**, and its corollary matters just as much: **never guess.**
A wrong detected value is worse than an honest question, because it arrives wearing the authority of
evidence and the user accepts it without reading. Three outcomes, and the third is not a failure:

| Status | Meaning | What happens to it later |
|---|---|---|
| `detected` | One unambiguous answer, with evidence | Becomes a prefilled default |
| `ambiguous` | Several plausible answers, or one that needs confirming | Becomes a question with the candidates offered |
| `unknown` | The repository does not answer this | Becomes a question with no prefill |

Every row carries the evidence that produced it — the file read or the command run. A row without
evidence is a guess with a status attached.

## Ground rules for every detector

- **Anchor to the repository root**, `git rev-parse --show-toplevel`, not the working directory.
  Run from a subdirectory and root-relative detection silently reads the wrong tree — the commonest
  way this produces a confidently wrong answer.
- **Match names exactly; never substring.** A script called `test:watch` is not the test command, and
  `pretest` is not either. Compare full script names against a ranked list of known ones. An
  unanchored match here is invisible: it produces a plausible command that runs the wrong thing.
- **Prefer local, offline evidence.** Some git commands reach the network (`git remote show origin`);
  those are still read-only but they are slow and can block on credentials. Use them only as a
  fallback, and if one stalls, record the key as `ambiguous` with that as its reason rather than
  waiting.
- **A command that is not on `PATH` may still be a shell alias or function**, which a non-interactive
  shell does not load. Report "not on `PATH`" and say so, rather than declaring the tool absent.
- **Say when a check could not be run.** An unrun check is never a pass and never an absence.

## Phase A — inspect

### A1. Repository and remote

- Confirm you are in a git work tree (`git rev-parse --is-inside-work-tree`). If not, stop: there is
  nothing to detect and the delivery half of the loop needs a repository.
- `git remote get-url origin` — check for `origin` **by name**, because the delivery skills hardcode
  it. If other remotes exist but `origin` does not, say which, and mark every branch key `ambiguous`.
- Record the forge host from that URL. **The delivery half assumes GitHub and GitHub Actions**; any
  other host is worth saying plainly here rather than discovering later.

### A2. Ecosystem and package manager

Fingerprint the lockfile at the repository root:

| File | Package manager |
|---|---|
| `pnpm-lock.yaml` | pnpm |
| `yarn.lock` | yarn |
| `package-lock.json` | npm |
| `bun.lock` / `bun.lockb` | bun |

- **Lockfiles for more than one manager → `ambiguous`, listing all of them.** Never silently pick.
  Two lockfiles usually mean a half-finished migration, and picking the loser produces commands that
  fail on every machine but the one that ran them. Two files naming the *same* manager
  (`bun.lock` beside `bun.lockb`) is not ambiguity — the answer is the same either way.
- `package.json` with no lockfile → **read its `packageManager` field before giving up.** Corepack's
  `"packageManager": "pnpm@10.0.0"` is a declaration of exactly what this repository uses, and a
  repository that gitignores its lockfile still has it. Present → `detected`, with the field as the
  evidence. Present *and* contradicting a lockfile → `ambiguous`, showing both; that disagreement is
  worth surfacing rather than resolving. Neither → `unknown`; the interview asks.
- **No `package.json` at all → the non-Node path.** Fingerprint `Cargo.toml`, `go.mod`,
  `pyproject.toml`, `Gemfile`, `Makefile`; record the ecosystem as evidence and mark every `verify.*`
  key `unknown`. The ecosystem is still worth recording even though it prefills nothing — it lets the
  interview ask an ecosystem-shaped question instead of a blank one.

### A3. Workspace layout

A monorepo changes the *shape* of the verify commands, so establish it before A4.

- pnpm: the `packages:` globs in `pnpm-workspace.yaml`.
- npm / yarn / bun: the `workspaces` field in the root `package.json` — it is **either** an array of
  globs **or** an object with a `packages` array. Handle both; assuming the array shape reads a real
  monorepo as a single package.
- Expand the globs and note which workspaces actually define scripts you care about. **Present only
  those.** A repository with forty packages and three that run tests should produce three rows, not
  forty.

### A4. Verify commands

Scan `scripts` in the root `package.json` and — in a monorepo — in each workspace's.

Ranked exact-name matches:

- **typecheck**: `typecheck`, `check:ts`, `check-types`, `type-check`, `tsc`
- **test**: `test`
- **lint**: `lint`

**Then read what the matched script actually does.** A name match is not a working command:
`npm init` writes `"test": "echo \"Error: no test specified\" && exit 1"`, which matches `test`
exactly and fails by design. A script whose body is a bare `echo`, an `exit 1`, or otherwise runs no
tool is a placeholder — record it `unknown` and say why. Reporting it `detected` would hand the user
a value to copy that makes every merge gate fail on first use, which is precisely the class of wrong
answer the status column exists to prevent.

**Compose the command as `<pm> run <script>`, always.** The bare form — `pnpm lint` — works in pnpm,
yarn and bun but **not in npm**, where only a handful of names (`test`, `start`) are built-in verbs
and everything else needs `run`. So `npm lint` and `npm check-types` are not commands, and a
detector that drops `run` emits a config that fails on the first npm repository it meets while
looking perfectly correct in review. `run` is valid in all four, so there is no reason to omit it.
An existing config using the bare form is equivalent, not wrong — do not report it as a difference.

Then compose, remembering the shapes differ:

- **`verify.typecheck` is an array**, so a monorepo naturally produces one entry per workspace —
  `cd <workspace> && <pm> run <script>`. A single-package repo produces a one-element array, not a
  string. Propose **every** workspace that has one; a repository deliberately checking only some of
  them is a choice for the interview, and silently dropping workspaces would hide type errors the
  user believes are covered.
- **`verify.test` and `verify.lint` are single strings.** Several workspaces with test scripts is
  therefore `ambiguous`, not a list: the loop runs one test command and the user has to say whether
  that is a root script that fans out, or one particular workspace. Offer the candidates; do not
  invent a `&&` chain that has never been run.
- **`verify.testDir`** — the directory holding the suites, from the test runner's config
  (`include` / `roots` / `testMatch`) when there is one, otherwise a conventional `tests/`, `test/`
  or `__tests__/` that actually exists.
- **`verify.testSingle`** — only when the runner is recognizable from `devDependencies` or the test
  script. For vitest and jest, `<detected test command> -- <path/to/test.spec.ts>`. An unrecognized runner is
  `unknown`; its single-file syntax is not guessable and a wrong one wastes the loop's tightest inner
  cycle.

### A5. CI provider, and the draft gate

`.github/workflows/*.yml` or `*.yaml` present → **GitHub Actions**, the only provider the draft-hold
mechanics understand.

**A convention-only workflow is exempt.** Its shape is defined once, under pattern D of
`${CLAUDE_PLUGIN_ROOT}/skills/setup/references/ci-cost-patterns.md` (`opened` plus optionally
`converted_to_draft` / `ready_for_review`, one run-only job, fails on a non-draft open); the
`opened`-only shape is a subset. **Remove it from the population BEFORE the five-case table
below is evaluated** — left in, its draft-condition `if` and short `types` list read as an
`ambiguous` row and Phase G calls it a FAIL.

When it is GitHub Actions, look at the workflows themselves before prefilling the three CI-ordering
booleans — and look only at the ones this is about: **workflows with an `on: pull_request` trigger.**
A workflow that fires on push, on a schedule, or on `pull_request_review` is not part of the draft
hold, and judging it as ungated turns a correctly-configured repository into a false finding (`review.openPullRequestsAsDraft`, `review.readyForReviewReleasesCi`,
`review.ciHeldUntilReviewSettled`). Two things have to be true for the hold to work, and **the second
is the one repositories get wrong**:

1. Jobs are gated on the draft condition — `github.event.pull_request.draft == false`, or the
   equivalent `if: ${{ !github.event.pull_request.draft }}`. **A job is also gated when ANY job it
   `needs` is gated** (unless it overrides the default with `if: always()` or similar). GitHub's
   default job condition requires every dependency to *succeed*, so one skipped dependency skips the
   dependent — which is exactly how real workflows are built: one cheap job carries the draft
   condition and the expensive ones hang off it by `needs`. Requiring the *whole* closure to be
   gated is the wrong test and fails those workflows; so is checking only for an explicit `if`.
   Either mistake reads a correctly-gated repository as ungated and then writes all three hold
   booleans `false`, turning a working setup off.
2. **`on.pull_request.types` carries every event the loop depends on.** GitHub's default types are
   `[opened, synchronize, reopened]` and `ready_for_review` is *not* among them. Without it, marking
   a pull request ready creates **no workflow run at all** — the draft condition is never even
   evaluated — and the loop waits for a run that will never exist.
   **So the default is never enough here** — a draft-gated workflow with no `types` list at all fails
   in exactly this way, and it is the commonest shape of the bug precisely because nothing looks
   wrong. **And declaring `types` explicitly replaces the defaults rather than adding to them**, so a list
   naming `ready_for_review` and nothing else is its own trap: a fix push after a red run then
   starts no run either, and the close-and-reopen fallback has no `reopened` to fire on. An explicit
   list needs all four; anything short of that is `ambiguous`, naming which events are missing.
   A fifth, `converted_to_draft`, is optional and worth having once per-pull-request `concurrency`
   is on: the run it creates (every job skips) cancels the run a mistaken non-draft open started.
   **`opened` is the one that looks droppable and is not.** The loop's own pull requests open as
   drafts, so it only ever produces a skipped run for them — but a standalone review on a
   *non-draft* pull request skips the ready-flip and settles against CI it assumes is already
   running, which without `opened` was never created.

Five cases, and **every one of them produces all three rows** — a case that emits nothing leaves the loop on
shipped defaults chosen for somebody else's repository:

| What the pull-request workflows show | The three booleans |
|---|---|
| Draft-gated, **and** an explicit `types` list naming all four of `opened`, `synchronize`, `reopened`, `ready_for_review` | `true`, `detected` |
| Draft-gated, but `types` is absent, or an explicit list is missing any of the four | `ambiguous` — the hold cannot work as written |
| Pull-request workflows exist, none draft-gated | `false`, `detected` — CI runs on open; the run-once design is simply not in use here |
| Some pull-request jobs gated, others not | `ambiguous` — name the ungated jobs |
| GitHub Actions present, but no pull-request workflow at all | `false`, `detected` — nothing to hold |

The mixed row is real and common — a repository part-way through adopting the hold, or one that
deliberately runs a cheap check on drafts. Neither `true` nor `false` is honest there: `true` would
claim a hold that part of CI ignores, `false` would discard the part that works. Name the ungated
jobs and let the user say which they meant.

The second row is the one worth being stubborn about. Prefilling `true` there would configure the
loop to rely on a hold this repository cannot deliver — the ready-flip creates no run, and the loop
waits for it forever. Say what is missing and point at `/devstride:doctor`, which diagnoses this
specific gap. The third row is a legitimate configuration, not a defect: say what it means for cost
(CI on open and again after every fix push) and leave the choice with the user.

**Also record, per pull-request workflow, which of the CI-cost mechanics it carries** (rows
`ci.concurrency`, `ci.productionTreeSkip`, `ci.policyCheck` — informational, they are not config
keys): a top-level `concurrency:` block with `cancel-in-progress: true`; a step comparing
`HEAD^{tree}` against the base branch on a production-branch push; a workflow that fails a
non-draft pull request opened by a person. The patterns and the measurements behind them are in
`${CLAUDE_PLUGIN_ROOT}/skills/setup/references/ci-cost-patterns.md`; `setup ci` is what applies
them. In a full run just report which are missing and say `setup ci` applies them — the full run
never edits a workflow.

Any other provider — `.gitlab-ci.yml`, `.circleci/`, `Jenkinsfile`, `azure-pipelines.yml` — or none
at all: record the provider name and prefill the three booleans `false`, `detected`. That is not a
degraded setup, just a different one; the loop opens ordinary pull requests and never waits on a
draft flip. **Setup attempts nothing provider-specific beyond GitHub Actions.**

### A6. Branches

From git alone — no network unless a local answer is unavailable.

- **Enumerate the branches that exist, then reason about them.** `git branch --format='%(refname:short)'`
  and `git branch -r --format='%(refname:short)'` — read **both**, because a fresh clone commonly has
  exactly one local branch and a local-only list reports a repository as single-branch when it is not.
  **Take only `origin`'s refs, and normalize them**: enumerate `refs/remotes/origin/*`, strip the
  `origin/` prefix, drop the symbolic `origin/HEAD` entry, and deduplicate against the local names.
  Both halves matter. Keeping the prefix writes `origin/develop` as `baseBranch`, which reads
  plausibly and then fails at the loop's first checkout, because git and every GitHub call want the
  branch name. And every delivery operation targets `origin` by name, so a fork checkout's
  `upstream/develop` is not a candidate for any role here — it is somebody else's branch.
- **Remote-tracking refs are a local cache, not the remote.** They go stale: `origin/develop` can
  outlive the branch it names, and a local-only branch has no remote at all. Since the loop's very
  first act is to fetch and pull against `origin`, a role assigned from a stale ref fails
  immediately. Where a role turns on evidence that is only local or only cached, confirm it with
  `git ls-remote --heads origin` — read-only, but a network call, so treat a stall as the ground
  rules say — and if you cannot confirm, mark the key `ambiguous` and say the evidence was a
  possibly-stale cache.
  Enumerating first matters: plenty of repositories name their long-lived branches `production`,
  `trunk`, `release` or `staging`, and probing only for `develop`/`main`/`master` would not merely
  miss them, it would report a four-branch repository as single-branch and hand every role to the one
  name it recognized.
- Default branch: `git symbolic-ref refs/remotes/origin/HEAD`. **This ref is set at clone time and is
  frequently absent**, so treat an error as ordinary, not exceptional; the fallback is
  `git remote show origin`, which is a network call (see the ground rules).
- **Classify only exact, whole branch names** after enumeration; never use substring or prefix
  matches. The common production-role candidates are `main`, `master`, `production`, and `prod`.
  The common pre-production development-role candidates are `develop`, `development`, `staging`,
  `stage`, `canary`, `test`, `testing`, and `qa`. `trunk` is a common single-trunk name, not proof
  of a separate production role. Preserve the repository's actual spelling in the value you propose.
  These lists assign likely roles among branches already proved to exist on `origin`; they are never
  the set of refs to probe for, and a name alone is not proof of what deploys.
- **One exact development candidate plus one exact production candidate is an unambiguous pair.**
  Mark all four role values `detected`: `baseBranch` and `release.releaseSource` use the development
  candidate; `release.productionBranch` and `hotfixBaseBranch` use the production candidate. The
  candidate-list order is NOT a ranking. If two names from either role set exist — for example both
  `main` and `production`, or both `staging` and `canary` — mark the affected roles `ambiguous`, show
  the matches, and ask which branch actually fills each role.
- Treat `origin/HEAD` as supporting evidence for the repository's ordinary pull-request base, not as
  proof of production. GitHub lets any branch be the default, and repositories commonly make either
  their development branch or their production branch the default. Use it to suggest, never to
  override a conflicting exact-name pair or an explicit answer.

**Four branch keys hang off this, not two, and every one of them has a shipped default pointing at a
branch this repository may not have.** Emit all four on every path, or the loop inherits
`develop`/`master` defaults and aims flows at refs that do not exist:

| Key | What it is |
|---|---|
| `baseBranch` | Where work branches from and merges back to |
| `release.releaseSource` | What gets promoted to production — normally the same branch as `baseBranch` |
| `release.productionBranch` | What production deploys from |
| `hotfixBaseBranch` | What an urgent fix branches from, so it carries no unreleased work — normally the production branch |

- One unambiguous development/production pair → use the pair exactly as described above.
- One production-role candidate or `trunk` plus topic branches (the ordinary trunk-based repository,
  where feature or dependency-bot branches happen to be open) → treat it as the single-branch case
  and prefill **all four roles to that long-lived branch**, `ambiguous`, saying so. Topic branches
  are work in flight, never candidates for a role. What must not happen is falling through to
  "several branches, no answer": the roles all have shipped defaults, so an unstated role is not
  neutral — it silently becomes `develop` or `master`.
- One development-role candidate with no production-role candidate → suggest it for `baseBranch`
  and `release.releaseSource`, but keep the production and hotfix roles `ambiguous`. Do not silently
  promote a staging, canary, test, or QA branch to production.
- Multiple candidates in either role set → keep the affected roles `ambiguous`, even if one appears
  earlier in the list. Show the exact matches and ask; the branch name cannot tell you which one
  deploys.
- Branches exist but none carry a conventional name → `ambiguous` on all four, with every enumerated
  branch offered as a candidate and the `origin/HEAD` default named as the likeliest ordinary
  pull-request base. `protectedBranches` should offer the long-lived ones, not just the two you can
  name.
- Only one branch → prefill **all four** to that branch, status `ambiguous` on each. A single-branch
  repository is a legitimate configuration — base, release source, production and hotfix base are
  genuinely the same ref, and hotfixes are then ordinary branches — but so is a repository whose
  second branch simply has not been created yet, and those two want different answers. What is not
  acceptable is leaving two of the four unstated: the defaults would fill them with branch names this
  repository does not have, and the failure surfaces much later, at the first release or hotfix.
- Always compute `protectedBranches` containing the detected base, production **and release-source**
  branches. All three, even when two of them are the same ref. It is what keeps the loop from
  force-pushing or deleting them — and the release source is the one people leave out, because it is
  usually the base branch and so looks already covered. Where it is not, it is the *head* of the
  production pull request, and an unlisted branch is one the loop treats as disposable: fair game to
  rebase and force-push.
- **Detached HEAD** does not block any of this — every probe above is by ref name. **No `origin`**
  does: mark the branch keys `ambiguous` and give that as the reason.

### A7. Review engines

Report what is here. **Absent is a finding, not a failure** — an empty roster is a legal
configuration in which the built-in adversarial pass is the local gate.

- **A local review CLI** (`review.localCommand`) — probe with `command -v codex`, and with the name
  of any other review CLI the user names. Found → offer it as a candidate, `ambiguous`, because the
  exact invocation is a choice and the defaults are usually wrong for this: which model, which
  reasoning effort, which flags. Also carry `review.localReviewerName`, so the roster calls the
  engine what it actually is rather than the shipped default's name.
  **Not found → `unknown`, not a detected `null`.** One probe that missed is not evidence of absence:
  the tool may be a shell alias a non-interactive shell never loaded, or a perfectly good reviewer
  with a name nobody thought to check. Since a `detected` row is advertised as copyable, a detected
  `null` here would quietly switch off a review engine the user has installed — and they would never
  see the moment it happened. Report what was probed, and let the question be asked.
- **Cloud reviewers** (`review.automatedReviewers`) — a cloud reviewer is *possible* when the origin
  host is GitHub and `gh auth status` succeeds for that host. **An entry is more than a name** — the
  review flow requests each reviewer per its `how`, and a `requested_reviewer` bot is requested by
  its `graphqlBotId`, so an entry missing those fields is malformed and silently requests nothing.
  Take the complete entry from the known-reviewer catalog in the defaults reference, or ask for
  every field; never write a half-populated one. That is a precondition, **not proof
  that a review can be requested**: entitlement, repository settings and organization policy all sit
  behind it, and none of them are visible from here. So a positive result is `ambiguous` — a
  candidate to confirm — and never `detected`. Whether a request actually lands is only ever settled
  on a real pull request, by the review flow that requests one and then checks the timeline for the
  event. **Setup never settles it** — not here and not in Phase G, which has no pull request to
  request against and would have to mutate an unrelated one to try.
- **`gh` itself** — `gh --version` and `gh auth status`. The whole delivery half depends on it: no
  `gh` means no pull requests, no review threads, no ready-flip. Read the **active** account's line;
  `gh auth status` can list several with different scopes. If authentication comes from `GH_TOKEN` or
  `GITHUB_TOKEN`, say so, because that changes how it gets fixed.

### A8. Conventions doc, and any existing config

- `conventionsDoc` — `AGENTS.md`, `CLAUDE.md` or `CONTRIBUTING.md` at the repository root, in that
  order of preference. More than one → `ambiguous`, listing them; the build engine reads exactly one
  and obeys it, so this choice has teeth. None → `unknown`.
- **A pull-request template** → a `prBodyTemplate.sections` row, `ambiguous`, carrying the template
  as the candidate. This repository already has an agreed pull-request format, and once setup writes
  the generic sections the pull-request skill treats them as authoritative and quietly stops using
  the one the team actually agreed on. Detecting it is what turns "should be replaced" into a
  question that gets asked.
  - **Look in every place GitHub honours, case-insensitively**: `pull_request_template.md` at the
    repository root, in `.github/`, or in `docs/`, and a `PULL_REQUEST_TEMPLATE/` directory in any of
    those three. Checking one spelling in one directory reports "no template" for most repositories
    that have one, which is worse than not looking — it produces a confident default.
  - **Capture each section as `{heading, guidance}`, not as a heading alone.** The pull-request skill
    fills each section from its `guidance`, so a heading with an empty guidance yields a section the
    skill does not know how to write, and the instructions or checklist the team wrote underneath are
    dropped from every pull request thereafter. Carry the text beneath each heading across as the
    guidance; where a heading has nothing under it, ask what belongs there rather than leaving it
    blank.
- **Read `.claude/ds-config.json` if it exists** and record each key's current value alongside the
  detected one. This is the only way a later re-run can tell a hand-edit apart from a stale value,
  and a re-run that cannot tell them apart is a re-run that overwrites deliberate work.
- **Documentation hooks** — two rows, `docs.updateSkill` and `docs.releaseNotesSkill`. Detection is
  limited here and the row must say so. From the existing config's `docs` block: a name whose
  `.claude/skills/<name>/SKILL.md` exists is `detected`; one whose directory is missing is
  `ambiguous`, carrying the dangling name. A legacy `release.docsRepo` block is `ambiguous`: its
  values are the candidate answers for the Phase D interview, and Phase F migrates it. Then look
  for signs of a documentation system to offer as **candidates, never as answers** — a `docs/`
  directory, a static-site config (`mkdocs.yml`, `docusaurus.config.*`, a `nuxt.config.*` beside a
  `content/` directory, `_config.yml`), a `CHANGELOG.md`, a `release-notes/` directory. Where
  nothing is found the rows are `unknown`, not `null`: a repository with no documentation is a
  legitimate answer, and only the owner can give it. The contract these hooks meet is
  `${CLAUDE_PLUGIN_ROOT}/skills/release/references/docs-hooks.md`.

### A9. Local environment

How this repository stands up an isolated local instance, if it can. Five rows:
`localEnvironment.create`, `.seed`, `.migrate`, `.teardown`, `.instanceBoundTo`.

- Look for the shapes that usually mean one exists: `docker-compose*.yml`, `docker-compose*.yaml`, `compose.yml` or
  `compose.yaml`, a `.devcontainer/`, a `flake.nix` or `shell.nix`, a `Tiltfile` or `skaffold.yaml`, and root scripts
  named `dev`, `sandbox`, `env:*`, `db:seed`, `db:reset`, `migrate`. Each is a **candidate** for the
  row it suggests — a compose file suggests `create`, a `db:seed` script suggests `seed` — never a
  `detected` value: a compose file proves a stack exists, not that `docker compose up` is how this
  team starts it. Report such rows `ambiguous`, carrying the candidate.
- **`instanceBoundTo` is never `detected`.** Whether a second checkout gets its own database, tables
  and ports is a property of the tooling's design, and nothing in a file says it. Ask, with
  `directory` (a second worktree gets its own instance; checking out another branch inside it keeps
  that instance's data), `branch`, and `none` as the options, saying what each means for the loop.
- Existing config: record the current block, per A8.
- Nothing found → the rows are `unknown`, not `null`. A repository with no isolated environment is
  a legitimate answer, and only the owner can give it; `null` is what the owner writes for a
  command that does not exist.

## The prefill summary — the contract

Phase A's output is a list of rows, one per configuration key, each with:

| Field | Meaning |
|---|---|
| `key` | Dotted path into `.claude/ds-config.json` — e.g. `verify.typecheck`, `review.openPullRequestsAsDraft` |
| `value` | The detected value, in the shape the key takes (array, string, boolean, object). `null` when nothing was detected |
| `evidence` | What produced it: the file read or the command run. Never empty |
| `status` | `detected`, `ambiguous`, or `unknown` |
| `candidates` | Present only when `ambiguous` — every plausible answer, so the question can offer them |
| `existing` | Present only when `.claude/ds-config.json` already sets this key — its current value |

**This shape is the contract.** Every `detected` row becomes a prefilled default; every `ambiguous`
or `unknown` row becomes a question. Rows are the unit — a key that produced no row is not a key
with no answer, it is a key nobody looked at, and the two must stay distinguishable.

## Phase B — report what was found

Present the summary grouped the way someone reads it, not the way it was gathered: what was detected,
what needs a decision, and what could not be determined. Lead with the count of each, so a user with
two open questions sees "two" rather than scanning forty rows for them.

**On a narrowed run, this is the end.** Report what that detector found and stop — see the argument
note at the top for why: the other detectors never ran, so the phases that write have nothing to go
on for most of the file.

On a full run, say what happens next — the open questions are coming, and nothing has been written
yet — and go to Phase C. Do not stop here for approval of the findings themselves; Phase D asks about every row
that needs a human, and the bulk confirmation there is where detected values get their sign-off.

## Phase C — map the organization's work types onto the loop's roles

The loop reasons in two abstract roles, and `hierarchyRoles` is where a repository says which of its
organization's real work types fill them:

- **`releaseUnit`** (a string) — the parent-item level whose completion cuts a release. The loop
  gives each one an integration branch, batches its work onto it, and ships it as one reviewed
  increment.
- **`leaf`** (an array of strings) — the executable one-day item types the loop actually builds.

`Container` is internal hierarchy shorthand, not user-facing DevStride vocabulary. In questions and
reports say **parent item**, **grouping item**, or the actual work type name returned by DevStride.
Developers reasonably interpret an unexplained “container” as Docker.

Read them from the organization, do not assume them. `get_workspace_context` establishes which
organization is connected; `get_work_type_hierarchy` returns the tree and a per-name lookup with each
type's parent and ancestor chain. **Never assume canonical spellings** — organizations rename these,
and they have typos; one real organization's capability level is spelled `Capabilty`. Whatever the
call returns is the truth, including its misspellings, because that string is what the loop will
compare against.

Propose from the structure: the childless types at the bottom of the deepest chain are the `leaf`
candidates, and the level directly above them is the `releaseUnit`. Confirm with `AskUserQuestion`,
showing the proposal against the actual hierarchy so the choice is legible — and confirm even when
the structure looks obvious, because this single answer decides where the loop branches, what it
counts down to, and what "a release" means for this repository. Getting it wrong plans work at one
size and releases it at another.

Two shapes need care:

- **More or fewer levels than the proposal assumes.** The model is two roles, not a level count. An
  organization with five parent-item levels still has exactly one release boundary; ask which,
  rather than counting.
- **A single work type doing everything.** Map it to both roles and say explicitly what that means:
  every item is its own release unit, so the loop runs without integration batching.

### When the DevStride connection is not available

The bundled server contributes **no tools at all** until it is signed in — that is the signed-out
symptom, not an error, so the failure mode to avoid is a wall of tool errors that reads like a bug.
Say it once, plainly: the server ships with the plugin, it needs one browser sign-in, and `/mcp` is
where that happens. Then offer two paths and take the user's answer:

1. **Continue without it** — everything else is detectable, so the config gets written with
   `hierarchyRoles` omitted and reported as required follow-up. Say what stays broken meanwhile:
   the loop cannot resolve release units, so it cannot batch or release by them.
2. **Stop and resume** — connect first, then re-run. Nothing is lost; setup is re-runnable by design.

Never guess the roles from the plugin's own defaults to paper over a missing connection. A plausible
`hierarchyRoles` naming work types the organization does not have is worse than an absent one: absent
is visible, and wrong silently matches nothing.

## Phase D — ask only what is left

Walk the prefill summary and turn it into as few questions as the repository allows.

- **Every `ambiguous` or `unknown` row is a question**, asked with `AskUserQuestion`. An `ambiguous`
  row already carries its candidates — offer them as the options, with the likeliest first. An
  `unknown` row has no prefill, so ask plainly and say what the value is for.
- **`detected` rows are confirmed in bulk, not asked one at a time.** Show them as a list with their
  evidence and take a single yes. Interview length is the product's first impression, and asking
  someone to re-approve forty facts their own repository just proved is how a good setup feels bad.
- **An explicit answer always beats a detection.** If the user overrides a `detected` value, the
  override is what gets written — do not re-apply the detected one at write time, and do not argue.
Four things no inspection can reach, asked every run — the first one first, because its answer
moves other keys:

- **Which delivery profile?** (`profile`) — one question, three options, each captioned with the
  contract's one-line "who it is for": `prototype`, `standard` (the default — offered first, and
  the answer when the user takes the default), `enterprise`. The contract is
  `${CLAUDE_PLUGIN_ROOT}/skills/plan/references/delivery-profiles.md`; read it before asking, and
  take the captions from its table rather than paraphrasing them. Say in the question what the
  answer moves — `epicIntegrationBranches.autoRelease`, `fastStoryMerges.enabled` and
  `review.pollTimeoutMinutes` are written to match it, at the values in the defaults reference —
  so the user is choosing a shape, not a label. On a re-run the file's current `profile` is the
  prefill. **If the answer is `prototype`, say the consequence before moving on**: `autoRelease`
  becomes `true`, so a release unit merges to `baseBranch` the moment its last item lands, with no
  human saying so. Name the branch; where it is also the production branch, or is promoted to it
  without a gate, that is production with nobody's hand on it, and the owner must hear it here,
  from setup, not from a deploy. The profile is never `detected`: nothing in a repository says how
  much rigor its owners want.
- **What does merging to the production branch actually do?** (`release.autoDeployOnMerge`) — one
  plain-English sentence: whether it deploys production automatically, and through what. Nothing can
  detect this and there is no sensible default, yet it is the sentence the release skill quotes back
  to an owner at the production gate so they know exactly what they are approving. Left unasked, it
  gets improvised at the one moment in the whole loop where improvising is least acceptable.
- **Documentation — three questions, asked together** (`docs.*`). Nothing here is detectable beyond
  the candidates A8 surfaced, and the answers become two LOCAL skills rather than config values, so
  ask precisely:
  1. **Where does documentation live?** A directory in this repository, a sibling checkout (path and
     branch), a hosted service (URL), or "nowhere" — in which case write `docs.updateSkill: null`,
     skip question 2, say that the release skill's docs pass will report itself skipped, and
     **still ask question 3**: the two hooks are independent, and a repository with no reference
     docs may well publish release notes (a changelog, a mailing).
  2. **How is documentation updated?** Edited and pushed straight to a branch that publishes on
     push; edited on a branch and merged through a pull request; through a tool or service; by
     someone else entirely (then the skill's job is to hand that person the delta). Capture whatever
     makes "publish" concrete for this repository — the branch, the pull-request base, the command,
     the person.
  3. **How are release notes pushed?** Where a note lives (a `release-notes/` directory, a
     `CHANGELOG.md`, a page in a service, a mailing) and how it becomes visible. "We do not publish
     release notes" is a real answer: write `docs.releaseNotesSkill: null` and say that
     `--release-notes` on the release skill will report itself unavailable.

  Then take the skill **names** (defaults `update-documentation` and `update-release-notes`; the
  owner may prefer a repository prefix), and — separately, because it is optional —
  **`release.deployVerification`**: a command that exits 0 only when production is serving the
  commit in `RELEASE_COMMIT`. Say what it buys: with it, release notes can be written the moment
  the deploy is proven live; without it, the release skill asks the owner to confirm the deploy by
  hand first. Never invent one. The answers are written into the scaffolded skills in Phase E2, not
  into the config — the config holds only the two names. The contract those skills must meet is
  `${CLAUDE_PLUGIN_ROOT}/skills/release/references/docs-hooks.md`. **Release notes are opt-in per
  release, by design**: setup never writes a policy for when a note is "warranted", because the
  release skill never interprets one — the owner passes `--release-notes` when they want a note.
- **Where should the lessons store live**, if not the default path.
  **Do not offer to create the file** — the store has a single writer, and it is not this skill. Its
  absence is a valid starting state that the review skill resolves the first time it has a lesson
  worth keeping; a file created here would be a second writer producing a store with no lessons in
  it. Write the key, nothing else.

## Phase E — write the config

One write, after every confirmation, of the whole document. There is no state in which a half-written
config exists.

Write these keys. Values come from detection, from Phase C, or from the answers in Phase D; where
none of those apply, write the shipped default, because a key present with a default is inspectable
and a key absent is invisible.

**The defaults are literal values, not a description of one.**
`${CLAUDE_PLUGIN_ROOT}/skills/setup/references/config-defaults.md` holds every one of them —
the delivery-profile values, branch naming, integration branches, commit conventions, the
pull-request body template, the CI block, the empty lists, and the known-cloud-reviewer catalog.
**Read it before writing**, and copy the
values verbatim. The delivery skills compare against these strings literally, so a default
paraphrased into something that means the same thing is a default that no longer matches.

| Key | Value |
|---|---|
| `baseBranch`, `hotfixBaseBranch`, `protectedBranches` | From A6. `protectedBranches` **always** contains the base, production and release-source branches |
| `integrationBranch` | `null` — the per-release-unit derivation is the default; an explicit value overrides it |
| `profile` | The Phase D answer, as the word itself — always written, `standard` included; the defaults reference says why |
| `epicIntegrationBranches` | Verbatim from the defaults reference, with `autoRelease` at the profile's value and `fastStoryMerges.enabled` decided by the rules below |
| `verify` | `typecheck` (array), `test`, `lint`, `testSingle`, `testDir`, `skipDuringStoryBuilds: []` |
| `generated` | Only when detected — omit rather than write an empty shape |
| `review` | The roster and the three CI-ordering booleans, per the rules below; `pollTimeoutMinutes` at the profile's value |
| `prBodyTemplate`, `commitConventions`, `ci`, `branchNaming` | Verbatim from the defaults reference, unless the repository said otherwise — `ci` includes `freezeBaseWhileReleasePrReady: true` and `expectedRunsPerPullRequest: 1` |
| `preShipChecks`, `preCommitWiringChecks` | `[]` — a repository names these for itself, deliberately; see the defaults reference for why empty is a real answer |
| `hierarchyRoles` | Phase C's confirmed mapping |
| `release` | `productionBranch`, `releaseSource`, `autoDeployOnMerge`, and `deployVerification` (`null` unless the owner gave one). Never `docsRepo` — that shape is retired; Phase F migrates one it finds |
| `docs` | `updateSkill` and `releaseNotesSkill` — the local skill names Phase E2 scaffolds, or `null` where the owner said there is nothing to update; `updateOnEpicRelease: false` |
| `conventionsDoc`, `itemTagFormat`, `lessonsDoc` | From A8, the answers, and the shipped default path |
| `plugin` | Verbatim from the defaults reference — `updateCheck: true`, `autoUpdate: false`, `pin: null`. Not asked: the default is right for nearly every repository, and the block is documented where the owner will find it |
| `localEnvironment` | `create`, `seed`, `migrate`, `teardown` (each a command string or `null`) and `instanceBoundTo`, from A9 and the answers. Write the block even when every command is `null` — `branch-hotfix` and `build-item` read it, and an absent block reads as "nobody asked", not "there is none" |

**The roster must describe what actually exists.** This is the one place where writing an aspirational
config does real damage, because every later run reads these keys as fact:

- No local review CLI detected → **omit `localCommand`** (or write `null`). The built-in adversarial
  pass is then the local gate, which is a legal configuration, not a degraded one.
- No cloud reviewer → **`automatedReviewers: []`**. Nothing is requested, polled or waited on, and an
  absent review is correct rather than pending.
- **`fastStoryMerges.enabled` is decided per repository, and the precondition depends on the
  profile.** Under fast merges an item gets no pull request and no CI of its own, so the local
  engines and the local suites are the only gate it receives; enabling it with nothing behind it
  merges code that nothing checked. Under `standard` and `enterprise`, write `true` only when a
  local CLI engine is on the roster *and* `verify.test` and `verify.typecheck` are set. Under
  `prototype`, write `true` whenever `verify.typecheck` is set — Claude's build-time pass is the
  local engine the contract's floor needs, and the profile's story gate is type-checks plus the
  touched suites. The exact rule is in the defaults reference; apply it, do not re-derive it.
- If the applicable precondition is not met, write `fastStoryMerges.enabled: false` and say which
  part was missing — under `prototype` too, saying there that the file now contradicts its
  profile, which `/devstride:doctor` will also report.
- **`autoRelease` and `review.pollTimeoutMinutes` take the profile's values** from the defaults
  reference. When that means writing `autoRelease: true` for `prototype`, repeat the consequence at
  the write, naming `baseBranch`: the release unit will merge there with no human saying so. That
  warning is the operator's to hear, and the write is the last moment setup can give it.

Then say what was written and where — and go to Phase E2 (scaffold the documentation skills the
`docs` block names), then Phase G. **The run is not finished at the write.** A config that has never been executed is a plausible-looking file, and the whole point of
Phase G is that plausible is not the bar.

## Phase E2 — scaffold the local documentation skills

The plugin holds only the two skill names; the owner's answers about where documentation lives, how
it is updated and how release notes are pushed belong in the repository, as skills it owns. Write
them now, from the templates in `${CLAUDE_PLUGIN_ROOT}/skills/setup/references/docs-skill-templates/`:

- `.claude/skills/<docs.updateSkill>/SKILL.md` from `update-documentation.md`, and
  `.claude/skills/<docs.releaseNotesSkill>/SKILL.md` from `update-release-notes.md` — only for the
  hooks the owner did not answer "nowhere" / "we do not publish" to.
- Fill every `{{PLACEHOLDER}}` from the Phase D answers, in the owner's own terms, and set the
  frontmatter `name` to the directory name. Where the answers came from a legacy `release.docsRepo`
  block (Phase F), its `path`, `branch` and `autoDeployOnPush` are the answers to the first two
  questions. Leave no placeholder unfilled: a skill that still reads `{{DOCS_LOCATION}}` is a skill
  that will confidently edit nothing.
- **Never overwrite a skill that already exists.** A present `SKILL.md` is the repository's,
  hand-edited or not; leave it and say so. The scaffold is a starting point, not a managed file —
  the owner edits it from here, and re-running setup must cost them nothing.
- Confirm the skill files are not gitignored (`git check-ignore <path>` must exit 1). A scaffolded
  skill that never enters a commit exists on one machine only, and every other clone's release
  skill will report a dangling hook.
- Tell the owner what was written, that each skill's `check` mode is what Phase G and
  `/devstride:doctor` run, and that the skills are theirs to refine — the templates are generic on
  purpose.

## Phase F — re-running on a repository that already has a config

Setup is re-runnable, and a re-run must never cost someone their hand edits. This path is the
difference between a command people run again and one they run once.

1. **Re-detect everything** — Phases A and C, unchanged.
2. **Diff against the existing file** and propose **only what would change** — a key that already
   matches is not a question. "What would change" is wider than detection: it is every accepted
   detector value that differs, every interview answer that differs (including a documentation hook the
   user has just said no longer applies), and every key missing entirely because it was written by hand or by
   an older version. Restricting the proposal to detected values alone silently drops the other two,
   which is how a stale setting survives a re-run the user thought had removed it.
   `profile` is a recognized key like any other: the file's value prefills the Phase D question, an
   unchanged answer is not a proposal, and a changed one proposes the profile **together with** the
   three keys it moves, as one change. A user who accepts the new profile but keeps a hand-set
   `autoRelease` or `pollTimeoutMinutes` has made an explicit choice — the key stands, by the
   contract — so say at the write that the file now disagrees with its profile, and that
   `/devstride:doctor` will report the same. A config with no `profile` at all was written by hand
   or by an older version: ask the question and propose the addition.
3. **On acceptance, deep-merge** the accepted keys into the existing document — then run Phase E2
   for any `docs` hook the merge introduced or migrated, and Phase G as usual.

What survives a merge, verbatim and unconditionally:

- **Keys setup does not recognize.** They may be newer than this version of the skill, or something
  the repository added on purpose. Either way they are not yours to remove.
- **Every `_`-prefixed key.** Real configs carry `_readme` annotations documenting hard-won reasons
  beside the values they explain. They are documentation, they are load-bearing to whoever wrote
  them, and a rewrite that drops them destroys the reasoning while leaving the config working.
- **Any value setup did not propose changing.** Silence is not consent to revert.

**One deletion is allowed, and only one shape of it:** a key setup itself recognizes, which the
user has explicitly said no longer applies — a documentation hook (`docs.updateSkill` or
`docs.releaseNotesSkill`) naming a skill for a documentation system that is gone being the case that
actually happens. Leaving it in place is not conservative: the release skill reads a present name as
a registered hook and would invoke a skill with nothing left to update. So set it to `null`, after
an explicit answer, and say you did.

**The legacy `release.docsRepo` block is the one migration.** A config written before 1.0 carries
docs settings the plugin itself used to act on. Propose, as one change: scaffold the local skills
from its values (Phase E2), write the `docs` block naming them, and remove `release.docsRepo`. On
acceptance do all three; on refusal leave the block untouched and say that the release skill will
report it as deprecated and run without docs until it is migrated.

Everything else stands: never remove an
unrecognized key, never remove one the user did not speak to, never rewrite the file wholesale to
normalize its shape, and never treat a missing key as a deliberate choice — a config written by hand, or by an older version, is simply
incomplete, so propose the addition. **Setup authors this file; it is not a precedence layer.** The
existing contract is unchanged: the file wins over the skills' shipped defaults, including over
anything setup itself wrote.

## Phase G — prove the config by running it

**A config is not done until it has run.** Everything up to here produced a file that *looks* right;
this phase finds out whether it *is* right, while the person who can fix it is still sitting there.
The alternative is discovering it later, from inside the delivery loop, as a confusing failure three
steps removed from its cause.

Phase G runs automatically after every write — fresh or merge — and is also available on its own
against a config setup did not write. **Validation reads the file, not any memory of writing it**;
keys it does not recognize are ignored, not errors.

`${CLAUDE_PLUGIN_ROOT}/skills/setup/references/validation-checklist.md` holds the checks and the
failure-mode table — symptom, likely cause, exact fix. Read it when you run this phase, and map
every failure to its row rather than improvising an explanation.

**Run every check, even after one fails.** Someone with three problems should learn all three now,
not one restart at a time. Each check ends `PASS`, `FAIL`, `SKIPPED` (by the user) or `UNVERIFIABLE`
(offline, or a prerequisite absent) — and those last two are **not** failures. Collapsing them into
one is how a setup gets called broken because a laptop was on a train.

1. **The verify commands actually run.** Execute every `verify.typecheck` entry and `verify.lint`;
   exit 0 is the pass. Where `generated.toleratedTypeErrors` is configured, errors matching it in
   files matching `generated.paths` do not fail the check — that is what the key is for.
   **`verify.test` is offered, never forced**: suites can run for half an hour, and nobody wants that
   sprung on them mid-setup. Declining is `SKIPPED`, and it is reported in the verdict rather than
   quietly folded into a pass.
   **Echo any command the user typed during the interview before running it the first time.** A
   detected command came from the repository's own scripts; a hand-entered one has never been seen
   by anything, and executing it unannounced is not a good first impression.
   **And be honest that these commands are not yours.** The write boundary says *this skill* writes
   one file — it does not, and cannot, promise the repository's own scripts leave the tree alone. A
   lint script may carry `--fix`, a typecheck may drop an incremental cache, a script may invoke a
   generator. So **ask before running anything whose name or flags suggest it writes** (`--fix`,
   `--write`, `format`, `fmt`, a regen), and note in the verdict when the tree changed during
   validation. Reporting `PASS` while quietly having reformatted somebody's source is the one
   outcome here that would be genuinely hard to forgive.
2. **The branch refs exist.** `git rev-parse --verify` for `baseBranch`, `release.releaseSource`,
   `release.productionBranch` and `hotfixBaseBranch` — all four, preferring the remote-tracking ref
   and falling back to local. **Then confirm them against the remote itself** with
   `git ls-remote --heads origin`: remote-tracking refs are a local cache and outlive the branches
   they name, so a deleted branch still passes a `rev-parse` and the loop fails on its first fetch.
   Where that network call cannot run, the ref checks are `UNVERIFIABLE` rather than `PASS` — say the
   evidence was a possibly-stale cache. Leaving the release source out is easy and expensive: the
   release skill fetches it first thing, so a stale value passes validation and fails at the release. Then assert
   `protectedBranches` still contains base, production and release source — a config that lost one is
   a config with the safety off.
2b. **The GitHub toolchain the delivery half requires.** Unconditional, whatever the review roster
   says: an `origin` remote exists **by name**, its host is GitHub, and `gh` is installed and
   authenticated for that host **with write access to this repository**. Authentication alone is not
   the check: a read-only token passes `gh auth status` and passes a repository read, and then cannot
   push a branch, open a pull request or merge one. Read the active account's scopes (`repo`, plus
   `read:org` for an organization-owned repository) and the repository's own permissions — 
   `gh api repos/{owner}/{repo} --jq .permissions` — and report a read-only result as a `FAIL` for
   delivery readiness, naming `gh auth refresh -s repo,read:org` as the fix. These are not reviewer conveniences — without them the loop cannot
   push, open a pull request, or merge anything. Checking them only when a cloud reviewer happens to
   be configured is how a repository with no `origin` gets certified loop-ready and then fails at the
   loop's first push. On a non-GitHub host, say plainly that the delivery half has no adapter and that
   the planning half still works — that is a `FAIL` for delivery readiness, not a warning.
3. **The declared review engines respond.** Only what the config declares — an engine nobody
   declared is not a gap, so do not check for it and do not mention it.
   A local CLI must actually be invocable: probe the binary from `review.localCommand` and get a
   version out of it. For a cloud reviewer, confirm `gh auth status` for the repository's host and
   read access via `gh api repos/{owner}/{repo}`.
   **Say plainly what that last one does not prove.** Access is a precondition; whether a review
   request actually registers is only ever settled on a real pull request, because the request
   mutation reports success even when it creates nothing. `PASS` here means "nothing is obviously
   in the way", and the checklist says so in those words.
4. **The work-type roles still resolve.** Re-read the hierarchy and confirm every name in
   `hierarchyRoles` is still there. Work types get renamed and archived between setup runs, and the
   failure is silent: the loop simply matches nothing, finds no release unit, and quietly treats
   every item as a one-off. If the DevStride connection is unavailable, reuse Phase C's message and
   record `UNVERIFIABLE` — a validation run must not stack-trace either.
5. **The lessons store has somewhere to live.** Check the `lessonsDoc` parent directory exists and is
   writable. That is the whole check: **setup never creates this file** — the review skill does, on
   its first lesson — so a missing file is the normal state and not a finding. What matters is that
   the directory will accept it when the time comes.
6. **The CI ordering is self-consistent.** Mostly a warning — but one case is a `FAIL`, and the
   distinction is whether CI can still *settle*.
   - **Warning:** the config opens pull requests as drafts and no workflow carries a draft gate. The
     hold does not engage, so CI runs more often than intended. Wasteful, not broken.
   - **Warning:** a pull-request workflow has no `concurrency` block, or the production-branch push
     runs with no tree-identical skip — CI is correct but pays for superseded and duplicate runs.
     Say `/devstride:setup ci` applies both, and `/devstride:ci-audit` shows what they cost.
   - **`FAIL`:** a draft-gated workflow whose trigger cannot rerun it — `types` absent, or an
     explicit list missing any of `opened`, `synchronize`, `reopened`, `ready_for_review` (a
     convention-only workflow, A5, never reaches this check). Here the
     loop cannot finish at all: after a red run, a fix push starts nothing and the close-and-reopen
     fallback has no event to fire on, so it waits forever on a run that cannot exist. A repository
     in that state is not loop-ready, whatever else passes.
   Point at `/devstride:doctor` either way. **Never edit a
   workflow to fix it**: outside `.claude/` this skill does not write, and that boundary does not
   bend for a helpful one-line change.

**The verdict is the output.** List every check with its outcome, then one line: **loop-ready** only
with zero failures — skips and unverifiables are fine, provided they are named. Anything else says
what failed and the fix from the checklist.

Two things the verdict must say when they are true, so a failure is not misread:

- **The working tree was dirty.** Validation runs against the tree as it is, which is correct, but an
  uncommitted change is a far likelier cause of a failing typecheck than the config is.
- **The run was offline.** The git and command checks are unaffected; the connection and cloud-access
  checks are `UNVERIFIABLE` and worth re-running when there is a network.

IMPORTANT:
- **The write boundary is `.claude/ds-config.json`, the Phase E2 scaffolds, and — in `setup ci` only, on acceptance — the pull-request workflows.** See the top. Everything else on disk is
  read-only to *this skill*, in every phase. The one thing that is not this skill is the repository's
  own verify commands, which Phase G runs — they belong to the repository and may touch the tree;
  Phase G asks first where that looks likely and reports it when it happens.
- **Never report a guess as `detected`.** The status column is the only thing standing between a
  detected value and a fabricated one, and a user who finds one wrong value stops trusting all of
  them.
- **Absence is information.** No local review CLI, no cloud reviewer, no CI provider — each is a real
  finding with a real value to write. Reporting them as gaps to fix misrepresents a legal
  configuration as a broken one.
- **Never write a config that claims an engine the repository does not have.** Every later run treats
  these keys as fact, so an aspirational roster does not fail loudly — it quietly changes what gets
  reviewed.
- **A written config is not a finished one.** Phase G is not an optional flourish at the end; it is
  the difference between a file that looks right and one that has been shown to work. Never end a
  run at the write and call the repository set up.
7. **The documentation hooks respond.** Only when `docs.updateSkill` or `docs.releaseNotesSkill` is
   set — an absent or `null` hook is a repository with no documentation system, which is `N/A` and
   said so, not a gap. For each name: `.claude/skills/<name>/SKILL.md` exists (missing → `FAIL`,
   fix `/devstride:setup docs`), then invoke the skill in its `check` mode and take its verdict —
   read-only by contract, so it is safe to run here. A skill with no `check` mode is a `FAIL` naming
   the template it should be rebuilt from. A `release.docsRepo` block is a `FAIL` naming the Phase F migration whenever it is present,
   with or without a `docs` block beside it. Where `release.deployVerification` is set, confirm its first
   token resolves (same segment-splitting as the verify commands) but do not run it — it is
   meaningful only against a real merge commit.
