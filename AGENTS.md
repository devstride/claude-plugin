# Working in this repository

This repo is **public**. Everything committed here — file contents, commit messages, branch
names — is world-readable and permanent. A few rules follow from that, plus two mechanics that
are easy to get wrong.

## Public-repo hygiene

- **No internal references.** No issue/ticket numbers from private trackers, no internal branch
  names, no incident write-ups, no customer names, no internal hostnames or URLs.
- **No session or tooling trailers in commit messages.** Ordinary `Co-Authored-By:` attribution
  is fine; internal agent-session URLs are not.
- Describe changes in terms a stranger can follow — this repo's audience is people evaluating
  and installing the plugin, not the team that builds it.

## Releasing: the version field is the update signal

`version` in `.claude-plugin/plugin.json` is both the pin and the **cache key**. Installed users
keep a cached copy at that version, so **pushing new commits without bumping `version` means
existing installs never receive the change.** Every user-visible change ships with a bump.

Tag releases with `claude plugin tag`, which creates a `{name}--v{version}` git tag and checks
that `plugin.json` and the marketplace entry agree.

## Validation caveat

`claude plugin validate <repo-root>` validates the **marketplace manifest only** when a
`marketplace.json` is present — it silently never checks `plugin.json`. Validate the plugin
manifest explicitly (point the command at a copy without the marketplace file, or validate both
paths individually) rather than trusting a single root-level run.

## Layout

- References are FLAT under `skills/<name>/references/` — the needle corpus glob
  `skills/*/references/*.md` is one level deep, so a nested directory is invisible to the
  rule-loss check. (The standing exception, `skills/setup/references/docs-skill-templates/`,
  holds templates, not rules.)

- `.claude-plugin/` holds `plugin.json` and `marketplace.json` — and nothing else.
- Component directories live at the repo root: `skills/` is auto-scanned, so it does not need
  declaring in `plugin.json`.
- Shared reference docs belong to the skill that owns them (`skills/<name>/references/`), not to
  a repo-level directory.
- `scripts/` holds repo-level maintenance scripts (`validate.sh`, `measure-cost.sh`, their tests).
  Nothing at runtime reads them and the plugin loader ignores the directory — it is not a
  component directory, and it must not move under `.claude-plugin/`.
