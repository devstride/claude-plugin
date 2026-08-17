# DevStride for Claude Code

DevStride's agentic delivery loop, packaged as a Claude Code plugin. Plan a roadmap into
existence, then let the loop walk it one story at a time — branch, build, adversarially review,
merge, and release — against your own repository and your own DevStride organization.

> **Status: early.** The fifteen delivery-loop skills have landed. The DevStride MCP server is not
> bundled yet, so you supply your own MCP connection for now, and the guided setup command is still
> to come. The sections below fill out as those land.

## Install

```
/plugin marketplace add devstride/claude-plugin
/plugin install devstride@devstride
```

## Setup

The skills read a per-repo config file, `.claude/ds-config.json`, for everything repo-specific:
branch names, verify/test/lint commands, review engines, and release settings. Every key has a
shipped default, so the skills degrade sensibly before you write one — but the file is where you
adapt the loop to your repository, and where it disagrees with a default, the file wins.

A guided setup command that inspects your repo and writes that file for you is in progress.

## Skills

Skills are namespaced by the plugin, so they invoke as `/devstride:<name>`.

**Planning** — shape and maintain a roadmap in DevStride:

| Skill | What it does |
|---|---|
| `plan` | Drives a roadmap into existence under a parent item through an interactive discovery loop |
| `comprehend-plan` | Recursively reads a plan — descriptions and comment threads, every level — before any edit |
| `insert-story` / `insert-defect` | Splices new work into a live plan's dependency chain, dated and ordered |
| `rationalize-gantt` | Backfills dates and rationalizes the dependency graph so the timeline reads as a clean cascade |

**Delivery** — walk the plan one item at a time:

| Skill | What it does |
|---|---|
| `build-item` | The orchestrator: select → branch → build → review → merge → completion ritual → repeat |
| `ultracode-build` | The build engine for a single scoped item, including an adversarial review pass |
| `review` | Runs a PR through every configured review engine, settles every finding, then releases CI |
| `pr` | Opens a pull request and runs the review-and-settle loop |
| `push` | Stages, commits, type-checks, and pushes following the repo's commit conventions |
| `branch-feature` / `branch-hotfix` | Cuts a working branch from the development or production branch |
| `create-story` / `create-defect` | Creates a one-off item outside any plan and delivers it end to end |
| `release` | Promotes the release branch to production, with a full gated review and a docs pass |

## Versioning

`version` in `.claude-plugin/plugin.json` is the install cache key. Installed copies are cached per
version, so every user-visible change ships with a version bump — otherwise existing installs keep
serving the old copy.

## License

MIT — see [LICENSE](./LICENSE).
