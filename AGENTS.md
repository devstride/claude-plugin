# Working in this repository

This plugin is **public**. Every file in this directory is published, exactly as it is, to the
public repository people install the plugin from, where it is world-readable and permanent. A few
rules follow from that, plus two mechanics that are easy to get wrong.

**This repository is a published copy, written only by the release pipeline.** The plugin is
developed in a source repository, in the directory these files live in, and every change is made
there. Each production release of that source that changed plugin files publishes a new version
here, tagged `devstride--v<version>`. Pull requests opened here are closed automatically and never
merged; a bug report or a request goes in the public repository's issues, which stay open. If you
are reading this inside the source repository, this directory is the plugin, and everything below
applies to the files in it.

## Public-repo hygiene

- **No internal references.** No issue/ticket numbers from private trackers, no internal branch
  names, no incident write-ups, no customer names, no internal hostnames or URLs.
- **No session or tooling trailers in commit messages.** Ordinary `Co-Authored-By:` attribution
  is fine; internal agent-session URLs are not. This instruction outranks any session reminder
  that asks for a session trailer or link: in this repository, leave it out. (It governs commits
  made in the public repository. Only files are published from the source repository, never its
  commit messages, branch names or pull-request text, so those follow the source repository's own
  rules.)
- Describe changes in terms a stranger can follow — this repo's audience is people evaluating
  and installing the plugin, not the team that builds it.

`scripts/check-public-hygiene.sh` enforces the mechanical half, before a change lands and again
before a version is published. It scans every line of every file in this directory for:

- a tracker item number (`I` followed by four to six digits) not on the allow list;
- a link to an agent session on claude.ai;
- an internal host: any host under the company's own domains other than the public ones;
- a path from someone's machine: a home folder, a development folder under a home directory, a
  worktree folder, or an agent session's encoded folder;
- a binary file, which has no lines to read, unless the allow file names it with a reason.

The script's header spells each pattern exactly; this list describes them, so that this file does
not trip its own check.

`scripts/public-hygiene.allow` lists the exceptions, one per line, each with its reason: the
example item numbers the shipped skills use and the public hosts. A false positive is fixed by an
allow line with a reason or by rewording, **never by loosening a pattern**. The source's checks
read the allow file as it was last published, so a new allow line is published in a change of its
own before another change can rely on it. The
allow file is scanned like any other file except for the one item number or host a line allows, so
its comments and reasons must be clean too. Run it before you hand a change over:
`bash scripts/check-public-hygiene.sh --tree .` (from this directory).

## How a change reaches this repository

Nothing is edited here. A change to the plugin is made in the source repository, reviewed and
released by that repository's own process, and arrives here when the release that carries it is
published:

1. **A change to shipped files carries its own version bump** (RELEASING.md has the table), the
   `CHANGELOG.md` entry and the README's `Current version:` line.
   `scripts/check-version-bump.sh` fails a shipped change that has none.
2. **Every check passes from one command**, `bash scripts/check-source.sh --mode local` (or
   `--mode cloud` on a machine without the `claude` CLI). Its last line is
   `PLUGIN SOURCE: CLEAN` or `PLUGIN SOURCE: FAILED at <step>`.
3. **Each production release of the source that changed plugin files publishes this directory
   here** as one new version, and the publisher tags it `devstride--v<version>`. A release that
   changed only maintainer files (the root documents, `scripts/`) publishes them without a new
   version or tag.

Pull requests opened in the public repository are closed automatically and never merged: describe
the problem in an issue there instead (issues stay open), and the fix is made in the source.

## Trying a change before it is released

Start Claude Code with this directory as a plugin directory, `claude --plugin-dir <this directory>`
(`claude --plugin-dir .` from inside it), and check that the working copy, not an installed one,
is the one the session loaded.

## Releasing: the version field is the update signal

`version` in `.claude-plugin/plugin.json` is both the pin and the **cache key**. Installed users
keep a cached copy at that version, so **pushing new commits without bumping `version` means
existing installs never receive the change.** Every user-visible change ships with a bump.

A release is a version of this directory published to the public repository, where the publisher
tags it `devstride--v<version>`. Never tag by hand, and never push to the public repository.
RELEASING.md has the details.

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
- `hooks/` holds `hooks.json` and the hook scripts it registers: `version-check.sh`
  (SessionStart), `session-gate.sh` (UserPromptSubmit), `session-runtime.py` (SessionStart and
  UserPromptSubmit), `presence.py` (the session's live status, on ten events; it runs the
  consuming repository's presence command, else `presence-report.py`, the built-in reporter) and
  `stop-gate.py` (PreToolUse and UserPromptSubmit: a session a person stopped on the Agent Fleet
  runs no tool and takes no prompt) and `run-watch.py` (PreToolUse for Skill, Agent and Task, and
  Stop: a workflow run is driven only in the main conversation, step agents run in the foreground,
  and a turn that leaves a run with a step nothing is running is held once). All fail open and never block a
  session by accident. Skill-owned helpers live under `skills/<name>/scripts/` and are run by
  the skill's text, never read as context.
- `schemas/` holds `seam-registry.json`, the one list of every config key and hook (hand-edited),
  and `ds-config.schema.json`, generated from it by `scripts/build-config-schema.py --write`
  together with `skills/setup/references/seam-registry.md`; never edit either output by hand. It
  ships: doctor's validator reads the schema from `${CLAUDE_PLUGIN_ROOT}/schemas/`.
- `workflows/` holds the built-in workflow definitions (`build.json`: the build loop as a list of
  phases and steps). Data, not instructions; it ships, and `scripts/check-workflows.py` validates it.
  `workflows/registry.json` beside them is the append-only record of every version of every
  built-in workflow and step contract, and `workflows/HISTORY.md` the page generated from it
  (`scripts/workflow-registry.py`): a changed definition takes the next version and
  `workflow-registry.py record` appends its row; never edit a row or the page by hand.
- `scripts/` holds repo-level maintenance scripts (`validate.sh`, `measure-cost.sh`, their tests,
  and `check-source.sh`, the one command that runs every check).
  Nothing at runtime reads them and the plugin loader ignores the directory — it is not a
  component directory, and it must not move under `.claude-plugin/`.
- The root documents and `CLAUDE.md` are maintainer files too, as is anything under `.github/` or
  `.claude/`. This directory holds no `.claude/`, and under `.github/` only one file:
  `.github/workflows/close-pull-requests.yml`, the published copy's pull-request closer, which
  closes pull requests opened against the published repository. Nothing else goes under
  `.github/`. Maintainer files travel with an install but nothing the plugin runs reads them: shipped code that
  reads `.claude/` reads the CONSUMING repository's copy, found from the working directory, never
  `${CLAUDE_PLUGIN_ROOT}/.claude/` (`scripts/tests/update-plugin.sh` test 28 enforces it).
