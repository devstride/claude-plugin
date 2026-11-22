---
load: contract
---
# Work out the release delta — what ships, from which commit, and whether anything is held

`release-steps`' `release-delta@1` step, the first step of the cut. It reads only: nothing is
cut, pushed or opened here. The hold rule is
`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/release-holds.md`, cited, not copied.

1. **Config wins.** Load `.claude/ds-config.json`: `release.releaseSource` (shipped default
   `develop`), `release.productionBranch` (`master`), `release.releaseBranchPattern`,
   `release.clearance`, `release.holdTimeZone`. Scope `merge-and-deploy` with no
   `release.releaseBranchPattern` → `HELD`, naming the key: there is no branch to bring production
   into (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/clearance.md` "Scope `merge-and-deploy`").
2. `git fetch origin <productionBranch> <releaseSource>`.
3. **Record `<sourceHead>`**, the SHA the delta is computed from and every later integrity check
   compares against, never the branch tip
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md` for the shape):
   - `NEW`: the `origin/<releaseSource>` tip. Not ahead of `origin/<productionBranch>` →
     `NOTHING TO RELEASE`; the run ends there.
   - `ADOPTED`: the adopted branch's cut point, read from the pull request's
     `devstride:release-branch` marker
     (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-branch.md` §2; with no marker its
     fallback, said). An adopted release is never `NOTHING TO RELEASE`.
   - `MERGED`: the merged release's own range, `<merge>^1..<merge>^2`. Nothing is checked for
     holds (it already shipped); the count feeds the documentation steps.
4. **No freeze.** Open pull requests into the release source are never settled, parked or waited
   for; a leftover `ci` freeze switch is ignored, said.
5. **Compute the delta** from `git log --first-parent origin/<productionBranch>..<sourceHead>`
   and the pull requests merged in that range (`gh pr list --base <releaseSource> --state
   merged`): the epics and stories that landed, the **user-facing** subset (UI, API, behaviour,
   permissions, migrations) against the internal one, and any breaking change or migration,
   called out. It drives the pull request body and the documentation payload; the class is the
   next step's (`classify-release`, `head: <sourceHead>`).
6. **Release holds, over every item in the delta** and its ancestors, decided by the script
   `release-holds.md` names, never by eye. Any held → `HELD`, naming the item and why: wait for
   the hold to lift, or the owner removes its line. The same check runs at every recompute.
7. Otherwise `ITEMS`, the count being the items in the delta. The first evidence line is
   `sourceHead <sha>`, kept in the run's record: later steps read it back from the run's
   `status` rather than from memory.

## Verdict

`RELEASE DELTA: ITEMS <count> | NOTHING TO RELEASE | HELD <reason>`

## Result

`state`: `items`, `nothing-to-release` or `held`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
