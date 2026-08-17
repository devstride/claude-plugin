---
name: setup
description: Inspect this repository and work out what its .claude/ds-config.json should say — package manager, verify commands, CI provider and draft gating, branches, review engines, conventions doc — then present the findings with the evidence behind each one. Read-only; writes nothing.
user-invocable: true
disable-model-invocation: true
---

Work out what the delivery loop's configuration should be **for this repository**, by looking at the
repository rather than asking. Run it after installing the plugin, before writing
`.claude/ds-config.json` by hand.

Optional argument — a detector name, to run just that one: `ecosystem` (A2–A3), `verify` (A4),
`ci` (A5), `branches` (A6), `engines` (A7), `docs` (A8). **Run each one's prerequisites too, silently
— A1 always, and A2–A3 before A4**, which cannot compose a command without knowing the package
manager or find workspace scripts without knowing the layout. A narrowed run reports fewer keys; it
must never report worse ones: $ARGUMENTS

> **This version inspects and reports. It does not write the config file.** The interview that turns
> these findings into `.claude/ds-config.json` arrives in a later release. Until then this is a
> filled-in worksheet: everything it marks `detected` is a value you can copy straight into the file,
> and everything it marks `ambiguous` or `unknown` is a decision only you can make. Phase B says
> exactly this to the user; do not imply a file was written.

**This skill is READ-ONLY.** It reads files and runs inspection commands. It never writes, moves or
deletes a file — `.claude/ds-config.json` included — never mutates git state (no commit, checkout,
branch, fetch, push or `git config` write), never installs anything, and never calls a DevStride
write tool. A run must leave `git status --porcelain` byte-identical to how it found it.

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

When it is GitHub Actions, look at the workflows themselves before prefilling the three CI-ordering
booleans — and look only at the ones this is about: **workflows with an `on: pull_request` trigger.**
A workflow that fires on push, on a schedule, or on `pull_request_review` is not part of the draft
hold, and judging it as ungated turns a correctly-configured repository into a false finding (`review.openPullRequestsAsDraft`, `review.readyForReviewReleasesCi`,
`review.ciHeldUntilReviewSettled`). Two things have to be true for the hold to work, and **the second
is the one repositories get wrong**:

1. Jobs are gated on the draft condition — `github.event.pull_request.draft == false`, or the
   equivalent `if: ${{ !github.event.pull_request.draft }}`.
2. **`ready_for_review` is in `on.pull_request.types`.** GitHub's default types are
   `[opened, synchronize, reopened]` and `ready_for_review` is *not* among them. Without it, marking a
   pull request ready creates **no workflow run at all** — the draft condition is never even
   evaluated — and the loop waits for a run that will never exist.

Four cases, and **all four produce all three rows** — a case that emits nothing leaves the loop on
shipped defaults chosen for somebody else's repository:

| What the pull-request workflows show | The three booleans |
|---|---|
| Draft-gated **and** `ready_for_review` in types | `true`, `detected` |
| Draft-gated, `ready_for_review` missing | `ambiguous` — the hold cannot work as written |
| Pull-request workflows exist, none draft-gated | `false`, `detected` — CI runs on open; the run-once design is simply not in use here |
| GitHub Actions present, but no pull-request workflow at all | `false`, `detected` — nothing to hold |

The second row is the one worth being stubborn about. Prefilling `true` there would configure the
loop to rely on a hold this repository cannot deliver — the ready-flip creates no run, and the loop
waits for it forever. Say what is missing and point at `/devstride:doctor`, which diagnoses this
specific gap. The third row is a legitimate configuration, not a defect: say what it means for cost
(CI on open and again after every fix push) and leave the choice with the user.

Any other provider — `.gitlab-ci.yml`, `.circleci/`, `Jenkinsfile`, `azure-pipelines.yml` — or none
at all: record the provider name and prefill the three booleans `false`, `detected`. That is not a
degraded setup, just a different one; the loop opens ordinary pull requests and never waits on a
draft flip. **Setup attempts nothing provider-specific beyond GitHub Actions.**

### A6. Branches

From git alone — no network unless a local answer is unavailable.

- **Enumerate the branches that exist, then reason about them.** `git branch --format='%(refname:short)'`
  and `git branch -r --format='%(refname:short)'` — read **both**, because a fresh clone commonly has
  exactly one local branch and a local-only list reports a repository as single-branch when it is not.
  Enumerating first matters: plenty of repositories name their long-lived branches `production`,
  `trunk`, `release` or `staging`, and probing only for `develop`/`main`/`master` would not merely
  miss them, it would report a four-branch repository as single-branch and hand every role to the one
  name it recognized.
- Default branch: `git symbolic-ref refs/remotes/origin/HEAD`. **This ref is set at clone time and is
  frequently absent**, so treat an error as ordinary, not exceptional; the fallback is
  `git remote show origin`, which is a network call (see the ground rules).
- `develop` / `main` / `master` are **heuristics for assigning roles among the branches you found**,
  never the set of branches to look for. Where the names are conventional the roles follow; where they
  are not, present what exists and let the interview assign them.
**Four branch keys hang off this, not two, and every one of them has a shipped default pointing at a
branch this repository may not have.** Emit all four on every path, or the loop inherits
`develop`/`master` defaults and aims flows at refs that do not exist:

| Key | What it is |
|---|---|
| `baseBranch` | Where work branches from and merges back to |
| `release.releaseSource` | What gets promoted to production — normally the same branch as `baseBranch` |
| `release.productionBranch` | What production deploys from |
| `hotfixBaseBranch` | What an urgent fix branches from, so it carries no unreleased work — normally the production branch |

- A development branch **and** a main/master branch → `baseBranch` and `release.releaseSource` = the
  development one; `release.productionBranch` and `hotfixBaseBranch` = main/master.
- Branches exist but none carry a conventional name → `ambiguous` on all four, with every enumerated
  branch offered as a candidate and the `origin/HEAD` default named as the likeliest production
  branch. `protectedBranches` should offer the long-lived ones, not just the two you can name.
- Only one branch → prefill **all four** to that branch, status `ambiguous` on each. A single-branch
  repository is a legitimate configuration — base, release source, production and hotfix base are
  genuinely the same ref, and hotfixes are then ordinary branches — but so is a repository whose
  second branch simply has not been created yet, and those two want different answers. What is not
  acceptable is leaving two of the four unstated: the defaults would fill them with branch names this
  repository does not have, and the failure surfaces much later, at the first release or hotfix.
- Always compute `protectedBranches` containing the detected base and production branches. It is
  what keeps the loop from force-pushing or deleting them, so it should never be left empty by
  accident.
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
  host is GitHub and `gh auth status` succeeds for that host. That is a precondition, **not proof
  that a review can be requested**: entitlement, repository settings and organization policy all sit
  behind it, and none of them are visible from here. So a positive result is `ambiguous` — a
  candidate to confirm — and never `detected`. Whether a request actually lands is settled by
  actually requesting one, which is the validation phase's job, not this one.
- **`gh` itself** — `gh --version` and `gh auth status`. The whole delivery half depends on it: no
  `gh` means no pull requests, no review threads, no ready-flip. Read the **active** account's line;
  `gh auth status` can list several with different scopes. If authentication comes from `GH_TOKEN` or
  `GITHUB_TOKEN`, say so, because that changes how it gets fixed.

### A8. Conventions doc, and any existing config

- `conventionsDoc` — `AGENTS.md`, `CLAUDE.md` or `CONTRIBUTING.md` at the repository root, in that
  order of preference. More than one → `ambiguous`, listing them; the build engine reads exactly one
  and obeys it, so this choice has teeth. None → `unknown`.
- **Read `.claude/ds-config.json` if it exists** and record each key's current value alongside the
  detected one. This is the only way a later re-run can tell a hand-edit apart from a stale value,
  and a re-run that cannot tell them apart is a re-run that overwrites deliberate work.

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

## Phase B — report, then stop

Present the summary grouped the way someone reads it, not the way it was gathered: what was detected,
what needs a decision, and what could not be determined. Lead with the count of each, so a user with
two open questions sees "two" rather than scanning forty rows for them.

Then say plainly:

- Nothing was written. This run inspected only, and the repository is byte-for-byte as it was found.
- The `detected` values can be copied into `.claude/ds-config.json` as they stand. Point at the
  [configuration reference](https://docs.devstride.com/developer-experience/agentic-skills/configuration-reference)
  for the full key contract — shapes, defaults and the keys no inspection can reach.
- The guided interview that asks the open questions and writes the file is not in this release yet.
- `/devstride:doctor` checks a config once it exists, and diagnoses the setup problems inspection can
  only observe.

Do not offer to write the file, and do not write it if asked — that path does not exist yet, and a
hand-rolled substitute would produce a file the real interview later has to reconcile against.

IMPORTANT:
- **Read-only, absolutely.** See the contract at the top. If a detector seems to need a write, it is
  the wrong detector.
- **Never report a guess as `detected`.** The status column is the only thing standing between a
  detected value and a fabricated one, and a user who finds one wrong value stops trusting all of
  them.
- **Absence is information.** No local review CLI, no cloud reviewer, no CI provider — each is a real
  finding with a real prefill. Reporting them as gaps to fix misrepresents a legal configuration as a
  broken one.
