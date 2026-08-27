---
name: setup
description: Set the delivery loop up for this repository — inspecting it for everything answerable without asking (package manager, verify commands, CI provider and draft gating, branches, review engines), mapping your DevStride work types onto the loop's roles, asking only about what is left, and writing .claude/ds-config.json, which a re-run merges into rather than overwrites.
user-invocable: true
disable-model-invocation: true
---

Set the delivery loop up for **this** repository and DevStride organization: inspect (A),
report (B), map work types onto roles (C), ask what is left (D), write (E) — or merge into an
existing config (F) — then prove it by running it (G).

Optional argument: $ARGUMENTS

- **`validate`** — skip to Phase G on the config already there; nothing asked or written.
  **Run A1 first even so** — Phase G assumes the repository root.
- **A detector name** — `ecosystem` (A2–A3), `verify` (A4), `ci-inspect` (A5), `branches` (A6),
  `engines` (A7) — inspect and report just that part. (`ci-inspect`, not `ci`: the bare word is
  the write mode; one token means one thing.)
- **`docs`** — the documentation-hooks mode, the one narrowed run that WRITES: A1 + A8, Phase
  D's three documentation questions plus `release.deployVerification`, then write **only** the
  `docs` block and that key (create-with-just-those-keys or Phase F merge, `release.docsRepo`
  migration included), scaffold E2, run Phase G check 7 alone.
- **`ci`** — the CI-cost mode, the second narrowed run that WRITES, and the only mode that
  touches a workflow file: A1 + A5; detect which of the four mechanics in
  `${CLAUDE_PLUGIN_ROOT}/skills/setup/references/ci-cost-patterns.md` each pull-request
  workflow carries; show the **exact diff** per mechanic missing OR present-but-inert; apply
  only accepted diffs — nothing else rewritten. Write `ci.freezeBaseWhileReleasePrReady` and
  `ci.expectedRunsPerPullRequest` if absent. **Draft-gate diffs accepted while the three
  `review.*` CI-ordering booleans are `false` → propose flipping them `true` in the same
  change.** Run Phase G's CI checks. Offer `/devstride:ci-audit` first for numbers.
- **Nothing** — the full run: inspect, ask, write, scaffold, validate.

**Run each mode's prerequisites silently — A1 always, A2–A3 before A4.** A narrowed run reports
fewer keys, never worse ones, **stops after Phase B and writes nothing** (a write would fill
every unexamined key with a default); a full `/devstride:setup` is what writes. **`docs` and
`ci` are the exceptions by design** — each writes exactly the keys its own questions answer.

**The write boundary — the whole of it**: `.claude/ds-config.json`; in E2 only, the scaffolded
skills (never overwriting); in `ci` mode only, the pull-request workflows under
`ci.workflowGlobs` (each change a diff, applied on an explicit yes). Nothing else, ever — no git
mutation, no installs, no DevStride **write** tool. **Phases A–D are strictly read-only**:
`git status --porcelain` stays byte-identical until the write.

## Why detection comes before questions

**Detect before you ask — and never guess**: a wrong detected value arrives wearing the
authority of evidence. Three outcomes; the third is not a failure:

| Status | Meaning | Later |
|---|---|---|
| `detected` | One unambiguous answer, with evidence | A prefilled default |
| `ambiguous` | Several plausible answers, or one needing confirmation | A question offering the candidates |
| `unknown` | The repository does not answer this | A question with no prefill |

Every row carries the evidence that produced it — a row without evidence is a guess with a
status attached.

## Ground rules for every detector

- **Anchor to the repository root** (`git rev-parse --show-toplevel`), never the working
  directory.
- **Match names exactly; never substring** — `test:watch` and `pretest` are not the test command.
- **Prefer local, offline evidence**; network git commands are fallbacks — a stall means
  `ambiguous` with that reason.
- **Not on `PATH` may be a shell alias or function** — report "not on `PATH`", never "absent".
- **Say when a check could not be run** — never a pass, never an absence.

## Phase A — inspect

### A1. Repository and remote

Confirm a git work tree (stop if not). `git remote get-url origin` — `origin` **by name** (the
delivery skills hardcode it); other remotes only → say which, mark every branch key `ambiguous`.
Record the forge host — **the delivery half assumes GitHub and GitHub Actions**; say plainly
when it is anything else.

### A2. Ecosystem and package manager

Lockfile at the root: `pnpm-lock.yaml` → pnpm · `yarn.lock` → yarn · `package-lock.json` → npm ·
`bun.lock`/`bun.lockb` → bun. More than one manager → `ambiguous`, listing all; **never silently
pick** (same-manager pairs are not ambiguity). `package.json`, no lockfile → read its
`packageManager` field: present → `detected`; contradicting a lockfile → `ambiguous`, showing
both; neither → `unknown`. No `package.json` → non-Node: fingerprint `Cargo.toml`, `go.mod`,
`pyproject.toml`, `Gemfile`, `Makefile`; record the ecosystem, mark every `verify.*` key
`unknown`.

### A3. Workspace layout

Before A4. pnpm: `packages:` globs in `pnpm-workspace.yaml`. npm/yarn/bun: the `workspaces`
field — **either** an array **or** an object with a `packages` array; handle both. Expand the
globs; **present only workspaces that define scripts you care about**.

### A4. Verify commands

Scan `scripts` in the root `package.json` and each workspace's. Ranked exact-name matches —
**typecheck**: `typecheck`, `check:ts`, `check-types`, `type-check`, `tsc`; **test**: `test`;
**lint**: `lint`. Then:

- **Read what the matched script does** — a body that is a bare `echo`/`exit 1` or runs no tool
  is a placeholder → `unknown`, saying why; never `detected`.
- **Compose as `<pm> run <script>`, always** — the bare form fails in npm; `run` works in all
  four. An existing bare-form config is equivalent, not wrong.
- **`verify.typecheck` is an array** — one `cd <workspace> && <pm> run <script>` per workspace
  that has one (single package → one-element array); propose **every** such workspace.
- **`verify.test` / `verify.lint` are single strings** — several candidates → `ambiguous`,
  offering them; never invent an unrun `&&` chain.
- **`verify.testDir`** — from the runner's config (`include`/`roots`/`testMatch`), else a
  conventional `tests/`, `test/`, `__tests__/` that exists.
- **`verify.testSingle`** — only when the runner is recognizable (vitest/jest:
  `<test command> -- <path>`); else `unknown`.

### A5. CI provider, and the draft gate

`.github/workflows/*.yml|yaml` → **GitHub Actions**, the only provider the draft-hold mechanics
understand. **A convention-only workflow is exempt** — `opened` plus optionally
`converted_to_draft`/`ready_for_review`, one run-only job, no checkout, fails on a non-draft
open (pattern D of `ci-cost-patterns.md`; `opened`-only is a subset). **Remove it from the population BEFORE the five-case table below is
evaluated** — left in, it reads `ambiguous` and Phase G calls it a FAIL.

Judge **only `on: pull_request` workflows**. The hold needs two things: (1) **jobs gated on
the draft condition** (`github.event.pull_request.draft == false` or the `!` form) — a job is
also gated when ANY job it `needs` is gated (unless it overrides with `if: always()` or
similar) — requiring an explicit `if` on the whole closure is the wrong test;
(2) **`on.pull_request.types` carries all four of `opened`, `synchronize`, `reopened`,
`ready_for_review`** — the defaults omit `ready_for_review`, an explicit list **replaces** the
defaults, `opened` is required (`converted_to_draft` optional); short → `ambiguous`, naming the
missing events. The traps: detector-evidence.md §A5.

Five cases; **every one produces all three boolean rows** (`review.openPullRequestsAsDraft`,
`review.readyForReviewReleasesCi`, `review.ciHeldUntilReviewSettled`):

| Pull-request workflows show | The three booleans |
|---|---|
| Draft-gated, explicit `types` naming all four of `opened`, `synchronize`, `reopened`, `ready_for_review` | `true`, `detected` |
| Draft-gated, `types` absent or missing any of the four | `ambiguous` — the hold cannot work as written; point at `/devstride:doctor` |
| None draft-gated | `false`, `detected` — legitimate; say the cost (CI on open and after every fix push) |
| Some jobs gated, others not | `ambiguous` — name the ungated jobs and ask |
| No pull-request workflow | `false`, `detected` — nothing to hold |

**Record, per pull-request workflow, the CI-cost mechanics** (informational rows
`ci.concurrency`, `ci.productionTreeSkip`, `ci.policyCheck`). **`ci.productionTreeSkip` takes
three values** — `present`, `present but inert` (the `HEAD^2` parent is not in the checkout —
depth, or a deepening fetch, judged by effect; `setup ci` then offers the `fetch-depth` diff
alone), `absent`. A step in a job with **no checkout** is a broken workflow, its own finding. A
full run only reports — it never edits a workflow. Any other provider (`.gitlab-ci.yml`, `.circleci/`,
`Jenkinsfile`, `azure-pipelines.yml`) or none: record the name, three booleans `false`,
`detected`. **Nothing provider-specific beyond GitHub Actions.**

### A6. Branches

From git alone — network only as fallback.

- **Enumerate, then reason** — local AND remote branch lists, only `origin`'s refs,
  normalized (prefix stripped, `origin/HEAD` dropped, deduplicated; a fork's `upstream/*` is
  never a candidate); a role resting on only-local or cached evidence is confirmed with
  `git ls-remote --heads origin`, and unconfirmable → `ambiguous`, naming the possibly-stale
  cache. The full enumeration procedure — commands, the default-branch fallback — is
  detector-evidence.md §A6; read it when running this detector.
- **Classify only exact, whole names; never substring or prefix.** Production-role candidates:
  `main`, `master`, `production`, `prod`. Development-role candidates: `develop`,
  `development`, `staging`, `stage`, `canary`, `test`, `testing`, `qa`. `trunk` is a common
  single-trunk name, not proof of a separate production role. Preserve the repository's
  spelling; the lists assign likely roles among branches proved to exist — never the refs to
  probe for, and a name is not proof of what deploys.
- **One exact development + one exact production candidate → all four roles `detected`**
  (`baseBranch` + `release.releaseSource` from the development one; `release.productionBranch`
  + `hotfixBaseBranch` from the production one). List order is NOT a ranking — two names from
  either set → those roles `ambiguous`, showing the matches. `origin/HEAD` supports the
  ordinary PR base — never proof of production, never overriding an exact pair or an explicit
  answer.

**Four keys hang off this — `baseBranch` (where work branches from and merges to),
`release.releaseSource` (what promotes to production, normally `baseBranch`),
`release.productionBranch` (what production deploys from), `hotfixBaseBranch` (what an urgent
fix branches from, normally the production branch). Emit all four on every path** — each has a
shipped default naming a branch this repository may not have. When the pair rule above does not
decide, **read `${CLAUDE_PLUGIN_ROOT}/skills/setup/references/detector-evidence.md` §A6 and
assign per its path table**; the constants: topic branches are never role candidates, a
staging/canary/test/qa branch is never silently promoted to production, and an undecidable role
is `ambiguous` with its candidates shown, never omitted. **Always compute `protectedBranches`
containing the base, production AND release-source branches** — all three even when two are one
ref; an unlisted branch is one the loop treats as disposable. **Detached HEAD** blocks nothing;
**no `origin`** does: branch keys `ambiguous`, with that reason.

### A7. Review engines

**Absent is a finding, not a failure** — an empty roster is legal; the built-in adversarial pass
is then the local gate.

- **Local review CLI** (`review.localCommand`) — the template must carry `<base>` (the ref
  the engine diffs against) and may carry `<context>` (round 2's distilled round-1 outcome on
  stdin; `config-defaults.md`). Probe `command -v codex` and any CLI the user names. Found → a
  candidate, `ambiguous` (model, effort, flags are choices); carry `review.localReviewerName`.
  **Not found → `unknown`, never a detected `null`** — one missed probe is not absence. Report
  what was probed.
- **Cloud reviewers** (`review.automatedReviewers`) — possible when origin is GitHub and
  `gh auth status` succeeds. **An entry is more than a name**: a `requested_reviewer` bot is
  requested by its `graphqlBotId`; missing fields silently request nothing — take the complete
  entry from the defaults reference's catalog, or ask for every field. A positive probe is
  `ambiguous`, never `detected` — only a real pull request settles it. **Setup never settles
  it** — not here, not in Phase G.
- **`gh`** — `gh --version`, `gh auth status`; read the **active** account's line; say when auth
  comes from `GH_TOKEN`/`GITHUB_TOKEN` — it changes the fix.

### A8. Conventions doc, and any existing config

- `conventionsDoc` — `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md` at the root, in that order of
  preference; several → `ambiguous`, listed; none → `unknown`.
- **A pull-request template** → a `prBodyTemplate.sections` row, `ambiguous`, carrying it.
  **Look everywhere GitHub honours, case-insensitively**: `pull_request_template.md` at the
  root, `.github/`, `docs/`, and a `PULL_REQUEST_TEMPLATE/` directory in any of the three.
  **Capture sections as `{heading, guidance}`** — the text beneath each heading is the
  guidance; an empty one becomes a question, not a blank.
- **Read `.claude/ds-config.json` if present**; record each key's current value beside the
  detected one — how a re-run tells a hand-edit from a stale value.
- **Documentation hooks** — rows `docs.updateSkill`, `docs.releaseNotesSkill`; detection is
  limited and the row says so. Existing config: a name whose `.claude/skills/<name>/SKILL.md`
  exists → `detected`; missing directory → `ambiguous` with the dangling name; legacy
  `release.docsRepo` → `ambiguous` (Phase D candidates; Phase F migrates). Signs of a
  documentation system are **candidates, never answers**: a `docs/` directory, `mkdocs.yml`,
  `docusaurus.config.*`, `nuxt.config.*` beside `content/`, `_config.yml`, a `CHANGELOG.md`, a
  `release-notes/` directory. Nothing → `unknown`, not `null`. Contract:
  `${CLAUDE_PLUGIN_ROOT}/skills/release/references/docs-hooks.md`.

### A9. Local environment

Eight rows: `localEnvironment.create`, `.recreate`, `.recreateMode`, `.instanceName`, `.seed`,
`.migrate`, `.teardown`, `.instanceBoundTo`.

- **`recreateMode` is never `detected`** — `"inPlace"` vs `"newInstance"` is what the command
  does, and a wrapper does not say; ask whenever `recreate` is non-null and carries `<name>`,
  explaining both.
- **`instanceName` — only when `recreate` resets in place and carries `<name>`**; propose it
  `ambiguous` (a marker file is the usual source), never `detected`.
- **`recreate` is asked, never inferred** — propose the composition its own
  `create`/`migrate`/`seed` answers imply; the owner confirms; `null` is legitimate.
- Candidate shapes — each `ambiguous` for the row it suggests, never `detected`:
  `docker-compose*.yml|yaml`, `compose.yml|yaml`, `.devcontainer/`, `flake.nix`/`shell.nix`,
  `Tiltfile`/`skaffold.yaml`, root scripts `dev`, `sandbox`, `env:*`, `db:seed`, `db:reset`,
  `migrate`.
- **`instanceBoundTo` is never detected.** Ask, with `directory` (a second worktree gets its own
  instance; checking out another branch inside it keeps that instance's data), `branch`, `none`
  — saying what each means.
- Existing config: record the current block, per A8. Nothing found → rows `unknown`, not `null`
  — only the owner can say "there is none".

**Read `${CLAUDE_PLUGIN_ROOT}/skills/setup/references/detector-evidence.md` when running A5 or
A6, when a detector's result is `ambiguous` and the candidates need explaining, or before
changing a detector.**

## The prefill summary — the contract

One row per configuration key: `key` (dotted path), `value` (in the key's shape; `null` when
nothing was detected), `evidence` (the file read or command run — never empty), `status`
(`detected` / `ambiguous` / `unknown`), `candidates` (only when `ambiguous` — every plausible
answer), `existing` (only when the config already sets the key). **This shape is the contract**:
every `detected` row becomes a prefilled default, every `ambiguous`/`unknown` row a question —
and a key that produced no row is a key nobody looked at, distinguishable from a key with no
answer.

## Phase B — report what was found

Group the summary as it is read — detected / needs a decision / undetermined — leading with
counts. **On a narrowed run this is the end.** On a full run go to Phase C; Phase D's bulk
confirmation is where detected values get sign-off.

## Phase C — map the organization's work types onto the loop's roles

`hierarchyRoles` has two roles: **`releaseUnit`** (string) — the parent-item level whose
completion cuts a release, each getting an integration branch and shipping as one reviewed
increment; **`leaf`** (array) — the executable one-day item types. `Container` is internal
shorthand — say **parent item**, **grouping item**, or the actual work type name.

**Read them from the organization; never assume canonical spellings** —
`get_workspace_context` establishes WHICH organization is connected (name it); whatever
`get_work_type_hierarchy` then returns is the truth, misspellings included. Propose from structure
(childless bottom types → `leaf`; the level above → `releaseUnit`); confirm with
`AskUserQuestion` even when obvious. More or fewer levels than assumed → ask which level is the
release boundary (two roles, not a level count); a single work type doing everything → map it to
both roles, every item its own release unit, no batching.

**DevStride connection unavailable**: the bundled server contributes no tools until signed in —
a symptom, not an error; `/mcp` is where sign-in happens. Two paths: continue without it (write
with `hierarchyRoles` omitted, reported as required follow-up) or stop and resume. **Never guess
the roles** — absent is visible; wrong silently matches nothing.

## Phase D — ask only what is left

**Every `ambiguous`/`unknown` row is a question** (`AskUserQuestion`) — an `ambiguous` row
offers its candidates, likeliest first; an `unknown` row has no prefill, so ask plainly and say
what the value is for. **`detected` rows are confirmed in bulk** — one list WITH each row's
evidence, one yes. **An explicit answer always beats a detection** — the override is written,
never re-applied.

Four things no inspection can reach, asked every run — the first one first:

- **Which delivery profile?** (`profile`) — three options captioned from the contract's table
  (`${CLAUDE_PLUGIN_ROOT}/skills/plan/references/delivery-profiles.md` — read it before
  asking): `prototype`, `standard` (default, first), `enterprise`; say what the answer moves
  (`epicIntegrationBranches.autoRelease`, `fastStoryMerges.enabled`,
  `review.pollTimeoutMinutes`); on a re-run the file's `profile` is the prefill. **If
  `prototype`, say the consequence now**: `autoRelease` becomes `true` — a release unit merges
  to `baseBranch` with no human saying so; name the branch. The profile is never `detected`.
- **What does merging to the production branch actually do?** (`release.autoDeployOnMerge`) —
  one plain-English sentence; the release skill quotes it back at the production gate. Nothing
  can detect it; no sensible default exists.
- **Documentation — three questions, together** (`docs.*`): (1) **where it lives** — a
  directory here, a sibling checkout (path + branch), a hosted service (URL), or "nowhere" →
  `docs.updateSkill: null`, skip (2), say the docs pass will report itself skipped, **still ask
  (3)** — the hooks are independent; (2) **how it is updated** — publishing branch / pull
  request / tool / person (the skill then hands them the delta) — capture what makes "publish"
  concrete; (3) **how release notes are pushed** — "we do not publish" →
  `docs.releaseNotesSkill: null`, saying that `--release-notes` will then report itself
  unavailable. Then the skill **names** (defaults `update-documentation`,
  `update-release-notes`) and — separately, optional — **`release.deployVerification`** (exits
  0 only when production serves the commit in `RELEASE_COMMIT`; say what it buys; never invent
  one). Answers go into the E2 scaffolds, not the config; contract:
  `${CLAUDE_PLUGIN_ROOT}/skills/release/references/docs-hooks.md`. **Release notes are opt-in
  per release** — no "warranted" policy; the owner passes `--release-notes`.
- **Where the lessons store lives**, if not the default path. **Never offer to create the file**
  — the store has a single writer, and it is not this skill. Write the key, nothing else.

**Read `${CLAUDE_PLUGIN_ROOT}/skills/setup/references/interview-rationale.md` when a Phase C/D
answer needs justifying, or when a re-run (Phase F) proposes removing or migrating a key.**

## Phase E — write the config

One write, after every confirmation, of the whole document. Values from detection, Phase C, or
Phase D; else the shipped default — present-with-default is inspectable, absent is invisible.
`${CLAUDE_PLUGIN_ROOT}/skills/setup/references/config-defaults.md` holds every default —
**read it before writing and copy verbatim**; the delivery skills compare these strings
literally.

| Key | Value |
|---|---|
| `baseBranch`, `hotfixBaseBranch`, `protectedBranches` | From A6; `protectedBranches` **always** holds base, production, release-source |
| `integrationBranch` | `null` — per-release-unit derivation is the default |
| `profile` | The Phase D answer, the word itself — always written, `standard` included |
| `epicIntegrationBranches` | Verbatim from the defaults reference; `autoRelease` at the profile's value; `fastStoryMerges.enabled` per below |
| `verify` | `typecheck` (array), `test`, `lint`, `testSingle`, `testDir`, `skipDuringStoryBuilds: []` |
| `generated` | Only when detected — omit an empty shape |
| `review` | The roster + three CI-ordering booleans per the rules; `pollTimeoutMinutes` at the profile's value |
| `prBodyTemplate`, `commitConventions`, `ci`, `branchNaming` | Verbatim from the defaults reference unless the repository said otherwise — `ci` includes `freezeBaseWhileReleasePrReady: true`, `expectedRunsPerPullRequest: 1` |
| `preShipChecks`, `preCommitWiringChecks` | `[]` — a repository names these for itself |
| `hierarchyRoles` | Phase C's confirmed mapping |
| `release` | `productionBranch`, `releaseSource`, `autoDeployOnMerge`, `deployVerification` (`null` unless given). Never `docsRepo` — retired; Phase F migrates |
| `docs` | `updateSkill`, `releaseNotesSkill` — the names E2 scaffolds, or `null`; `updateOnEpicRelease: false` |
| `conventionsDoc`, `itemTagFormat`, `lessonsDoc` | From A8, the answers, and the shipped default path |
| `plugin` | Verbatim — `updateCheck: true`, `autoUpdate: false`, `pin: null`. Not asked |
| `localEnvironment` | The eight A9 keys. Write the block even when every command is `null` — absent reads as "nobody asked" |

**The roster must describe what actually exists** — later runs read these keys as fact. No
local CLI detected → **omit `localCommand`** (or `null`). No cloud reviewer →
**`automatedReviewers: []`**. **`fastStoryMerges.enabled`, precondition by profile**:
`standard`/`enterprise` → `true` only with a local CLI engine on the roster *and* `verify.test`
and `verify.typecheck` set; `prototype` → `true` whenever `verify.typecheck` is set (the exact
rule is in the defaults reference — apply, do not re-derive); unmet → `false`, saying which part
was missing and, under `prototype`, that the file now contradicts its profile. **`autoRelease`
and `review.pollTimeoutMinutes` take the profile's values** — `autoRelease: true` for
`prototype` repeats the consequence at the write, naming `baseBranch`.

Say what was written; go to E2, then G. **The run is not finished at the write.**

## Phase E2 — scaffold the local documentation skills

From `${CLAUDE_PLUGIN_ROOT}/skills/setup/references/docs-skill-templates/`:
`.claude/skills/<docs.updateSkill>/SKILL.md` from `update-documentation.md` and
`.claude/skills/<docs.releaseNotesSkill>/SKILL.md` from `update-release-notes.md` — only for
hooks not answered "nowhere"/"we do not publish". Fill every `{{PLACEHOLDER}}` from the Phase D
answers (legacy `release.docsRepo` values answer the first two); frontmatter `name` = the
directory name; **leave no placeholder unfilled**. **Never overwrite an existing skill** — say
so instead. Confirm the files are not gitignored (`git check-ignore` exits 1). Say what was
written, that each skill's `check` mode is what Phase G and `/devstride:doctor` run, and that
the skills are the owner's to refine.

## Phase F — re-running on a repository that already has a config

A re-run must never cost someone their hand edits.

1. **Re-detect everything** — Phases A and C, unchanged.
2. **Diff against the existing file; propose only what would change** — wider than detection:
   every accepted detector value that differs, every interview answer that differs (including a
   hook the user just said no longer applies), every key missing because it was written by hand
   or an older version. `profile` is a recognized key: the file's value prefills the question; a
   changed answer proposes the profile **together with** the three keys it moves, as one change;
   a kept hand-set `autoRelease`/`pollTimeoutMinutes` is an explicit choice — say the file now
   disagrees with its profile, as `/devstride:doctor` will. No `profile` → ask and propose the
   addition.
3. **On acceptance, deep-merge** the accepted keys — then E2 for any hook the merge introduced
   or migrated, then G.

Survives verbatim, unconditionally: **unrecognized keys**; **every `_`-prefixed key**
(`_readme` annotations are load-bearing); **any value setup did not propose changing** (silence
is not consent). **One deletion is allowed**: a recognized key the user explicitly said no
longer applies (typically a documentation hook whose system is gone) — set it `null` and say so.
**The legacy `release.docsRepo` block is the one migration** — propose as one change: scaffold
from its values (E2), write the `docs` block, remove it; on refusal leave it, saying the release
skill will report it deprecated. Never rewrite the file to normalize shape; never treat a
missing key as deliberate — propose the addition. **Setup authors this file; it is not a
precedence layer** — the file wins over shipped defaults, including anything setup itself
wrote.

## Phase G — prove the config by running it

**A config is not done until it has run.** Phase G runs automatically after every write, and on
its own against a config setup did not write. **Validation reads the file, not any memory of
writing it**; unrecognized keys are ignored. **Read
`${CLAUDE_PLUGIN_ROOT}/skills/setup/references/validation-checklist.md` when you run this
phase** — it holds each check's full procedure, its run rules, and the failure-mode table
(symptom, cause, exact fix); map every failure to its row rather than improvising.

**Run every check, even after one fails.** Each ends `PASS`, `FAIL`, `SKIPPED` (by the user) or
`UNVERIFIABLE` (offline, or a prerequisite absent) — the last two are **not** failures:

1. **Verify commands run** — every `verify.typecheck` entry and `verify.lint`; exit 0 passes
   (`generated.toleratedTypeErrors` in `generated.paths` excepted). **`verify.test` is offered,
   never forced** — declining is `SKIPPED`, reported. The checklist's run rules govern echoing
   hand-typed commands and asking before anything that looks like it writes.
2. **Branch refs exist** — `git rev-parse --verify` all four role keys, preferring the
   remote-tracking ref and falling back to local (a fresh clone has few local branches), **then
   confirm against
   the remote** (`git ls-remote --heads origin`; no network → `UNVERIFIABLE`, naming the
   possibly-stale cache). Assert `protectedBranches` still holds base, production and release
   source — a config that lost one has the safety off.
2b. **The GitHub toolchain** — unconditional: `origin` **by name**, host GitHub, `gh`
   authenticated **with write access** (scopes + `gh api repos/{owner}/{repo} --jq .permissions`;
   read-only → `FAIL`, fix `gh auth refresh -s repo,read:org`). Non-GitHub host → `FAIL`, not a
   warning: the delivery half has no adapter; the planning half works.
3. **Declared review engines respond** — only what the config declares. Local CLI: probe the
   binary, get a version. Cloud: `gh auth status` + repository read — **saying what that does
   not prove**: only a real pull request settles whether a request registers.
4. **Work-type roles still resolve** — every `hierarchyRoles` name still in the hierarchy
   (renames fail silently: the loop matches nothing, every item becomes a one-off). Connection
   unavailable → Phase C's message, `UNVERIFIABLE`.
5. **The lessons store has somewhere to live** — the `lessonsDoc` parent directory exists and is
   writable; **setup never creates the file** — missing is the normal state.
6. **CI ordering is self-consistent** — warnings (drafts configured but nothing gated; missing
   `concurrency`; tree skip absent or `present but inert` — `/devstride:setup ci` applies the
   fixes) except one **`FAIL`**: a draft-gated workflow whose trigger cannot rerun it — `types`
   absent or missing any of the four events (a convention-only workflow never reaches this
   check); a fix push then starts nothing — not loop-ready, whatever else passes. Point at
   `/devstride:doctor` either way. **Never edit a workflow to fix it.**
7. **Documentation hooks respond** — only when set (absent/`null` → `N/A`, said so): the skill
   file exists (missing → `FAIL`, fix `/devstride:setup docs`), its `check` mode runs and its
   verdict is taken; no `check` mode → `FAIL` naming the template. A `release.docsRepo` block →
   `FAIL` naming the Phase F migration. `release.deployVerification` set → confirm its first
   token resolves; do not run it.

**The verdict is the output**: every check with its outcome, then one line — **loop-ready** only
with zero failures; skips and unverifiables are fine, named. Say when **the working tree was
dirty** (the likelier typecheck culprit) and when **the run was offline**.

IMPORTANT:
- **The write boundary is `.claude/ds-config.json`, the E2 scaffolds, and — in `setup ci` only,
  on acceptance — the pull-request workflows.** Everything else is read-only in every phase;
  Phase G runs the repository's own verify commands, asking first where a write looks likely.
- **Never report a guess as `detected`** — the status column is all that stands between a
  detected value and a fabricated one.
- **Absence is information** — no local CLI, no cloud reviewer, no CI provider are real findings
  with real values, not gaps to fix.
- **Never write a config that claims an engine the repository does not have** — an aspirational
  roster quietly changes what gets reviewed.
- **A written config is not a finished one** — Phase G decides.
