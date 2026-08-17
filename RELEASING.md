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
| **MAJOR** | A breaking change to a published contract: **renaming or removing a skill** (`/devstride:<name>`), or changing the meaning of an existing `.claude/ds-config.json` key. |
| **MINOR** | New skills, or existing skills whose **behavior** changes — new steps, different gates, a new config key. Additive contract changes belong here. |
| **PATCH** | Wording, typos, clarifications, documentation. Nothing that changes what a skill *does*.                                          |

**Worked example.** Renaming `build-item` to `deliver` is a MAJOR bump, even though it is a one-word
edit: every user's muscle memory, saved commands, and any wrapper scripts break. Adding a brand-new
skill alongside the existing fifteen is MINOR — nothing that worked before stops working. Fixing a
misleading sentence inside a skill is PATCH.

**The compatibility promise this table implies, and that users rely on:** skill names and the
`.claude/ds-config.json` key contract change **only on a MAJOR bump**. Anything else is free to move
between minors.

## The checklist

1. **Move the `Unreleased` entries** in `CHANGELOG.md` under a new `## [x.y.z] — YYYY-MM-DD`
   heading, and add the comparison link at the bottom of the file.
2. **Bump `version`** in `.claude-plugin/plugin.json` to match. It lives there and nowhere else —
   the marketplace entry deliberately carries no version, so there is nothing to keep in sync.
3. **Commit** as `release: v<version>`.
4. **Tag and push.** Use the official tooling rather than tagging by hand:

   ```bash
   claude plugin tag --push -m "devstride %s"
   ```

   This creates `devstride--v<version>` — note the plugin-name prefix, which is the convention the
   tool expects, not a bare `v<version>`. It also refuses to run on a dirty tree and validates that
   `plugin.json` and the marketplace entry agree, which is the check that catches a half-finished
   step 2. Preview with `--dry-run` first.
5. **Push `main`.**

## When your users actually get it

**They do not get it automatically.** This is the part worth stating plainly when you announce a
release, because the intuition is wrong: an installed plugin stays pinned to its installed version
indefinitely. Verified on Claude Code 2.1.233 — starting a fresh session with a newer version
available left the installed plugin untouched.

Getting the new version takes two commands, and **both** are required:

```bash
claude plugin marketplace update devstride   # refresh the catalog
claude plugin update devstride@devstride     # upgrade the installed plugin
```

followed by a restart to apply. Two traps worth repeating to users:

- **`marketplace update` alone does nothing to an installed plugin.** It refreshes catalog metadata
  and prints success, while the installed copy stays exactly where it was. This looks like the fix
  did not ship.
- **`claude plugin update devstride` fails** with "Plugin not found" — the update command needs the
  fully-qualified `devstride@devstride`.

So the answer to "when does my team get the fix" is: when they run those two commands. Say so in the
release announcement rather than assuming it propagates.

### Pinning

There is **no version or ref flag** on `claude plugin marketplace add` — a GitHub-sourced marketplace
always tracks the default branch. Pinning therefore works by pointing the marketplace at a local
clone checked out at a release tag, which freezes the user at that commit until they move the clone:

```bash
git clone --branch devstride--v0.3.1 --depth 1 \
  https://github.com/devstride/claude-plugin ~/devstride-plugin-pinned
claude plugin marketplace remove devstride
claude plugin marketplace add ~/devstride-plugin-pinned
```

Unpin by removing it and re-adding the GitHub source:

```bash
claude plugin marketplace remove devstride
claude plugin marketplace add devstride/claude-plugin
```

This is the reason release tags matter even without GitHub Releases: the tag is what a pinning user
clones.

## A release packages a port — it does not license direct edits

Until the upstream repository switches to consuming this published plugin, **skill text is developed
upstream and ported here** (see [CONTRIBUTING.md](CONTRIBUTING.md)). Cutting a release does not
change that: a release packages whatever the latest port brought in. If a skill needs a fix, it is
fixed upstream and re-ported, then released. Editing skill prose directly here would be silently
overwritten by the next port.
