# Changelog

All notable changes to this plugin are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). See [RELEASING.md](RELEASING.md)
for what each version component means here and how a release is cut.

## [Unreleased]

### Fixed

- **Review step 7.3 has a remedy for the GitHub mergeability stall that actually works.** When a
  ready flip starts no run and the pull request reads `mergeable_state: unknown` with no merge
  commit, close+reopen does not clear it (observed twice, including on this repository's own
  pull request #7): GitHub creates no runs at all — not even skipped ones — for existing heads,
  repo-wide. What clears it is a NEW head. The skill now escalates in order — close+reopen, then
  ONE empty commit (`git commit --allow-empty`) when the stall persists ~60 s later — bounded to
  one per settle, then stops and surfaces a GitHub-side incident instead of looping. An empty
  commit does not change the patch, so no re-review fires. Invariant F7 and needles pin it;
  `build-item` and step 7.5 point at the escalation instead of restating close+reopen
  (invariants total 101 → 104: F7 plus the new section S).
- **`doctor` no longer reports a finding on a correctly configured draft-convention check** —
  1 finding on such a repository before, 0 after. The
  "convention-only workflow" exemption in `doctor` §5, `setup` A5 and validation check 6
  recognised only the `opened`-only shape; the better shape subscribes to `opened`,
  `converted_to_draft` and `ready_for_review` so a failure at a non-draft open is superseded by a
  pass on the same SHA when the person converts to draft. The definition now lives once, under
  pattern D of the CI cost patterns (opened plus optionally those two events, never
  `synchronize`; one run-only job, no checkout, fails on a non-draft open, passes otherwise), and
  the workflow is removed from the population before the four-events, concurrency and draft-gate checks. The
  `opened`-only shape stays exempt as a subset.
- **Pattern C's tree-identical skip could silently never fire.** The checkout must use
  `fetch-depth: 2` AND the step must `--deepen=1` the production ref: a depth-1 checkout leaves
  `HEAD` a shallow boundary that a later `--depth=2` fetch may not deepen, so `HEAD^2` never
  resolves and the promotion is re-tested every time. The snippet and prose say so.

### Changed

- **`ci.expectedRunsPerPullRequest` is read per workflow, not as an aggregate.** A full-stack
  pull request legitimately executes several workflows once each; 1.2.0 reported that as
  "5 executed runs; expected 1". `review` step 8 now reports one line per workflow that executed
  and names a SECOND run of the SAME workflow as the excess, with a fourth cause — the empty
  re-trigger commit above, an excess only when that workflow had already executed. `ci-audit`
  classifies per (pull request, workflow) and its headline ratio is executed runs over the
  distinct workflows that executed per pull request; `doctor`'s run-once line uses the same
  ratio. No config change is needed: the key's name, type and default are unchanged.
- Pattern D (the draft-convention check) is now the three-event shape shown in
  `ci-cost-patterns.md`; repositories on
  the older `opened`-only shape can re-copy it to get the pass-on-conversion behaviour.

## [1.2.0] — 2026-08-26

### Added

- **`localEnvironment` config block** — `create`, `seed`, `migrate`, `teardown` (a command or
  `null` each) and `instanceBoundTo` (`directory` / `branch` / `none`): how a repository stands up
  an isolated local instance, if it can. `setup` gathers candidates and asks (detector A9);
  `doctor` reports the block and probes its commands; `branch-hotfix` reads `migrate` then `seed`
  instead of asking every time. `build-item`'s serial-execution rule is restated against what
  actually constrains it — shared test infrastructure and production writes — rather than against
  the assumption that every repository has exactly one working tree and one database, an
  assumption a per-checkout instance quietly breaks.

- **The plugin tells you when it is behind.** A `SessionStart` hook (`hooks/version-check.sh`)
  compares the version *this session is running* — read from the loaded copy, not from disk —
  against the newest release tag, and prints the two exact update commands (with the installed id
  and scope it read, never assumed) when a newer one exists. Silent when current or offline: it
  speaks only when there is something to do. Never blocks a session, never exits non-zero; the
  network call is capped at five seconds and cached for six hours. `doctor` reports when it last
  ran and what it found. New config block `plugin` — `updateCheck` (default `true`), `autoUpdate`
  (default `false`: apply at session start and ask for a restart — the only safe moment, since a
  mid-loop update would change skill behaviour between build steps), `pin` (hold a version
  deliberately; reported once, never nagged). `DEVSTRIDE_PLUGIN_UPDATE_CHECK=0` disables it.
- `doctor`'s version-currency recipe moved to `skills/doctor/references/version-currency.md`, the
  one place the hook and the skill both cite.

### Changed

- **Verification names its path.** A verdict that rests on having looked — a browser, a running
  service, a manual run — now reports "verified X via path Y" and lists the routes to the same
  state that were not tried; a bare "verified" is under-specified. `ultracode-build` phase 3
  states the rule in full (and its tests/false-green lens now flags a fix verified on one path
  to a state other paths reach); `review` step 4 applies it at triage. Written after a UI fix
  passed every automated gate, was confirmed by opening the link, and shipped with a hole on two
  routes nobody had named.

### Fixed

- `RELEASING.md` described this repository as a port target whose skill text is overwritten from
  an upstream copy. That predates the dogfood cutover; this repository is the source of truth and
  is edited directly.

## [1.1.0] — 2026-08-26

### Added

- **`ci-audit` skill.** Measures what CI actually costs, from `gh` alone: executed workflow runs
  per pull request (the design is one), post-merge push minutes by branch, release pull requests
  re-run by a moving base, and the named offenders with their likely cause. Runs, not minutes,
  are what the Actions usage page counts — and a draft-gated run whose jobs all skip is the gate
  working, not a cost — so the skill counts executed jobs and their minutes.
- **`setup ci`** — an opt-in write mode (like `setup docs`) and the only path by which setup
  touches a workflow: it detects which of four CI-cost mechanics each pull-request workflow
  carries, shows the exact diff for each missing one, and applies only the accepted diffs. The
  mechanics and the measurements behind them are in
  `skills/setup/references/ci-cost-patterns.md`: the draft gate; per-pull-request `concurrency`
  with cancel-in-progress; a tree-identical skip on production-branch pushes (a promotion merge
  has the same tree the base branch just tested); a check that fails a non-draft pull request
  opened by a person, with the convention in the message.
- Config keys `ci.freezeBaseWhileReleasePrReady` (default `true`) and
  `ci.expectedRunsPerPullRequest` (default `1`).

### Changed

- **`release`** settles the release source before cutting (merge or park every ready pull request
  into it), refuses to proceed past the flip while the base moves, and re-checks at the owner
  gate that nothing merged beneath the release pull request. **`build-item`** will not merge into
  the base branch while a ready release pull request exists — it waits for that release to merge.
  Every merge beneath a ready release pull request re-runs its merge preview and stales the
  reviewed diff; on one repository that was 18% of test minutes.
- **`review`** step 8 reports executed CI runs on the pull request it settled against
  `ci.expectedRunsPerPullRequest`, naming the cause of each extra run; a repeat is a lesson.
- **`doctor`** warns (never fails) when a pull-request workflow lacks `concurrency` or a
  production-branch push lacks the tree-identical skip, and reports the last seven days'
  executed-runs-per-pull-request ratio.

## [1.0.0] — 2026-08-26

**Why a major version.** `release.docsRepo` changes meaning — the plugin no longer acts on it —
and `releaseNotesWhen` is retired. Per [RELEASING.md](RELEASING.md), changing what an existing
`.claude/ds-config.json` key means is a MAJOR bump, however small the edit. Migration is one
command: `/devstride:setup docs`.

### Changed

- **`release` no longer writes release notes on its own judgement, and no longer edits
  documentation itself.** The documentation phase now invokes a LOCAL skill in the consuming
  repository (`docs.updateSkill`) with a structured delta payload — what shipped, per item, in plain
  English — and that skill owns where docs live and how they are published. Core documentation is
  still updated by default when a skill is registered (`no docs` suppresses it) — but now only
  after the production merge is confirmed and the deploy verified, so public documentation never
  describes functionality still waiting on the owner's approval. **Release notes are
  opt-in**: `--release-notes true|draft`, default `false`, written in a new post-merge step only
  after the production merge is confirmed and the deploy verified live (`release.deployVerification`
  when configured, otherwise owner confirmation). The `releaseNotesWhen` policy is gone on purpose:
  no skill in the plugin decides that a delta "warrants" a note. `docs only` and a new
  `release-notes only` run either phase alone against an already-shipped release.
- **`setup`** asks three documentation questions — where docs live, how they are updated, how
  release notes are pushed — plus an optional deploy-verification command, and **scaffolds the two
  local skills** from shipped templates (never overwriting one that exists). Its validation phase
  runs each registered skill's read-only `check` mode. A legacy `release.docsRepo` block is offered
  as a one-step migration: scaffold from its values, write `docs.*`, remove the block.
- **`doctor`** gains a `docs` section: each hook's skill exists and is not gitignored, its `check`
  mode passes, a legacy `docsRepo` block is reported, and an unregistered documentation system is
  N/A rather than a failure.

### Added

- Config keys `docs.updateSkill`, `docs.releaseNotesSkill`, `docs.updateOnEpicRelease` and
  `release.deployVerification`. The contract — keys, payload shape, the `update` / `publish` /
  `draft` / `check` modes a local skill must accept — is
  `skills/release/references/docs-hooks.md`; the scaffold templates are
  `skills/setup/references/docs-skill-templates/`.
- `build-item` step 8 can update documentation when a release unit's release pull request merges,
  behind `docs.updateOnEpicRelease` (default `false`). Never release notes.

### Deprecated

- `release.docsRepo`. `release` no longer acts on it: it reports the shape as deprecated, names
  `/devstride:setup docs` as the migration, and runs without docs. `setup` migrates it; `doctor`
  flags it.

## [0.10.0] — 2026-08-25

### Added

- **Delivery profiles.** One user-facing choice — `prototype`, `standard`, or `enterprise` — now
  sets how much rigor the loop spends per unit of work: how finely `plan` slices stories and how
  deep each spec goes, how many readers `ultracode-build` fans out and how wide its adversarial
  review may go, which verified findings are fixed in-story, how many local review rounds `review`
  runs, which local gate a story must hold before it merges, and how long the loop waits for a
  cloud reviewer. The canonical contract is `skills/plan/references/delivery-profiles.md`; every
  skill cites it. Resolution order: an explicit profile word in the invoking skill's arguments →
  a `Delivery profile:` marker line in the plan root's description → `profile` in
  `.claude/ds-config.json` → `standard`. Four config keys that already exist on their own
  (`epicIntegrationBranches.autoRelease`, `fastStoryMerges.enabled`, `review.pollTimeoutMinutes`,
  the three `review.*` CI-ordering booleans) win over a profile default when present. Floors no
  profile removes: one Claude adversarial pass at NARROW or wider on every story; the security
  lens on any diff touching the auth boundary; at least one engine behind a fast merge; a green
  local gate before merge; the full configured roster and CI on the release PR.
- **`profile` and `profileOverrides` config keys.** `setup` asks which profile and writes it, plus
  the profile-consistent values of the derived keys — saying out loud when `prototype` sets
  `autoRelease: true`. `doctor` reports the effective profile, its source, and any key that
  contradicts it.
- **`/devstride:rebalance <root> <profile>`** — the eighteenth skill. Re-slices a live plan's
  NOT-STARTED leaves to a new profile: merges fine stories into vertical slices (or splits coarse
  ones), embeds the absorbed specs in the successor so no detail is lost, archives the absorbed
  originals with a pointer (never deletes), rewires dependency edges, numbers successors with the
  splice convention, rewrites the root marker, and re-dates the not-done items. Shows a
  before/after table and requires sign-off before writing; refuses to run while a build loop is
  active on the same plan.
- **A bounded review loop.** `maxLocalReviewRounds` caps total runs of the local CLI reviewer per
  story (0 / 1 / 2 by profile); after the cap, the last round's findings are fixed without a
  re-review and anything further that is not P1 or security is deferred with a rationale. A
  `fixFloor` (`p1-security` / `likely-important` / `all-confirmed`) decides which verified
  findings are fixed in-story. Verification defaults to REFUTED unless reproducible.
- **Fail-fast cloud-reviewer registration.** A `requestReviews` call must be proven registered
  (the per-reviewer `review_requested` timeline event) within two minutes or that reviewer is
  dropped for the run and reported — never waited out. `review.pollTimeoutMinutes` now bounds
  only the wait for a REGISTERED reviewer's review.

### Changed

- **The default rigor is now `standard`, not what is now called `enterprise`.** Every skill
  previously ran at a single, maximum rigor: up to six readers per story, HIGH-RISK review breadth
  whenever in doubt, every confirmed finding fixed, unbounded re-review rounds, a 20-minute
  reviewer poll. Measured on a real greenfield project that shape cost hours and dozens of review
  agents per story. A repository that wants the previous behaviour sets `"profile": "enterprise"`
  in `.claude/ds-config.json`; a repository with no `profile` key now runs `standard`.
- `review.pollTimeoutMinutes` takes the profile's default (5 / 10 / 20) when absent from config.
- A public consuming repository can keep tracker numbers out of commits and branch names with
  `itemTagFormat: ""` and an integration-branch pattern without `<epic-number>`; the keys already
  tolerated this and the documentation now says so.

## [0.9.0] — 2026-08-18

### Added

- **Repository-aware branch-role suggestions in setup and doctor.** Setup now recognizes exact
  common production branch names (`main`, `master`, `production`, `prod`) and pre-production
  development names (`develop`, `development`, `staging`, `stage`, `canary`, `test`, `testing`,
  `qa`) among branches that actually exist on `origin`. One unambiguous pair is proposed for all
  four delivery roles; multiple matches remain a user decision. Doctor now checks the effective
  configured-or-fallback roles against the remote and prints the concrete mapping setup would use
  when a static `develop` or `master` fallback does not exist. Neither skill guesses from a
  substring, and doctor remains read-only.

### Changed

- **User-facing hierarchy language says “parent item,” not “container.”** Planning and setup retain
  container/leaf as an internal classification, but their prompts and reports now use parent item,
  grouping item, or the organization's actual work type so developers do not mistake a DevStride
  hierarchy node for a Docker container.

## [0.8.1] — 2026-08-18

### Added

- **A check that proves a skill edit dropped no rule** —
  `skills/review/references/delivery-loop-invariants.md`, referenced from `CONTRIBUTING.md`. It
  catalogues 83 hard-won facts these skills encode and carries a runnable grep for whether any has
  gone missing. Run it whenever you edit skill text: compressing or re-wording is exactly when a
  rule disappears along with the paragraph carrying it, and it disappears quietly — the prose still
  reads well, so nothing looks wrong.

  It is candid about its limits, including two it demonstrated on itself while being written: it
  originally read its own catalogue, which made it pass unconditionally, and several needles missed
  on rules that were plainly present under rewritten wording. A miss means *go and look*, never
  *a rule was lost*.

## [0.8.0] — 2026-08-18

### Fixed

- **The draft-gate check failed repositories whose CI hold works.** It counted a job as gated only
  when *every* job in its `needs` closure was gated. GitHub's default job condition requires all
  dependencies to succeed, so one skipped dependency skips the dependent — meaning **any** gated
  dependency is enough. The wrong test rejected exactly the layout it was written for: a cheap gate
  job carrying the draft condition, an ungated utility job beside it, and the expensive job
  depending on both. It also called a job gated when `if: always()` opts it out of that default and
  it genuinely does run on drafts.
- **The trigger-event check had the matching gap.** It required `ready_for_review`, correctly, but
  declaring `types` explicitly *replaces* GitHub's defaults rather than adding to them — so a list
  naming only that event fixes the ready-flip and breaks everything after it. All four events are
  required now, including `opened`, which looks droppable under the draft hold and is not: a
  standalone review on a non-draft pull request skips the flip and settles against CI that, without
  it, was never created.

### Added

- **A `ds` marketplace entry**, pointing at the same plugin, so the install line can be typed as
  `ds@devstride`. Same skills, same version, one manifest — the entry is a name, not a fork.
  **It shortens the install spelling only:** measured on a real alias install, the skill namespace
  comes from the plugin manifest's name, so commands remain `/devstride:<skill>` either way. Install
  one entry or the other, never both — they install as separate plugins from one source, so both
  means two copies on disk and every skill twice.
  Update commands take the id you installed under (`claude plugin list` shows it); the diagnostic no
  longer assumes either name.

## [0.7.0] — 2026-08-18

### Added

- **`/devstride:setup`** — a guided setup command, so a new repository does not start with a blank
  `.claude/ds-config.json` and a reference page. It inspects the repository and works out what the
  config should say — package manager, verify commands, CI provider and its draft gating, branch
  roles, review engines, conventions doc — reporting every value with the evidence behind it and a
  status of `detected`, `ambiguous` or `unknown`, then asks only about what it could not settle.

  **It ends by running what it wrote.** Verify commands are invoked for real, branch refs resolved,
  declared review engines probed, work-type roles re-checked against the organization. Every check
  runs even after one fails, and the repository is called loop-ready only with zero failures —
  skipped and unverifiable are reported as themselves, never folded into a pass. Each failure maps to
  a shipped failure-mode table with the exact fix.

  Built in three phases — inspection, then the interview and write, then this validation pass — with
  **no version bump until the last of them landed**, because `version` is the install cache key and a
  bump partway through would have put a command that stops halfway into everyone's install. That
  constraint is now satisfied: the bump ships with this release.

## [0.6.0] — 2026-08-17

### Added

- **`/devstride:doctor`** — a read-only setup check. Every prerequisite of this loop currently fails
  silently: a missing or unauthenticated `gh`, a DevStride connection whose signed-out symptom is
  *absent tools* rather than an error, a config typo that reads as an unset key, workflow jobs never
  gated on draft (so the review-before-CI design simply never engages), and a test command left
  unset while fast merges make the local suites the only gate. `doctor` reports each with what
  breaks and the command that fixes it, walks every section rather than stopping at the first
  failure, and never changes anything — which is what makes it safe as the first thing you run.

## [0.5.0] — 2026-08-17

### Added

Four config keys existed but nothing read them, so the behaviour they describe was hardcoded to one
repository's conventions. They are now honoured:

- **`itemTagFormat`** — the shape of the work-item tag in commit messages. It was fixed at
  `[I#####]`; a repo whose tracker uses `PROJ-123` can now say so.
- **`review.localReviewerName`** — the local review engine's display name. The skills called it
  "Codex" in every roster announcement regardless of what was actually configured.
- **`epicIntegrationBranches.slugRule`** — how to derive a branch slug from a title. Without it each
  run invented its own slugging, so the same release unit could be named two ways.
- **`epicIntegrationBranches.releaseTarget`** — where a completed release unit lands. It was
  hardcoded to the base branch; a repo that stages releases elsewhere can now point it there.

### Changed

- `push` named `verify.typecheckCombined` in its config header while its step read
  `verify.typecheck`. Both keys exist so nothing broke, but a skill should not name a key it does
  not read. It now reads the array form, with the combined form as an explicit fallback.
- `push` shipped one repository's toolchain as its defaults — a specific package-manager invocation
  and a specific generated file path. Both are gone; the defaults are now the config keys
  themselves, and no monorepo literal remains anywhere in `skills/`.

## [0.4.3] — 2026-08-17

### Changed

- `CONTRIBUTING.md` records four disciplines for editing skills without silently losing rules —
  cut the why before the what; a rationale moved away from its mechanism becomes false; walk the
  config keys both ways; presence is not correctness. Each names a failure this text has actually
  suffered, and each fails without erroring.

## [0.4.2] — 2026-08-17

### Fixed

- **`ultracode-build` cited a config key that does not exist.** It asked for
  `verify.singleTestCommand` when the key is `verify.testSingle`, so the build phase would look up
  a missing key and guess how to run the touched test suite — silently, since an absent key does
  not error. Found by auditing every one of the 50 config keys the skills cite against a real
  config; it was the only mismatch.

## [0.4.1] — 2026-08-17

### Changed

- **This repo is now canonical for the skills.** DevStride's own monorepo has cut over to
  installing the plugin like any other customer, so skill text is developed and released here
  rather than ported in. `CONTRIBUTING.md` updated accordingly — skill pull requests are welcome.

## [0.4.0] — 2026-08-17

### Fixed

Six logic defects in the skills, all pre-existing rather than introduced by packaging, plus the
holes found while fixing them.

- **Pre-ship checks ran after the pull request had already been marked ready and CI had settled**,
  so a failing one forced a fix onto reviewed, tested code and CI re-ran on a patch no engine had
  seen. `review` now supports a caller-declared pre-ship hold (7.1b) with a named `PRE-SHIP RESUME`
  re-entry mode; `pr` and `release` declare it and discharge it at a new step 2c.
- **`push` staged only tracked files**, so a change introducing a new file committed and pushed
  without it while reporting success.
- **`insert-story` / `insert-defect` created an edge-less orphan** when a plan had no selectable
  next item — which `build-item` then classified as unplanned work and shipped straight to the base
  branch. Now distinguishes a finished plan (attach after the last completed item, numbered as a
  dotted splice) from a blocked one (stop and surface it).
- **`rationalize-gantt` could not terminate on a dependency cycle**, the very thing `plan` relies
  on it to catch. It now isolates strongly connected components first and stops before writing any
  date, naming the real cycle members rather than the innocent nodes feeding them.
- **`build-item` demanded a pull-request reference for fast-merge stories that have none**,
  inviting a fabricated one; it now cites the merge commit and integration branch, and the release
  step actually links the release pull request it promises.
- **`build-item` left a stale remote branch** after every fast merge, and now deletes it — only
  once the integration push has succeeded.

### Changed

- `CONTRIBUTING.md`: port a change as a patch, never a file copy. A wholesale copy silently reverts
  the generalizations that make the text repo-agnostic.

## [0.3.4] — 2026-08-17

### Fixed

- **The pinning and unpinning recipes left you with no plugin.** `claude plugin marketplace remove`
  uninstalls every plugin that came from that marketplace, and re-adding the marketplace does not
  bring it back — both recipes now include the required `claude plugin install` step.
- **"Updates are never automatic" was too absolute.** Auto-update is a per-marketplace setting, off
  by default but available in `/plugin` → the marketplace → Enable auto-update. Documented alongside
  the manual path.
- Corrected which safeguard catches a forgotten version bump: it is `claude plugin tag` refusing to
  re-create an existing tag, not its manifest-agreement check — the marketplace entry carries no
  version to disagree with.

### Changed

- The release checklist now validates the skills and both manifests before tagging, pushes `main`
  before the tag (so a public tag can never point at a commit that is not on the branch), re-points
  the changelog's `[unreleased]` link, verifies the release actually installs, and ends with an
  announce step.
- Stated what to do when `Unreleased` is empty.

## [0.3.3] — 2026-08-17

### Fixed

- **Pinning is much simpler than previously documented.** Append `@<tag>` to the marketplace source
  (`devstride/claude-plugin@devstride--v0.3.2`) — the earlier instructions had users cloning a tag
  and adding the directory, which worked but was unnecessary.
- Noted that `claude plugin update` acts on the **user** scope by default, so a project-, local- or
  managed-scope install needs a matching `--scope` or the command reports the plugin isn't installed
  and changes nothing.

### Changed

- The release checklist now covers updating the README's version line and validating both manifests
  separately, so neither can be missed on a future release.
- Clarified the compatibility promise: **new** config keys are a MINOR change; removing, renaming or
  redefining an existing one is MAJOR. The previous wording implied any config-key change was MAJOR,
  contradicting the table beside it.

## [0.3.2] — 2026-08-17

### Fixed

- **The documented update path did not work.** Updates are not automatic: a fresh session leaves an
  installed plugin at its existing version, and refreshing the marketplace reports success without
  touching the install. Upgrading needs `claude plugin marketplace update devstride` **and**
  `claude plugin update devstride@devstride` (fully-qualified — the bare name reports "not found"),
  then a restart.
- The pinning example now cites the current release tag.

## [0.3.1] — 2026-08-17

### Added

- `CHANGELOG.md` and `RELEASING.md`: a documented release process — how to choose a version number,
  the checklist for cutting a release, how to tag, and how updates reach installed users.
- README section on versioning, updates and pinning.

## [0.3.0] — 2026-08-17

### Added

- **The DevStride MCP server is bundled.** Installing the plugin brings the DevStride connection
  with it — no separate MCP setup. The bundled server uses OAuth: you sign in once through the
  browser and no credential is stored or committed.
- README section covering sign-in, switching organization, connecting without a browser (CI and
  other headless environments), and trimming the advertised tool catalog.

### Changed

- **Sign-in is a required step, not a lazy prompt.** Until you connect the server it contributes no
  tools at all, and nothing prompts you — run `/mcp` after installing.
- Signing in grants read **and write** access to the organization you pick, at the level you have in
  the app. There is no sandbox mode.

## [0.2.0] — 2026-08-17

### Added

- **The fifteen delivery-loop skills**, invocable as `/devstride:<name>`. Planning: `plan`,
  `comprehend-plan`, `insert-story`, `insert-defect`, `rationalize-gantt`. Delivery: `build-item`,
  `ultracode-build`, `review`, `pr`, `push`, `branch-feature`, `branch-hotfix`, `create-story`,
  `create-defect`, `release`.
- `CONTRIBUTING.md` recording the transition-period sync direction: skill text is developed upstream
  and ported here, so skill-prose pull requests are declined for now while issues and
  packaging/manifest pull requests are welcome.

## [0.1.0] — 2026-08-17

### Added

- Initial scaffold: plugin manifest, marketplace entry, MIT license, and repository conventions.
  Installed an empty plugin — no skills yet.

[unreleased]: https://github.com/devstride/claude-plugin/compare/devstride--v1.2.0...HEAD
[1.2.0]: https://github.com/devstride/claude-plugin/compare/devstride--v1.1.0...devstride--v1.2.0
[1.1.0]: https://github.com/devstride/claude-plugin/compare/devstride--v1.0.0...devstride--v1.1.0
[1.0.0]: https://github.com/devstride/claude-plugin/compare/devstride--v0.10.0...devstride--v1.0.0
[0.10.0]: https://github.com/devstride/claude-plugin/compare/devstride--v0.9.0...devstride--v0.10.0
[0.9.0]: https://github.com/devstride/claude-plugin/compare/devstride--v0.8.1...devstride--v0.9.0
[0.8.1]: https://github.com/devstride/claude-plugin/compare/devstride--v0.8.0...devstride--v0.8.1
[0.8.0]: https://github.com/devstride/claude-plugin/compare/devstride--v0.7.0...devstride--v0.8.0
[0.7.0]: https://github.com/devstride/claude-plugin/compare/devstride--v0.6.0...devstride--v0.7.0
[0.6.0]: https://github.com/devstride/claude-plugin/compare/devstride--v0.5.0...devstride--v0.6.0
[0.5.0]: https://github.com/devstride/claude-plugin/compare/devstride--v0.4.3...devstride--v0.5.0
[0.4.3]: https://github.com/devstride/claude-plugin/compare/devstride--v0.4.2...devstride--v0.4.3
[0.4.2]: https://github.com/devstride/claude-plugin/compare/devstride--v0.4.1...devstride--v0.4.2
[0.4.1]: https://github.com/devstride/claude-plugin/compare/devstride--v0.4.0...devstride--v0.4.1
[0.4.0]: https://github.com/devstride/claude-plugin/compare/devstride--v0.3.4...devstride--v0.4.0
[0.3.4]: https://github.com/devstride/claude-plugin/compare/devstride--v0.3.3...devstride--v0.3.4
[0.3.3]: https://github.com/devstride/claude-plugin/compare/devstride--v0.3.2...devstride--v0.3.3
[0.3.2]: https://github.com/devstride/claude-plugin/compare/devstride--v0.3.1...devstride--v0.3.2
[0.3.1]: https://github.com/devstride/claude-plugin/compare/devstride--v0.3.0...devstride--v0.3.1
[0.3.0]: https://github.com/devstride/claude-plugin/compare/devstride--v0.2.0...devstride--v0.3.0
[0.2.0]: https://github.com/devstride/claude-plugin/compare/devstride--v0.1.0...devstride--v0.2.0
[0.1.0]: https://github.com/devstride/claude-plugin/releases/tag/devstride--v0.1.0
