---
load: contract
---
# Work out the release delta — what this release carries, and whether anything holds it

`release-steps`' `release-delta@1` step, the first step of the cut. It reads only and writes
nothing. Its `<sourceHead>` is the SHA every later check compares against
(`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-branch.md` "Where the cut point is
read").

1. **Config wins.** Load `.claude/ds-config.json`: `release.releaseSource` (shipped default
   `develop`) and `release.productionBranch` (`master`). `git fetch origin <productionBranch>
   <releaseSource>`.
2. **Record `<sourceHead>`** by the payload's `shape`
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`):
   - `NEW` → the `origin/<releaseSource>` tip just fetched (where the cut will be made).
   - `ADOPTED` → the adopted branch's cut point, from its pull request's
     `<!-- devstride:release-branch <name> cut <sha> -->` marker (no marker: `git merge-base
     origin/<name> origin/<releaseSource>`, said so); with no `release.releaseBranchPattern` the
     pull request is headed by the source, so its `origin/<releaseSource>` tip.
   - `MERGED` → the merged release's own range (its merge commit's first parent to its second),
     so the close-out names what shipped. Never `NOTHING TO RELEASE` here: that would end the run
     before its close-out. No holds are read for code already in production.
3. **Nothing ahead** (`NEW`): `git rev-list --count origin/<productionBranch>..<sourceHead>` is
   `0` → `NOTHING TO RELEASE`. The run ends; nothing is cut.
4. **The delta.** `git log --first-parent origin/<productionBranch>..<sourceHead>` and the pull
   requests merged in that range (`gh pr list --base <releaseSource> --state merged`, kept only
   when the merge commit is in the range): the epics and stories that landed, the **user-facing**
   subset (UI, API, behaviour, permissions, migrations) against the internal rest, and any
   breaking change or migration called out. Report it in plain words: it drives the release pull
   request's body and the documentation plan.
5. **Release holds** on every item in the delta, with its ancestors, by the helper in
   `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/release-holds.md`. Held → `HELD`, naming
   the item and its reason: the run stops before anything is cut. The review checks them again at
   every recompute.
6. **No freeze.** Open pull requests into the source are never settled, parked or waited for; a
   leftover `ci` freeze switch is ignored, said so.
7. Answer `ITEMS <n> at <sourceHead>`: the work items the delta carries (the merged pull requests
   when no merge names one, said so), then the full SHA. The runner keeps that line.

## Verdict

`RELEASE DELTA: ITEMS <count> | NOTHING TO RELEASE | HELD <reason>`

## Result

`state`: `items`, `nothing-to-release` or `held`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-branch.md`
