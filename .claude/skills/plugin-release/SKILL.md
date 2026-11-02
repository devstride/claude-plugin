---
name: plugin-release
description: "Cut a release of this plugin: `prepare [major|minor|patch]` validates, moves the CHANGELOG, adds the cost table, bumps the version and README line and commits `release: v<version>` on the release branch; `verify` waits for the tag the release-guard workflow pushes after the merge and proves a scratch project installs it. A maintainer skill of this repository, never shipped."
---

# plugin-release

The release of this plugin is a pull request into `main`: its head carries the version bump,
the CHANGELOG heading, the README line and the cost table, and once it merges the
`release-guard` workflow tags `devstride--v<version>`. This skill does the two halves around that
merge. RELEASING.md says what each version component means and why the version is the update
signal; read it before choosing the bump.

Every message to a person says what happened in plain words, and ends with one result line:

- `PLUGIN RELEASE: PREPARED v<version> on <branch> (<sha>)`
- `PLUGIN RELEASE: VERIFIED v<version> (tag <sha>, installed in a scratch project)`
- `PLUGIN RELEASE: BLOCKED <step>: <reason>` — and nothing after the blocked step runs.

## prepare [major|minor|patch]

Run on the branch whose pull request will carry the release (a story or hotfix branch: every merge
into `main` here is its own release), with a clean tree and that branch up to date with
`origin/main`.

1. **Choose the bump.** The argument, or else read `## [Unreleased]` in `CHANGELOG.md` against
   RELEASING.md's table and say which row decided it. An empty `Unreleased` blocks: either nothing
   user-visible changed (no release), or write the entries from `git log <newest tag>..HEAD` first.
2. **Validate.** `bash scripts/validate.sh --needles`. A failure, a budget breach or a DEAD
   REFERENCE blocks; a needle MISS is read and reported, not a failure.
3. **The CHANGELOG.** Move every `Unreleased` entry under `## [<version>] — <YYYY-MM-DD>` (today's
   date where the release is cut), leave `## [Unreleased]` empty above it, add the comparison link
   `[<version>]: https://github.com/devstride/claude-plugin/compare/devstride--v<previous>...devstride--v<version>`
   beside the others, and re-point `[unreleased]` at `devstride--v<version>...HEAD`.
4. **The cost table.** Paste the output of
   `bash scripts/measure-cost.sh --table --since devstride--v<previous>` under the new heading as a
   `### Cost` subsection, unedited.
5. **The version.** Set `version` in `.claude-plugin/plugin.json` (never in `marketplace.json`) and
   the README's `Current version:` line to `<version>`.
6. **The status-line marker**, only if `skills/setup/references/statusline.sh` changed since the
   previous tag: raise its `# ds-statusline: managed v<x.y.z>` line to `<version>`. Otherwise leave
   it alone.
7. **Commit, then check the commit.** Commit everything as `release: v<version>` (no item
   numbers, no session trailer — this repository is public). Both checks read COMMITTED history,
   never the work tree, so they run after the commit:
   `bash scripts/check-version-bump.sh --base origin/main` must pass and
   `bash scripts/check-public-hygiene.sh --base origin/main --branch "$(git branch --show-current)"`
   must print `CLEAN`. On a failure, fix it, `git commit --amend`, and run both again. Then push.

The pull request then goes through the delivery loop's review. Never tag by hand and never push
to `main`: the merge is the release, and the workflow tags it.

## verify

Run after the release pull request merges.

1. **The tag.** Poll `git ls-remote --tags origin devstride--v<version>` every 20 seconds for up to
   10 minutes; the workflow's run is the cause when it does not appear (`gh run list --workflow
   release-guard.yml --branch main`). Confirm the tag's commit is on `main`.
2. **A scratch install.** In a new empty directory, `git init`, then
   `claude plugin marketplace update devstride` and
   `claude plugin install devstride@devstride --scope project` (or `claude plugin update
   devstride@devstride --scope project` where it is already installed), and read
   `claude plugin list --json`: the project row must report `<version>`. Delete the directory.
3. Report the tag, its commit and the installed version, and say that installations pick it up at
   their next session start (where `plugin.autoUpdate` allows) or through `/devstride:update`.
