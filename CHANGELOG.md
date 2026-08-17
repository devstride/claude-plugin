# Changelog

All notable changes to this plugin are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). See [RELEASING.md](RELEASING.md)
for what each version component means here and how a release is cut.

## [Unreleased]

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

### Notes

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

[unreleased]: https://github.com/devstride/claude-plugin/compare/devstride--v0.3.1...HEAD
[0.3.1]: https://github.com/devstride/claude-plugin/compare/devstride--v0.3.0...devstride--v0.3.1
[0.3.0]: https://github.com/devstride/claude-plugin/compare/devstride--v0.2.0...devstride--v0.3.0
[0.2.0]: https://github.com/devstride/claude-plugin/compare/devstride--v0.1.0...devstride--v0.2.0
[0.1.0]: https://github.com/devstride/claude-plugin/releases/tag/devstride--v0.1.0
