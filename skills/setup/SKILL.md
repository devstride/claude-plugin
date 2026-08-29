---
name: setup
description: Set the delivery loop up for this repository — inspecting it for everything answerable without asking (package manager, verify commands, CI provider and draft gating, branches, review engines), mapping your DevStride work types onto the loop's roles, asking only about what is left, and writing .claude/ds-config.json, which a re-run merges into rather than overwrites.
user-invocable: true
disable-model-invocation: true
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

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

`.github/workflows/*.yml|yaml` means GitHub Actions, the only supported hold. Read
`${CLAUDE_PLUGIN_ROOT}/skills/setup/references/detector-evidence.md` §A5 and
`ci-cost-patterns.md`. Remove convention-only workflows BEFORE judging `on: pull_request`:
one run-only/no-checkout job on `opened` (optionally draft/ready events) that enforces draft open.
For the rest require (1) every expensive job draft-gated directly or through `needs` (unless it
overrides with `always()`), and (2) explicit `opened`, `synchronize`, `reopened`,
`ready_for_review` trigger types. Name missing events/jobs.

Five cases; **every one produces all three boolean rows** (`review.openPullRequestsAsDraft`,
`review.readyForReviewReleasesCi`, `review.ciHeldUntilReviewSettled`):

| Pull-request workflows show | The three booleans |
|---|---|
| Draft-gated, explicit `types` naming all four of `opened`, `synchronize`, `reopened`, `ready_for_review` | `true`, `detected` |
| Draft-gated, `types` absent or missing any of the four | `ambiguous` — the hold cannot work as written; point at `/devstride:doctor` |
| None draft-gated, one or more PR workflows | `ambiguous` — not loop-ready: CI starts before review and after fix pushes; offer `/devstride:setup ci` |
| Some jobs gated, others not | `ambiguous` — name the ungated jobs and ask |
| No pull-request workflow | `false`, `detected` — nothing to hold |

Record per workflow `ci.concurrency`, `ci.productionTreeSkip` (`present` / `present but inert` /
`absent`) and `ci.policyCheck`; a no-checkout step is its own fault. Full mode only reports.
Any other provider (`.gitlab-ci.yml`,
`.circleci/`, `Jenkinsfile`, `azure-pipelines.yml`) records the name and three booleans `false`,
`unknown` — the plugin cannot promise CI-last there. No CI records `false`, `detected` and N/A.
**Nothing provider-specific beyond GitHub Actions.**

### A6. Branches

Read `detector-evidence.md` §A6. Enumerate normalized local + `origin` refs; confirm cached/local
evidence with `git ls-remote`, else `ambiguous`. Match whole names only: production candidates
`main|master|production|prod`; development candidates
`develop|development|staging|stage|canary|test|testing|qa`. One of each detects all four roles:
development → `baseBranch` + `release.releaseSource`; production →
`release.productionBranch` + `hotfixBaseBranch`. Multiple candidates are ambiguous; list order
never ranks, `origin/HEAD` never proves production, topic branches never qualify, and staging is
never silently promoted. Emit all four keys on every path. `protectedBranches` always includes
base, production and release source. No `origin` makes branch roles ambiguous; detached HEAD does
not.

### A7. Review engines

**Absent is a finding, not a failure** — an empty roster is legal; the built-in adversarial pass
is then the local gate.

- **Local review/support CLI** — probe `command -v codex` and any CLI the user names. A review
  template must accept either `<context>` on stdin (preferred: every cycle receives scope + the
  cumulative ledger) or `<base>`; `<effort>` enables task-sized reasoning. For Codex, offer the
  context-first read-only template from `config-defaults.md` as both `review.localCommand` and
  optional `review.localAssistCommand`; it leaves model choice to operator/managed config and
  disables the DevStride MCP. Found → `ambiguous` until confirmed; carry
  `review.localReviewerName`. Existing base-only/literal-effort commands remain supported but
  get a migration proposal, never a silent rewrite. **Not found → `unknown`, never detected
  `null`** — report what was probed.
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

### A10. Deployment stage

Rows: `stage.resolve`, `stage.productionStages`. Nothing found → unknown; ask whether this repo
deploys per-environment infrastructure, accepting null. SST/serverless/Pulumi/Terraform/env-script
signals are ambiguous candidates, never detection; read detector-evidence §A10. `resolve` must be
cheap, quiet and preferably read a marker. When non-null, always ask `productionStages`; empty is
valid. Never confuse this read-only cloud stage with the mutable LOCAL `localEnvironment`. Record
existing config per A8.

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
- **Documentation, asked in dependency order** (`docs.*`): first ask **where it lives** — a
  directory here, a sibling checkout (path + branch), a hosted service (URL), or "nowhere" →
  `docs.updateSkill: null`. When it exists, next ask **how it is updated** — publishing branch /
  pull request / tool / person — and capture what makes "publish" concrete. Then separately ask
  **how release notes are pushed**; "we do not publish" → `docs.releaseNotesSkill: null`, so
  `--release-notes` reports itself unavailable. Then ask for the skill **names** (defaults
  `update-documentation`, `update-release-notes`) and, separately and optionally,
  **`release.deployVerification`** (exits 0 only when production serves `RELEASE_COMMIT`; explain
  its value; never invent one). Answers go into the E2 scaffolds, not the config; contract:
  `${CLAUDE_PLUGIN_ROOT}/skills/release/references/docs-hooks.md`. **Release notes are opt-in
  per release** — no "warranted" policy; the owner passes `--release-notes`.
- **Whether to write the repository a status line** — one yes/no, every run. It renders
  `Model · Effort · Repo · Checkout · Branch · Stage · PR`; the segment worth naming when asking is
  **Checkout** (main checkout vs linked worktree — the loop puts epic work in worktrees, so this
  stops being obvious exactly when it starts to matter). Say it writes `.claude/statusline.sh` and
  the `statusLine` setting, both the owner's to edit afterwards, and that declining changes nothing
  else. Written in E3.
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
| `plugin` | Verbatim — `updateCheck: true`, `autoUpdate: true`, `pin: null`; automatic mutation is project/local-scope only |
| `stage` | The two A10 keys — `resolve`, `productionStages`. Write the block even when `resolve` is `null`: absent reads as "nobody asked", and most repositories legitimately have no stage |
| `localEnvironment` | The eight A9 keys. Write the block even when every command is `null` — absent reads as "nobody asked" |

**The roster must describe what actually exists** — later runs read these keys as fact. No
local CLI detected → **omit `localCommand`** (or `null`). No cloud reviewer →
**`automatedReviewers: []`**. **`fastStoryMerges.enabled`, precondition by profile**:
`standard`/`enterprise` → `true` with `verify.test` and `verify.typecheck` set; `prototype` →
`true` whenever `verify.typecheck` is set (the exact
rule is in the defaults reference — apply, do not re-derive); unmet → `false`, saying which part
was missing and, under `prototype`, that the file now contradicts its profile. **`autoRelease`
and `review.pollTimeoutMinutes` take the profile's values** — `autoRelease: true` for
`prototype` repeats the consequence at the write, naming `baseBranch`.

Say what was written; go to E2, then E3, then G. **The run is not finished at the write.**

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

## Phase E3 — write the status line

Only when Phase D said yes. Copy
`${CLAUDE_PLUGIN_ROOT}/skills/setup/references/statusline.sh` to `.claude/statusline.sh`,
`chmod +x` it, and MERGE into `.claude/settings.json` — never replace the document:

```json
{ "statusLine": { "type": "command", "command": "bash .claude/statusline.sh", "padding": 0 } }
```

**Copy it verbatim — nothing is substituted.** It is repo-agnostic and reads the consuming
repository's config at runtime for `stage.*`, which is what lets one file serve every repository
and makes re-copying it safe; a `{{PLACEHOLDER}}` edited in is a bug, not a customization.

**Never overwrite an existing `.claude/statusline.sh`** — the owner may have edited it or written
their own. Say it is already there and leave it.

Then prove it runs, because a status line fails silently — Claude Code renders nothing and reports
no error:

```bash
printf '{"workspace":{"current_dir":"%s"}}' "$PWD" | bash .claude/statusline.sh; echo
```

Non-empty output is the pass. Confirm neither file is gitignored (`git check-ignore` exits 1) — a
status line only one machine has is the commonest fresh-clone surprise — and say both are the
owner's to edit.

Then **look at which segments that render actually produced**, and ask about the structurally
absent ones — in practice `stage`, the only blank whose cause is genuinely ambiguous. Answers
either write config (`stage.resolve`) or record `statusLine.hiddenSegments`; an unanswered question
writes nothing. The segment table, the transient-versus-structural split and the exact question are
in `${CLAUDE_PLUGIN_ROOT}/skills/setup/references/statusline-segments.md`.

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

1. **Verify** — run every typecheck + lint, applying only configured generated tolerances; offer
   `verify.test` (decline = reported `SKIPPED`). Follow the checklist's write-risk prompts.
2. **Branches** — verify all four roles locally/remote, prefer remote-tracking, confirm with
   `ls-remote` (offline = `UNVERIFIABLE`), and require protected branches to include base,
   production and release source.
2b. **GitHub** — require `origin`, GitHub host, authenticated `gh`, scopes and repository write
   permission. Read-only/non-GitHub = `FAIL`; the checklist gives the exact auth repair.
3. **Declared review engines respond** — only what the config declares. Probe the binary/version
   for `review.localCommand` and `review.localAssistCommand`; validate its placeholders, and for
   known Codex confirm `exec`, `--sandbox`, and the configured effort tiers from help without
   spending a model call. Cloud: `gh auth status` + repository read — **saying what that does
   not prove**: only a real pull request settles whether a request registers.
4. **Work types** — every `hierarchyRoles` name still resolves; connection unavailable is
   `UNVERIFIABLE` with Phase C's message.
5. **The lessons store has somewhere to live** — the `lessonsDoc` parent directory exists and is
   writable; **setup never creates the file** — missing is the normal state.
6. **CI ordering is self-consistent.** No PR workflow → N/A. Any expensive PR workflow without
   the draft hold → **FAIL**: the loop cannot keep CI last; fix `/devstride:setup ci`. Also FAIL a
   draft-gated workflow whose `types` omit any of `opened`, `synchronize`, `reopened`,
   `ready_for_review` (a convention-only workflow is excluded). Missing `concurrency` and a tree
   skip absent/`present but inert` remain cost warnings. **Never edit a workflow in a full or
   validate run; only `setup ci` may apply an accepted diff.**
7. **Docs hooks** — null = N/A; otherwise require the skill + passing `check` mode. Legacy
   `release.docsRepo` fails with the Phase F migration. Probe but do not run deploy verification.

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
