# Changelog

All notable changes to this plugin are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). See [RELEASING.md](RELEASING.md)
for what each version component means here and how a release is cut.

## [Unreleased]

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

[unreleased]: https://github.com/devstride/claude-plugin/compare/devstride--v0.4.2...HEAD
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
