# Version currency — the one recipe

The single authority for "what is the newest devstride plugin release, and is this install
behind?" Cited by `doctor` §2 and executed by `hooks/version-check.sh` at every session start.
Both must keep matching this file; a second copy of the recipe is a second place for it to drift.

## Newest release

```bash
git ls-remote --tags https://github.com/devstride/claude-plugin \
  | awk '{print $2}' | sed 's|refs/tags/||' | grep -v '\^{}' | sed 's/.*--v//' \
  | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1
```

Three traps, each one a real misreport:

- **Tags, not GitHub Releases.** This project tags every release and creates no Release objects, so
  a `releases` query returns empty and reads as "up to date" forever.
- **Strip the `devstride--v` prefix before comparing.** The tag is `devstride--v1.1.0`; the plugin
  reports `1.1.0`. Comparing the two shapes reports every current install as behind.
- **Compare with `sort -V`**, never lexically: `1.10.0` sorts before `1.9.0` as a string.

## The running version — not the on-disk one

`claude plugin list` reads DISK. A session serves whatever it loaded at startup, so the two can
disagree. The version-check hook runs *from the loaded copy*, so it reads
`$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json` — the version **this session** is serving —
and reports that. `doctor`, which runs as a skill inside the session, reports what
`claude plugin list` says and labels it as disk.

## Updating — two commands, and one alone does nothing

```bash
claude plugin marketplace update devstride     # refresh the catalog; changes NO installed plugin
claude plugin update <installed-id> --scope <scope>
```

then restart. **Take `<installed-id>` and `<scope>` from `claude plugin list --json`** — never
assume them. The marketplace publishes the same plugin under two entry names, `devstride` and the
`ds` alias; the id is whichever one that machine installed through, and naming the other reports
"not installed", which reads as a broken setup while the user stays on the old version believing
they updated. `update` acts on the `user` scope unless told otherwise, so always pass the
resolved scope. Repository `autoUpdate` may mutate only a `project`/`local` row whose
`projectPath` exactly matches this repository. A `user` or `managed` row is shared state: the
hook prints this manual command and never lets one repo update every other repo's installation.
After an automatic command, re-read `claude plugin list --json` and require the requested
version; exit status alone is not proof that disk changed.

## What the session-start check records

Two files under `${XDG_CACHE_HOME:-~/.cache}/devstride-plugin/`. `newest.json` is shared — the
newest tag is not per-repository — and holds `newest` + `fetchedAt` for the six-hour TTL.
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
| `mode` | `notify` (default), `auto-update`, or `pinned` — from the repo's `plugin` config block |
| `result` | `current`, `behind`, `behind-pinned`, `pin-drift`, `updated`, `update-failed`, `update-verification-failed`, `shared-scope-auto-refused`, `scope-binding-unverified`, `lookup-failed`, or `unreachable` |
| `install` | The `id scope` identified from the enabled row whose `installPath` is the loaded copy — or `null` |
| `notifiedFor` | What the pinned/drift line was last printed for; the same situation is said once, not every start |
| `statusLine` | Independent managed-copy result: `n/a`, `current`, `owner-managed`, `updated:<old>:<new>`, or `update-failed` |

Absent per-repo file → the check has never run for this repository on this machine: the plugin predates it, hooks are disabled,
or `DEVSTRIDE_PLUGIN_UPDATE_CHECK=0` is set. That is what `doctor` reports.
