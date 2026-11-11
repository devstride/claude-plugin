# Releasing

A release is a pull request into `main` that carries a version bump. There is no package registry —
the marketplace source is this git repository, so the release artifacts are a version, a changelog
entry, and a tag, and the `release-guard` workflow pushes the tag when the release merges.

## Why the version matters more than usual

`version` in `.claude-plugin/plugin.json` is **the install cache key**. Installed copies are cached
per version, so **pushing changes without bumping it means existing installs never receive them** —
they keep serving the cached copy indefinitely. This is the single easiest mistake to make here, and
it fails silently: your change is on `main`, the repo looks right, and no user sees it.

Every user-visible change ships with a bump. No exceptions.

## Choosing the number

Semantic versioning, interpreted for a plugin whose product is instructions:

| Bump      | When                                                                                                                             |
| --------- | -------------------------------------------------------------------------------------------------------------------------------- |
| **MAJOR** | Breaking a published contract: **renaming or removing a skill** (`/devstride:<name>`), or **removing, renaming, or changing the meaning of an existing** `.claude/ds-config.json` key. |
| **MINOR** | New skills; existing skills whose **behavior** changes (new steps, different gates); **new** config keys. Purely additive contract changes belong here. |
| **PATCH** | Wording, typos, clarifications, documentation. Nothing that changes what a skill *does*.                                          |

**Worked examples.** Renaming `build-item` to `deliver` is MAJOR, even though it is a one-word edit:
every user's muscle memory, saved commands, and any wrapper scripts break. Adding a brand-new skill
alongside the existing skills is MINOR — nothing that worked before stops working. **Adding** a
config key is MINOR (existing configs keep working); **redefining** one is MAJOR (existing configs
now mean something else). Fixing a misleading sentence inside a skill is PATCH.

**The compatibility promise this table implies, and that users rely on:** an existing skill name and
an existing `.claude/ds-config.json` key keep working, and keep meaning the same thing, until a
MAJOR bump. New skills and new keys can arrive in a MINOR — the promise protects what you already
depend on, it does not freeze the surface.

## Cutting a release

The repo-local `plugin-release` skill (`.claude/skills/plugin-release/SKILL.md`) is the checklist;
run it rather than these steps by hand.

- **`plugin-release prepare [major|minor|patch]`**, on the branch whose pull request carries the
  release: `bash scripts/validate.sh --needles` (the three `claude plugin validate` passes, the
  marketplace invariant, `bash -n` over every shipped script, the script tests, the load budgets and
  the rule-loss needles — a budget breach or a DEAD REFERENCE blocks exactly like a manifest error;
  a needle MISS is a prompt to read), then the CHANGELOG move with its comparison links and the
  generated `### Cost` table, the version in `plugin.json` and the README's `Current version:` line,
  and one `release: v<version>` commit that
  `scripts/check-version-bump.sh` accepts.
- **The pull request merges**, after the delivery loop's review and the three required checks
  (`release-guard`, `merge-path`, `public-hygiene`; AGENTS.md, "How a change reaches `main`"),
  through `plugin-release merge <pr>` under the owner's standing yes (`.claude/standing-yes.md`)
  when every one of its conditions holds, else on the owner's own yes.
- **`release-guard` tags `devstride--v<version>`** on the merge commit. Never tag by hand and never
  push to `main`: the tag is created only for a commit that is already on `main`, so a public
  release tag can never name a commit nobody merged.
- **`plugin-release verify`** waits for the tag and proves a scratch project installs the version.
- **Announce it**, including `/devstride:update` for installations on 3.5.1 or newer and the two
  native bootstrap commands below for everything older — on 3.1.0–3.5.0 `/devstride:update` can
  stop with `plugin-root-missing` (fixed in 3.5.1), and older copies do not contain the skill.

Three rules the skill applies, and why:

- **An empty `Unreleased` is not a release.** Either nothing user-visible changed, or the entries
  were never written; write them from `git log <last tag>..HEAD`. Do not cut an empty version.
- **The marketplace entries carry no version.** `devstride` and its `ds` alias must stay identical
  in `source`, so both serve the same plugin at the same version; a `version` field on either would
  manufacture drift. Assert it when you touch that file:

  ```bash
  python3 -c "import json; p=json.load(open('.claude-plugin/marketplace.json'))['plugins']; \
    assert len({e['source'] for e in p})==1 and not [e for e in p if 'version' in e]; print('ok')"
  ```

- **A release never touches a status-line marker.** Repositories commit only the launcher
  (`skills/setup/references/statusline-launcher.sh`), which runs the `statusline.sh` of the plugin
  a session has loaded, so a change to `statusline.sh` reaches people with the plugin and needs
  nothing else. The launcher's own `# ds-statusline-launcher: managed v<n>` marker rises by one in
  the commit that changes the launcher, never at release time: the session-start hook compares it
  with each repository's launcher, so an unchanged marker strands a launcher fix in the field.

**Commits after a release that touch only maintainer files** — the paths
`skills/update/scripts/update-plugin.py` lists as inert: the root documents, `CLAUDE.md`,
`scripts/`, `.github/` and `.claude/` — need neither a bump nor a tag: updates still install the
release beneath them. That holds only where both the running helper and the release being
installed list the path. Widening the list is the compatibility event: a helper older than the
release that widened it still treats the new paths as shipped, so hold `main` on the tag after a
widening until most machines run that release. Narrowing is safe.

## When your users actually get it

**Not automatically, unless they opted in — but from 1.2.0 they are told.** The plugin's own
session-start check (`hooks/version-check.sh`) compares the running version with the newest tag
(using a six-hour cache). When behind, it routes shared user copies to `/devstride:update`, managed
copies to their administrator, ambiguous copies to Doctor, and may update a repository-bound
project/local copy when `plugin.autoUpdate` is enabled. That is why tagging is part of
publishing, not bookkeeping: an untagged release is invisible to the check. Claude Code's own
auto-update is a separate, per-marketplace setting and it is **off by default** for a manually
added marketplace. A user who enables it (in `/plugin` → the
devstride marketplace → **Enable auto-update**) gets releases without doing anything. Everyone else
stays on their installed version indefinitely — verified on Claude Code 2.1.233, where starting a
fresh session with a newer version available left the installed plugin untouched.

From 3.5.1 onward (3.1.0–3.5.0 can stop with `plugin-root-missing`), `/devstride:update` resolves the loaded copy, attests the canonical tag and
installed files, then stops. Run `/reload-plugins` and confirm no DevStride load error; restart if
reload is unavailable or fails. Repository-driven automatic updates remain session-start-only.

On 3.5.0 or older — or when the skill is unavailable — two commands are required:

```bash
claude plugin marketplace update devstride   # refresh the catalog
claude plugin update devstride@devstride --scope <scope>   # the scope claude plugin list shows
```

followed by `/reload-plugins` (confirm no DevStride load error), with restart as the fallback. Three
traps worth repeating in the announcement:

- **`marketplace update` alone does nothing to an installed plugin.** It refreshes catalog metadata
  and prints success, while the installed copy stays exactly where it was. This looks like the fix
  did not ship.
- **`claude plugin update devstride` fails** with "Plugin not found" — the update command needs the
  fully-qualified `devstride@devstride`.
- **It defaults to the `user` scope.** Pass the scope `claude plugin list` shows — `project` for the
  recommended install, `user` for an older machine-wide one (likewise local or managed) — or the
  command reports the plugin is not installed and changes nothing.

So the answer to "when does my team get the fix" is: when marketplace auto-update next runs, at an
opted-in repository's next session start, through `/devstride:update` on 3.5.1+, or after the two
bootstrap commands on an older copy. Say which rather than assuming it propagates.

### Pinning

Users hold one repository with `plugin.pin` in its `.claude/ds-config.json`. Pinning the marketplace
(append `@<tag>` to its source; there is no `--ref` flag) holds every repository on the machine, and
**`marketplace remove` uninstalls every plugin that came from that marketplace, in every repository
and scope, and re-adding it does not bring them back** — so note each row first and reinstall each:

```bash
claude plugin list --json                 # note every DevStride row: id, scope, projectPath
claude plugin marketplace remove devstride
claude plugin marketplace add devstride/claude-plugin@devstride--v<version>
claude plugin install <id> --scope <scope>   # once per row: its id and scope, from its projectPath
```

Unpinning is the same three commands with the bare `devstride/claude-plugin` as the source.

This is one reason to tag every release: **the tag is the pin**, and an untagged release is one
nobody can hold still on. Treat tagging as part of publishing rather than a bookkeeping extra —
the update machinery resolves `<name>--v*` tags, so an untagged release is not merely unpinnable.

## This repository is the source of truth

Skill text is developed **here** and released from here. An earlier arrangement developed the skills
in a private upstream repository and ported them in, and this file used to warn that direct edits
would be overwritten by the next port. That ended with the dogfood cutover: the upstream repository
now installs this plugin and keeps no local copies of these skills. Edit skills directly, open a
pull request, and cut a release — there is nothing upstream to re-port from.

What survives from that era is the discipline, not the direction: keep skills repo-agnostic (see
[CONTRIBUTING.md](CONTRIBUTING.md)), move a *diff* rather than a file when text travels between
repositories, and run the invariants check whenever you edit skill text.
