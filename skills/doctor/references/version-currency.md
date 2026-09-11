---
load: contract
---
# Version currency — the one recipe

The shared contract for newest-release and installed-version decisions. `doctor` §2 reports it;
`hooks/version-check.sh` and `/devstride:update` execute it through
`skills/update/scripts/latest-version.sh`. Keep all three paths aligned.

## Newest release

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/update/scripts/latest-version.sh"
```

Three traps, each one a real misreport:

- **Tags, not GitHub Releases.** This project tags every release and creates no Release objects, so
  a `releases` query returns empty and reads as "up to date" forever.
- **Accept only the strict `devstride--vMAJOR.MINOR.PATCH` tag shape**, then return its bare version.
  A loose suffix match can treat another plugin's tag as this plugin's release.
- **Compare the three numeric components portably**, never lexically: `1.10.0` must beat `1.9.0`.

## The running version — not the on-disk one

`claude plugin list` reads DISK. A session serves whatever it loaded at startup, so the two can
disagree. The version-check hook runs *from the loaded copy*, so it reads
`$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json` — the version **this session** is serving —
and reports that. `doctor`, which runs as a skill inside the session, reports what
`claude plugin list` says and labels it as disk.

## Updating — explicit skill or native bootstrap

From 3.5.1 (3.1.0–3.5.0 can stop with `plugin-root-missing`), `/devstride:update` resolves the loaded copy, requires the canonical marketplace at the
newest tag commit (from 3.5.1, or a descendant changing only inert maintainer files), compares the
installed shipped files with that tag, and verifies disk again. It may
change a user/project/local install, but never a pin, managed install, or ambiguity. Reload and
confirm no DevStride load error; restart if reload is unavailable or fails.

Before 3.5.1 (3.0.0 and older lack the skill), bootstrap with both commands:

```bash
claude plugin marketplace update devstride     # refresh the catalog; changes NO installed plugin
claude plugin update <installed-id> --scope <scope>
```

Take both placeholders from `claude plugin list --json`; the installed id may be the `ds` alias and
`update` otherwise defaults to user scope. Repository `autoUpdate` runs only at session start and
may mutate only a project/local row bound to that checkout; a linked worktree reports
`worktree-auto-deferred`. Shared user rows hand off to update,
managed rows to their administrator, and unbound/ambiguous rows to Doctor. Exit zero alone proves
nothing. After native bootstrap, verify with `claude plugin list`, then reload and check for errors.

**Install line (doctor's repo declaration).** No DevStride row bound here in `claude plugin list
--json`: print `claude plugin install <id> --scope project`, from the repository root (it writes
`enabledPlugins` into the committed `.claude/settings.json`; `--scope local` is per person). A
user-scope row too: add `claude plugin uninstall <that row's id> --scope user --keep-data`, or the pair stops
`/devstride:update`. A bound row needs no install line.

## What the session-start check records

Two files under `${XDG_CACHE_HOME:-~/.cache}/devstride-plugin/`. `newest.json` is shared — the
newest tag is not per-repository — and holds a schema, canonical source, `newest`, and `fetchedAt`
for the six-hour TTL. Older/untrusted cache shapes are ignored.
`repo-<sha1-of-repo-root>.json` is per repository, because `mode` comes from that repository's
config and two repositories with different pins would otherwise overwrite each other's status.
Written on every run:

| Field | Meaning |
|---|---|
| `checkedAt` | Unix time of this run |
| `repo` | The repository root the config was read from (a session launched from a subdirectory still resolves to it) |
| `running` | The version the session that ran the check was serving |
| `newest` | Newest tag seen, or `null` when unreachable |
| `source` | `network` (fetched this run) or `cache` (within the 6-hour TTL) |
| `mode` | `notify` (default), `auto-update`, `pinned`, or `invalid` when config/runtime could not be trusted |
| `result` | `current`, `behind`, `behind-pinned`, `pin-drift`, `pinned-ahead`, `running-ahead`, `invalid-config`, `invalid-runtime`, `disk-current-unverified`, `disk-current-verified`, `installed-ahead`, `updated`, `update-failed`, `update-verification-failed`, `shared-scope-auto-refused`, `scope-binding-unverified`, `worktree-auto-deferred`, `lookup-failed`, or `unreachable` |
| `install` | The `id scope` identified from the enabled row whose `installPath` is the loaded copy — or `null` |
| `notifiedFor` | What the pinned/drift line was last printed for; the same situation is said once, not every start |
| `statusLine` | Independent managed-copy result: `n/a`, `current`, `owner-managed`, `updated:<old>:<new>`, or `update-refused` |

Absent per-repo file → the check has never run for this repository on this machine: the plugin predates it, hooks are disabled,
or `DEVSTRIDE_PLUGIN_UPDATE_CHECK=0` is set. That is what `doctor` reports.

## Cited by

- `skills/doctor/SKILL.md` §2 — the **Version currency** bullet ("run … use its strict shared tag
  helper (not Releases) and report installed/newest").
- `skills/doctor/SKILL.md` §2 — the **Session-start check** bullet, for the per-repository record's
  schema and for explaining every `result` value.
- `skills/setup/references/config-defaults.md` — the update-check keys point here for the recipe.
- `hooks/version-check.sh` — its header names this file as the recipe for "newest release".
