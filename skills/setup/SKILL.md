---
name: setup
description: Set the delivery loop up for this repository — inspecting it for everything answerable without asking (package manager, verify commands, CI provider and draft gating, branches, review engines), mapping your DevStride work types onto the loop's roles, asking only about what is left, and writing .claude/ds-config.json, which a re-run merges into rather than overwrites.
user-invocable: true
disable-model-invocation: true
---

Set the delivery loop up for **this** repository and **this** DevStride organization, in one guided
session. Run it after installing the plugin, and again whenever the repository changes shape.

Six phases: inspect what the repository can answer (A), report it (B), map the organization's work
types onto the loop's roles (C), ask only about what is left (D), write the config (E) — or, on a
repository that already has one, merge into it without destroying anything (F).

Optional argument: $ARGUMENTS

- **`validate`** — skip straight to Phase G and check the config that is already there. Nothing is
  inspected for a rewrite, nothing is asked, nothing is written. Use it after hand-editing the file,
  or to find out why the loop is behaving oddly.
- **A detector name** — `ecosystem` (A2–A3), `verify` (A4), `ci` (A5), `branches` (A6),
  `engines` (A7), `docs` (A8) — to inspect and report just that part.
- **Nothing** — the full run: inspect, ask, write, validate.

**Run each one's prerequisites too, silently
— A1 always, and A2–A3 before A4**, which cannot compose a command without knowing the package
manager or find workspace scripts without knowing the layout. A narrowed run reports fewer keys; it
must never report worse ones.

**A narrowed run stops after Phase B and writes nothing.** It has only looked at part of the
repository, so it has nothing to say about the rest — and a write would fill every key the skipped
detectors would have answered with a default, silently replacing real settings with guesses. Say
that a full `/devstride:setup` is what writes the file.

**The write boundary — the whole of it.** This skill writes exactly one path: `.claude/ds-config.json`.
Nothing else, ever. Not application code, not `CLAUDE.md`, not permission settings, not a CI
workflow, not a `.gitignore`. It never mutates git state — no commit, checkout, branch, fetch, push
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
   **But declaring `types` explicitly replaces the defaults rather than adding to them**, so a list
   naming `ready_for_review` and nothing else is its own trap: a fix push after a red run then
   starts no run either, and the close-and-reopen fallback has no `reopened` to fire on. An explicit
   list needs `opened`, `synchronize`, `reopened` **and** `ready_for_review`; anything short of that
   is `ambiguous`, naming which events are missing.

Five cases, and **every one of them produces all three rows** — a case that emits nothing leaves the loop on
shipped defaults chosen for somebody else's repository:

| What the pull-request workflows show | The three booleans |
|---|---|
| Draft-gated, **and** the trigger fires on all four of `opened`, `synchronize`, `reopened`, `ready_for_review` (whether by default or by an explicit list) | `true`, `detected` |
| Draft-gated, but any of those four events missing from an explicit `types` list | `ambiguous` — the hold cannot work as written |
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
- One conventional branch plus topic branches (the ordinary trunk-based repository: `main`, and
  whatever feature or dependency-bot branches happen to be open) → treat it as the single-branch case
  and prefill **all four roles to the trunk**, `ambiguous`, saying so. Topic branches are work in
  flight, never candidates for a role. What must not happen is falling through to "several branches,
  no answer": the roles all have shipped defaults, so an unstated role is not neutral — it silently
  becomes `develop` or `master`.
- Branches exist but none carry a conventional name → `ambiguous` on all four, with every enumerated
  branch offered as a candidate and the `origin/HEAD` default named as the likeliest production
  branch. `protectedBranches` should offer the long-lived ones, not just the two you can name.
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

- **`releaseUnit`** (a string) — the container level whose completion cuts a release. The loop gives
  each one an integration branch, batches its work onto it, and ships it as one reviewed increment.
- **`leaf`** (an array of strings) — the executable one-day item types the loop actually builds.

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
  organization with five container levels still has exactly one release boundary; ask which, rather
  than counting.
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
Three things no inspection can reach, asked every run:

- **What does merging to the production branch actually do?** (`release.autoDeployOnMerge`) — one
  plain-English sentence: whether it deploys production automatically, and through what. Nothing can
  detect this and there is no sensible default, yet it is the sentence the release skill quotes back
  to an owner at the production gate so they know exactly what they are approving. Left unasked, it
  gets improvised at the one moment in the whole loop where improvising is least acceptable.
- **Is there a sibling docs repository the release skill should update?** If yes, take the **whole
  object** in that same exchange: `path`, the `branch` to push, whether pushing deploys the site
  (`autoDeployOnPush`), whether releases update it by default (`updateByDefault`), and when a release
  note is warranted (`releaseNotesWhen`). A bare yes writes an incomplete `docsRepo` that stops the
  release skill at its first read. No docs sibling → omit `release.docsRepo` entirely, which is how
  the release skill knows to skip that phase.
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
branch naming, integration branches, commit conventions, the pull-request body template, the CI
block, the empty lists, and the known-cloud-reviewer catalog. **Read it before writing**, and copy the
values verbatim. The delivery skills compare against these strings literally, so a default
paraphrased into something that means the same thing is a default that no longer matches.

| Key | Value |
|---|---|
| `baseBranch`, `hotfixBaseBranch`, `protectedBranches` | From A6. `protectedBranches` **always** contains the base, production and release-source branches |
| `integrationBranch` | `null` — the per-release-unit derivation is the default; an explicit value overrides it |
| `epicIntegrationBranches` | Verbatim from the defaults reference, with `fastStoryMerges.enabled` decided by the rules below |
| `verify` | `typecheck` (array), `test`, `lint`, `testSingle`, `testDir`, `skipDuringStoryBuilds: []` |
| `generated` | Only when detected — omit rather than write an empty shape |
| `review` | The roster and the three CI-ordering booleans, per the rules below |
| `prBodyTemplate`, `commitConventions`, `ci`, `branchNaming` | Verbatim from the defaults reference, unless the repository said otherwise |
| `preShipChecks`, `preCommitWiringChecks` | `[]` — a repository names these for itself, deliberately; see the defaults reference for why empty is a real answer |
| `hierarchyRoles` | Phase C's confirmed mapping |
| `release` | `productionBranch`, `releaseSource`, `autoDeployOnMerge`; `docsRepo` only if the user opted in, and then complete |
| `conventionsDoc`, `itemTagFormat`, `lessonsDoc` | From A8, the answers, and the shipped default path |

**The roster must describe what actually exists.** This is the one place where writing an aspirational
config does real damage, because every later run reads these keys as fact:

- No local review CLI detected → **omit `localCommand`** (or write `null`). The built-in adversarial
  pass is then the local gate, which is a legal configuration, not a degraded one.
- No cloud reviewer → **`automatedReviewers: []`**. Nothing is requested, polled or waited on, and an
  absent review is correct rather than pending.
- **`fastStoryMerges.enabled: true` only when at least one local engine is present.** Under fast
  merges an item gets no pull request and no CI of its own, so the local suites are the only gate it
  receives; enabling it with nothing local behind it merges code that nothing checked.
- Equally, **`fastStoryMerges` needs `verify.test` and `verify.typecheck` set** for the same reason.
  If the interview could not establish them, write `fastStoryMerges.enabled: false` and say why.

Then say what was written and where — and go straight to Phase G. **The run is not finished at the
write.** A config that has never been executed is a plausible-looking file, and the whole point of
Phase G is that plausible is not the bar.

## Phase F — re-running on a repository that already has a config

Setup is re-runnable, and a re-run must never cost someone their hand edits. This path is the
difference between a command people run again and one they run once.

1. **Re-detect everything** — Phases A and C, unchanged.
2. **Diff against the existing file** and propose **only what would change** — a key that already
   matches is not a question. "What would change" is wider than detection: it is every accepted
   detector value that differs, every interview answer that differs (including a docs repository the
   user has just said is gone), and every key missing entirely because it was written by hand or by
   an older version. Restricting the proposal to detected values alone silently drops the other two,
   which is how a stale setting survives a re-run the user thought had removed it.
3. **On acceptance, deep-merge** the accepted keys into the existing document.

What survives a merge, verbatim and unconditionally:

- **Keys setup does not recognize.** They may be newer than this version of the skill, or something
  the repository added on purpose. Either way they are not yours to remove.
- **Every `_`-prefixed key.** Real configs carry `_readme` annotations documenting hard-won reasons
  beside the values they explain. They are documentation, they are load-bearing to whoever wrote
  them, and a rewrite that drops them destroys the reasoning while leaving the config working.
- **Any value setup did not propose changing.** Silence is not consent to revert.

**One deletion is allowed, and only one shape of it:** a key setup itself recognizes, which the
user has explicitly said no longer applies — the sibling docs repository being the case that
actually happens. Leaving a stale `release.docsRepo` in place is not conservative, because the
release skill reads a present one as opt-in and would commit and push to a checkout that is gone.
So remove it, after an explicit answer, and say you did. Everything else stands: never remove an
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
   and falling back to local. Leaving the release source out is easy and expensive: the release skill
   fetches it first thing, so a stale value passes validation and fails at the release. Then assert
   `protectedBranches` still contains base, production and release source — a config that lost one is
   a config with the safety off.
2b. **The GitHub toolchain the delivery half requires.** Unconditional, whatever the review roster
   says: an `origin` remote exists **by name**, its host is GitHub, and `gh` is installed and
   authenticated for that host. These are not reviewer conveniences — without them the loop cannot
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
6. **The CI ordering is self-consistent** — warn only, never a failure. If the config says pull
   requests open as drafts but no workflow carries a draft gate, the hold cannot work, and the loop
   would wait on CI that already ran. Say so and point at `/devstride:doctor`. **Never edit a
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
- **The write boundary is one path: `.claude/ds-config.json`.** See the top. Everything else on disk is
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
