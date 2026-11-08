---
name: plugin-release
description: "Cut a release of this plugin: `prepare [major|minor|patch]` validates, moves the CHANGELOG, adds the cost table, bumps the version and README line and commits `release: v<version>` on the release branch; `merge <pr>` merges a clean, green pull request under the owner's standing yes and leaves the audit comment; `verify` waits for the tag the release-guard workflow pushes after the merge and proves a scratch project installs it. A maintainer skill of this repository, never shipped."
---

# plugin-release

The release of this plugin is a pull request into `main`: its head carries the version bump,
the CHANGELOG heading, the README line and the cost table, and once it merges the
`release-guard` workflow tags `devstride--v<version>`. This skill does the two halves around that
merge. RELEASING.md says what each version component means and why the version is the update
signal; read it before choosing the bump.

Every message to a person says what happened in plain words, and ends with one result line:

- `PLUGIN RELEASE: PREPARED v<version> on <branch> (<sha>)`
- `PLUGIN RELEASE: MERGED #<pr> at <head> under the standing yes of <date>`
- `PLUGIN RELEASE: OWNER YES NEEDED #<pr>: <reason>` — the standing yes does not apply; ask the
  owner on this pull request and merge only on their own typed yes (a relayed yes is not theirs)
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
6. **The seam registry.** Set every `"since": "unreleased"` in `schemas/seam-registry.json` to
   `"<version>"`, then `python3 scripts/build-config-schema.py --write` (the schema's `$id` and the
   key table carry the new version). `python3 scripts/build-config-schema.py --check --release --base origin/main`
   must print `SCHEMA: ok`: an `UNRELEASED` or `DRIFT` line blocks the commit, exactly as the
   release guard would block the pull request.
7. **The status-line marker**, only if `skills/setup/references/statusline.sh` changed since the
   previous tag: raise its `# ds-statusline: managed v<x.y.z>` line to `<version>`. Otherwise leave
   it alone.
8. **Commit, then check the commit.** Commit everything as `release: v<version>` (no item
   numbers, no session trailer — this repository is public). Both checks read COMMITTED history,
   never the work tree, so they run after the commit:
   `bash scripts/check-version-bump.sh --base origin/main` must pass and
   `bash scripts/check-public-hygiene.sh --base origin/main --branch "$(git branch --show-current)"`
   must print `CLEAN`. A finding in the release commit: fix it, `git commit --amend`, and run both
   again. A finding in an EARLIER commit's message (a session trailer an agent harness added, an
   item number): amend cannot reach it, so rebuild the branch's history without it — for example
   `git reset --soft origin/main` and re-commit the work in clean commits — then run both again.
   Then push (`--force-with-lease` after a rebuild; never onto `main`).

The pull request then goes through the delivery loop's review. Never tag by hand and never push
to `main`: the merge is the release, and the workflow tags it.

## merge <pr>

Run once the pull request's review has settled. The owner's standing yes
(`.claude/standing-yes.md`) replaces the per-pull-request question only when every check below
holds at one exact head. The first one that fails stops here with `OWNER YES NEEDED` and its
reason; nothing is merged and nothing is bypassed.

1. **The standing yes is in force.** Read `.claude/standing-yes.md` at `origin/main` (`git fetch`
   first; never the branch's copy, which the pull request could have edited): it exists and says
   `Status: in force`. Note its date and the commit it was read at.
2. **The pull request qualifies.** `gh pr view <pr> --json state,isDraft,baseRefName,headRefOid,headRepository,isCrossRepository,author,files`:
   open, not a draft, base `main`, not cross-repository, and its author has `admin` permission
   (`gh api repos/{owner}/{repo}/collaborators/<login>/permission`). Record `<head>` = `headRefOid`.
   Its files include neither `.claude/standing-yes.md` nor anything under
   `.claude/skills/plugin-release/`: those always need the owner's own yes.
3. **The review settled clean.** The last local review round (Claude and Codex) on `<head>` found
   no P1 and no serious P2, and `python3 skills/review/scripts/reviewed-status.py verify <head>
   --pr <pr> --base main` prints `REVIEWED`. After that clean round, the proof is posted with
   `python3 skills/review/scripts/reviewed-status.py post <head> --pr <pr> --base main`, never
   before it and never to get past this step.
4. **The local checks pass at `<head>`** (a clean tree checked out at exactly `<head>`):
   `bash scripts/check-version-bump.sh --base origin/main`, `bash scripts/check-neutrality.sh`,
   `bash scripts/check-public-hygiene.sh --base origin/main`, and `bash scripts/validate.sh
   --needles` (in the background, read from its log, never piped through `head`).
5. **Every check is green on `<head>`.** `python3 skills/pr/scripts/merge-gate.py <pr> <head>
   --all-green --repo devstride/claude-plugin` prints `MERGE <command>`; run exactly that command.
   `REFUSE` or `ERROR` stops with its reason (wait for pending checks first; a red check is never
   merged).
6. **The audit comment**, on the pull request at once (`gh pr comment <pr> --body-file <file>`):

   ```
   <!-- devstride:standing-yes -->
   Merged under Phil Reynolds's standing yes of <date> (`.claude/standing-yes.md` at <short sha>).
   - Head: <head>
   - Checks: every check green on that commit (merge gate, `--all-green`): <name: result, ...>
   - Review: <rounds> local rounds (Claude and Codex); the last found no P1 and no serious P2.
     Review proof: `devstride/reviewed` by <login>.
   - Local checks: version bump, neutrality, public hygiene and the validator passed.
   ```

   No item numbers, no session links, no AI attribution: this repository is public. A failed
   comment is reported and retried; the merge stands.

Then run `verify` when the pull request carried a release.

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
