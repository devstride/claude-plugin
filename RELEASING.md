# Releasing

Cutting a release is a short manual checklist. There is no CI pipeline and no package registry — the
marketplace source is this git repository, so the release artifacts are a version, a changelog entry,
and a tag.

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
alongside the existing fifteen is MINOR — nothing that worked before stops working. **Adding** a
config key is MINOR (existing configs keep working); **redefining** one is MAJOR (existing configs
now mean something else). Fixing a misleading sentence inside a skill is PATCH.

**The compatibility promise this table implies, and that users rely on:** an existing skill name and
an existing `.claude/ds-config.json` key keep working, and keep meaning the same thing, until a
MAJOR bump. New skills and new keys can arrive in a MINOR — the promise protects what you already
depend on, it does not freeze the surface.

## The checklist

0. **Validate what you are about to ship.**

   ```bash
   bash scripts/validate.sh --needles
   ```

   That one command runs everything: the three `claude plugin validate` passes (the marketplace
   manifest, the skill frontmatter, and the plugin manifest from a copy without
   `marketplace.json` — one run does not cover it, and the root-level run silently skips the
   third), the marketplace invariant, `bash -n` over every shipped script, the script tests, and
   the skill-body budget check. **A budget breach blocks the release exactly like a manifest
   error** — raise the budget visibly in the same commit as the text that needs it, or move
   rationale to a reference. `--needles` adds the rule-loss check from
   `delivery-loop-invariants.md` — a needle MISS is advisory (a prompt to read, not a failure); a
   DEAD REFERENCE is blocking and fails the step.

1. **Move the `Unreleased` entries** in `CHANGELOG.md` under a new `## [x.y.z] — YYYY-MM-DD`
   heading, add the comparison link at the bottom, and **re-point `[unreleased]`** at the tag you are
   about to create — otherwise it spans the release you just cut. Then paste the output of
   `bash scripts/measure-cost.sh --table --since <previous tag>` under the new heading as a
   `### Cost` subsection: the numbers are generated, never edited by hand, and the table's leading
   comment names the ref and commit it was measured against.

   *If `Unreleased` is empty*, one of two things is true. Either nothing user-visible changed, in
   which case do not cut a release at all; or the entries were never written, in which case write
   them now from the commit range (`git log <last tag>..HEAD`). Do not cut an empty version.

2. **Bump `version`** in `.claude-plugin/plugin.json`. This is the authority — the marketplace
   entries deliberately carry no version, so there is nothing to keep in sync there.

   **Keep it that way.** There are two entries now, `devstride` and its `ds` alias, and they must
   stay identical in `source` so both always serve the same plugin at the same version. Adding a
   `version` field to either one would manufacture exactly the drift this arrangement makes
   impossible — two entries that can disagree about what they publish. The invariant is worth
   asserting if you touch that file:

   ```bash
   python3 -c "import json; p=json.load(open('.claude-plugin/marketplace.json'))['plugins']; \
     assert len({e['source'] for e in p})==1 and not [e for e in p if 'version' in e]; print('ok')"
   ```

3. **Update the README's `Current version:` line** to match. It is the only *other* place a version
   literal lives, and it is the first thing a visitor reads. Every other example deliberately uses a
   `<version>` placeholder so it cannot go stale.

4. **Commit** as `release: v<version>`.

5. **Push `main` FIRST.** Before tagging, not after: `claude plugin tag --push` pushes only the tag.
   Tag first and a rejected or forgotten branch push leaves an immutable public release tag for a
   commit that is not on `main`.

6. **Tag.** Use the official tooling rather than tagging by hand. Preview it first:

   ```bash
   claude plugin tag --dry-run
   claude plugin tag --push
   ```

   This creates `devstride--v<version>` — note the plugin-name prefix, which is the convention the
   tool expects, not a bare `v<version>`. It refuses to run on a dirty tree, and **refuses to
   re-create a tag that already exists** — which is what actually catches a forgotten step 2, and it
   only works because the previous release was tagged. (Its manifest-agreement check cannot catch an
   un-bumped version: the marketplace entry has no version to disagree with.)

7. **Verify the release is real**, in a scratch project — this whole document exists because these
   failures are silent:

   ```bash
   claude plugin marketplace update devstride
   claude plugin update devstride@devstride
   claude plugin list          # confirm the reported version is the one you just cut
   ```

8. **Announce it**, including the two update commands from the section below. Users who have not
   enabled auto-update will not receive the release until they run them.

## When your users actually get it

**Not automatically, unless they opted in — but from 1.2.0 they are told.** The plugin's own
session-start check (`hooks/version-check.sh`) compares the version a session is running against
the newest tag and prints the two update commands when it is behind; a repository can opt in to
having it apply the update at session start (`plugin.autoUpdate`). That is why tagging is part of
publishing, not bookkeeping: an untagged release is invisible to the check. Claude Code's own
auto-update is a separate, per-marketplace setting and it is **off by default** for a manually
added marketplace. A user who enables it (in `/plugin` → the
devstride marketplace → **Enable auto-update**) gets releases without doing anything. Everyone else
stays on their installed version indefinitely — verified on Claude Code 2.1.233, where starting a
fresh session with a newer version available left the installed plugin untouched.

For everyone else, two commands, and **both** are required:

```bash
claude plugin marketplace update devstride   # refresh the catalog
claude plugin update devstride@devstride     # upgrade the installed plugin
```

followed by a restart to apply. Three traps worth repeating in the announcement:

- **`marketplace update` alone does nothing to an installed plugin.** It refreshes catalog metadata
  and prints success, while the installed copy stays exactly where it was. This looks like the fix
  did not ship.
- **`claude plugin update devstride` fails** with "Plugin not found" — the update command needs the
  fully-qualified `devstride@devstride`.
- **It defaults to the `user` scope.** A project-, local- or managed-scope install needs a matching
  `--scope`, or the command reports the plugin is not installed and changes nothing.

So the answer to "when does my team get the fix" is: immediately if they enabled auto-update,
otherwise when they run those two commands. Say which in the announcement rather than assuming it
propagates.

### Pinning

Users pin by appending `@<tag>` to the marketplace source. There is no `--ref` flag; the ref belongs
in the source argument. **`marketplace remove` uninstalls every plugin that came from that
marketplace, and re-adding it does not bring them back** — so the reinstall is a required third step:

```bash
claude plugin marketplace remove devstride
claude plugin marketplace add devstride/claude-plugin@devstride--v<version>
claude plugin install devstride@devstride
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
