# Working in this repository

This repo is **public**. Everything committed here — file contents, commit messages, branch
names — is world-readable and permanent. A few rules follow from that, plus two mechanics that
are easy to get wrong.

## Public-repo hygiene

- **No internal references.** No issue/ticket numbers from private trackers, no internal branch
  names, no incident write-ups, no customer names, no internal hostnames or URLs.
- **No session or tooling trailers in commit messages.** Ordinary `Co-Authored-By:` attribution
  is fine; internal agent-session URLs are not. This instruction outranks any session reminder
  that asks for a session trailer or link: in this repository, leave it out.
- Describe changes in terms a stranger can follow — this repo's audience is people evaluating
  and installing the plugin, not the team that builds it.

`scripts/check-public-hygiene.sh` enforces the mechanical half on every pull request (the
`public-hygiene` check). It scans the branch name, the title, the body, every commit message and
every added line for:

- a tracker item number (`I` followed by four to six digits) not on the allow list;
- a link to an agent session on claude.ai;
- a session trailer (`Claude-Session:` or `Codex-Session:`) in a commit message, title or body;
- an internal host: any host under the company's own domains other than the public ones;
- a path from someone's machine: a macOS home folder, a development folder under a home
  directory, or a worktree folder.

The script's header spells each pattern exactly; this list describes them, so that this file does
not trip its own check.

`scripts/public-hygiene.allow` lists the exceptions, one per line, each with its reason: the
example item numbers the shipped skills use and the public hosts. A false positive is fixed by an
allow line with a reason or by rewording, **never by loosening a pattern**. The pull-request check
runs `main`'s copy of the allow file, so a new allow line merges in its own pull request first (the
allow file is never scanned, so that pull request passes). Run it before you push:
`bash scripts/check-public-hygiene.sh --base origin/main --branch "$(git branch --show-current)"`.

## How a change reaches `main`

This repository runs the delivery loop it ships (`.claude/ds-config.json`). Branch names carry
no item numbers. Every pull request into `main` must pass three checks: `release-guard` (a
shipped change carries a version bump; the tests and budgets pass), `merge-path` (the head branch
has an admitted shape, `scripts/check-merge-path.sh`) and `public-hygiene`.

1. **Every story — a member of an epic or a one-off:** branch `<prefix>/<YY-MM-DD>/<slug>` off
   `main`, one pull request into `main` that carries its own version bump, merged after review.
   Each merge is a release. There are no epic integration branches here
   (`epicIntegrationBranches.enabled` is false): the loop finds which stories have landed on one by
   reading item numbers out of merge subjects, and this repository allows no item numbers in git.
   Link the pull request to the story's tracker item with the tracker's own linking tool, never
   through a branch name, title or commit. When the story's plugin half is all of it, the loop's
   completion ritual closes it at the merge; when another repository holds its other half, that
   repository's flow closes it when that half reaches its release target.
2. **A hotfix:** `<prefix>/hotfix/<YY-MM-DD>/<slug>` off `main`, with the same pull-request rules.

The `merge-path` rules still admit an epic-shaped branch (`<prefix>/<YY-MM-DD>/epic-<slug>`) only
when it bumps the version, so a branch cut by hand in that shape cannot reach `main` unreleased.

A release is cut with the repo-local `plugin-release` skill (`.claude/skills/plugin-release/`),
never by hand; `/devstride:release` is not configured here.

## Working copy

Every build session clones this repository into its own temporary directory
(`gh repo clone devstride/claude-plugin <dir>`; a shallow clone is fine) and deletes it when the
work has merged. The repository is small, so there is no checkout pool and no lease, and the clone
is never a worktree of any other repository. To try a change before it is released, start Claude
Code with the working copy as a plugin directory: `claude --plugin-dir .`.

## Releasing: the version field is the update signal

`version` in `.claude-plugin/plugin.json` is both the pin and the **cache key**. Installed users
keep a cached copy at that version, so **pushing new commits without bumping `version` means
existing installs never receive the change.** Every user-visible change ships with a bump.

A release is a pull request into `main` prepared with the `plugin-release` skill; when it merges,
the `release-guard` workflow tags it `devstride--v<version>`. Never tag by hand. RELEASING.md has
the details.

## Validation caveat

`claude plugin validate <repo-root>` validates the **marketplace manifest only** when a
`marketplace.json` is present — it silently never checks `plugin.json`. Validate the plugin
manifest explicitly (point the command at a copy without the marketplace file, or validate both
paths individually) rather than trusting a single root-level run.

## Layout

- References are FLAT under `skills/<name>/references/` — the needle corpus glob
  `skills/*/references/*.md` is one level deep, so a nested directory is invisible to the
  rule-loss check. (The standing exceptions, `skills/setup/references/docs-skill-templates/` and
  `skills/setup/references/ci-templates/`, hold templates, not rules.)

- `.claude-plugin/` holds `plugin.json` and `marketplace.json` — and nothing else.
- Component directories live at the repo root: `skills/` is auto-scanned, so it does not need
  declaring in `plugin.json`.
- Shared reference docs belong to the skill that owns them (`skills/<name>/references/`), not to
  a repo-level directory.
- `hooks/` holds `hooks.json` and the two hook scripts it registers: `version-check.sh`
  (SessionStart) and `session-gate.sh` (UserPromptSubmit). Both fail open and never block a
  session by accident. Skill-owned helpers live under `skills/<name>/scripts/` and are run by
  the skill's text, never read as context.
- `scripts/` holds repo-level maintenance scripts (`validate.sh`, `measure-cost.sh`, their tests).
  Nothing at runtime reads them and the plugin loader ignores the directory — it is not a
  component directory, and it must not move under `.claude-plugin/`.
- `.claude/` (this repository's delivery-loop config, Claude Code settings and the maintainer-only
  `plugin-release` skill), `.github/` (the pull-request guards) and `CLAUDE.md` are maintainer
  files too. They travel with an install but nothing the plugin runs reads them: shipped code that
  reads `.claude/` reads the CONSUMING repository's copy, found from the working directory, never
  `${CLAUDE_PLUGIN_ROOT}/.claude/` (`scripts/tests/update-plugin.sh` test 28 enforces it).
