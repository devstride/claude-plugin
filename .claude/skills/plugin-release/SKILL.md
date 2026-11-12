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
7. **The status-line launcher's marker** is not raised here. Check only: if
   `skills/setup/references/statusline-launcher.sh` changed since the previous tag, its
   `# ds-statusline-launcher: managed v<n>` line must be higher than at that tag (a new file starts at 1); if
   it is not, stop and say so. `statusline.sh` carries no marker.
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

A pull request that changes the standing yes, this procedure, the checks, the workflows or the
instruction files is covered like any other (the owner's words of 2026-11-12: his standing yes
applies here exactly as in the main DevStride repository). It still cannot change the rules for its
own merge, because the merge reads the standing yes, this procedure and both gate scripts from
`main`, as the trusted copy below says. The `merge-path` and `public-hygiene` checks run `main`'s
copy too; `release-guard` runs the pull request's own copy, so review reads a change to it like any
other.

**Trusted copy.** This procedure, the standing yes and both gate scripts are read and run from
`origin/main`, never from the pull request. Run `merge` only in a session started in a clean
worktree of `origin/main` (`git fetch origin && git worktree add --detach <tmp> origin/main`, then
start the session there), so the skill and instructions loaded are main's; a session started in
the pull request's checkout stops with `OWNER YES NEEDED`. Every path below marked *(main)* is in
`<tmp>`. Both gate scripts run with `python3 -I`, so nothing placed beside them is imported. One
worktree serves one merge: the next `merge` starts again in a fresh session from a
fresh worktree of the then-current `main`.

1. **The standing yes is in force.** `<tmp>/.claude/standing-yes.md` *(main)* exists and says
   `Status: in force`. Note its date and `<trusted>` = `git -C <tmp> rev-parse HEAD`, then `git
   fetch origin`: `origin/main` must equal `<trusted>` (otherwise `<tmp>` is stale; stop). Follow
   this procedure as written in
   `<tmp>/.claude/skills/plugin-release/SKILL.md` *(main)*; where it differs from the branch's copy,
   main's wins.
2. **The pull request qualifies.** `gh pr view <pr> --json
   state,isDraft,baseRefName,headRefName,headRefOid,isCrossRepository,author`: open,
   not a draft,
   base `main`, not cross-repository, authored by the owner (`philreynolds`), the account the
   owner's builds run under. Record `<head>` = `headRefOid`. Every commit (`gh api
   repos/{owner}/{repo}/pulls/<pr>/commits --paginate`; the count must equal `gh api
   repos/{owner}/{repo}/pulls/<pr> --jq .commits`, since the list stops at 250) has the owner as
   its GitHub author. Commit authorship alone can be set by anyone who can push, so also read
   every push to the head branch (`gh api "repos/{owner}/{repo}/activity?ref=refs/heads/<headRefName>"
   --paginate`): each entry's `actor` is the owner, and `<head>` is the `after` of one of them. The
   pull request is linked to a tracked work item whose build the owner started; say which item in
   the private tracker comment, never on GitHub.
3. **The review settled clean.** The last local review round (Claude and Codex) on `<head>` found
   no P1 and no serious P2. Only then post the proof, `python3 -I
   <tmp>/skills/review/scripts/reviewed-status.py post <head> --pr <pr> --base main` *(main)*, and
   check it: `verify <head> --pr <pr> --base main` *(main)* prints `REVIEWED`. Never post it to get
   past this step. The proof is this session's attestation, posted under the owner's account.
4. **The local checks passed at `<head>`.** The build ran them in its own checkout before review:
   `bash scripts/check-version-bump.sh --base origin/main`, `bash scripts/check-neutrality.sh`,
   `bash scripts/check-public-hygiene.sh --base origin/main`, and `bash scripts/validate.sh
   --needles` (in the background, read from its log, never piped through `head`); the required
   checks run them again on `<head>`. The merge session itself never runs the pull request's code:
   it would share a machine with `<tmp>`. If they weren't run on `<head>`, stop with `OWNER YES
   NEEDED`. Then confirm `<tmp>` is untouched: `git -C <tmp> status --porcelain --ignored` prints
   nothing and `git -C <tmp> rev-parse HEAD` is `<trusted>`.
5. **Every check is green on `<head>`.** `python3 -I <tmp>/skills/pr/scripts/merge-gate.py <pr>
   <head> --all-green --repo devstride/claude-plugin` *(main)* prints `MERGE <command>`. Right
   before running it, `git fetch origin` and compare `origin/main` with `<trusted>`. If it moved (a
   revocation may have landed), `<tmp>` is stale: stop with `OWNER YES NEEDED` (main moved during
   the merge) and start `merge` again in a fresh session. Then run exactly that command.
   `REFUSE` or `ERROR` stops with its reason (wait for pending checks first; a red check is never
   merged).
6. **The audit comment**, on the pull request at once (`gh pr comment <pr> --body-file <file>`):

   ```
   <!-- devstride:standing-yes -->
   Merged under Phil Reynolds's standing yes of <date> (`.claude/standing-yes.md` at <short sha>).
   - Head: <head>
   - Checks: every check green on that commit (merge gate, `--all-green`): <name: result, ...>
   - Review: <rounds> local rounds (Claude and Codex); the last found no P1 and no serious P2.
     Review proof: `devstride/reviewed`, posted under the owner's account.
   - Local checks: version bump, neutrality, public hygiene and the validator passed.
   ```

   No item numbers, no session links, no AI attribution: this repository is public. A failed
   comment is reported and retried; the merge stands, and the weekly report flags it until the
   comment is there.

**On the owner's own yes** (any `OWNER YES NEEDED`): merge only after the owner types yes for this
pull request in the session, through the same merge gate *(main)*, then comment at once:

```
<!-- devstride:owner-yes -->
Merged on Phil Reynolds's own yes for this pull request, given in the session on <date>.
- Head: <head>
- Why the standing yes did not apply: <reason>
```

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
