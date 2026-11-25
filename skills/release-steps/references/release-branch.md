---
load: contract
---
# Cut the release branch — protected, at the SHA the delta was computed from

`release-steps`' `release-branch@1` step (the step `cut-branch`). The procedure is
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-branch.md` §2 (the name, one release at a
time, the cut) and §3 (the branch is protected), cited, not copied; names are matched by the
anchored rule of `${CLAUDE_PLUGIN_ROOT}/skills/release/references/branch-patterns.md`.

1. **Config wins.** Load `.claude/ds-config.json`. No `release.releaseBranchPattern` →
   `NOT CONFIGURED`: the release pull request is headed by `release.releaseSource` itself. Under
   scope `merge-and-deploy` that is a config error instead → `REFUSED release.releaseBranchPattern`
   (production is brought into a release branch, and without one there is none).
2. **Shape** (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`): `ADOPTED`
   → `ADOPTED <branch>` (its fix-exclusion check ran when the shape was read); `MERGED` →
   `ADOPTED <branch>`, the merged release's branch, with nothing cut. **The payload's `tower`
   with `adopted: true` wins over the shape** (`resume-rules.md` "What the payload carries":
   under `cut-to-deploy` the shape was read before the tower claim adopted): the branch is the
   provider's local record's `branch`
   (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/clearance.md` "The local record"), its pull
   request open or merged alike → `ADOPTED <branch>`, nothing cut and the train not levelled; an
   open one first passes the fix-exclusion check (§3) on its commits above the source (the shape
   never read them): a match → `REFUSED <the matching commit>`. A merged one shipped as it is.
3. **Scope `cut-to-deploy` with a `claims` block**: the release this one waited behind at the
   tower claim may have synced fixes into the source, so first level the train by
   `release-branch.md` §1 step 7's rule, under the train claim this run still holds (a conflict →
   `REFUSED`, naming the files: nothing is cut).
4. **Name it** by §2: the pattern with today's date; taken on origin and the pattern ends in
   `[-n]` → `-2`, `-3`, until free; taken without `[-n]` → `NAME TAKEN <name>`. Check the name
   against the pattern before pushing it.
5. **Heartbeat `cut --branch <name>`** before the push (scopes `release` and `cut-to-deploy`, only
   while this session's local clearance record shows it holds the tower; `resume-rules.md`
   "Heartbeats"). Exit 4 → stop: another session owns this release now.
6. **Cut** at `<sourceHead>`, read as below, never at a re-read `origin/<releaseSource>`:
   `git switch -c <name> <sourceHead> && git push -u origin <name>`. Answer `CUT <name> at
   <sourceHead>`. From here the branch takes new commits only, each passing the fix-exclusion check
   (§3); the marker that records the cut goes into the pull request body at
   `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-pr.md`.

## Where the cut point is read

`<sourceHead>` is never re-read from `origin/<releaseSource>` after the delta: another session's
merge may have moved it. Every step that needs it takes the first of: the release pull request's
`<!-- devstride:release-branch <name> cut <sha> -->` marker once it is open; this run's recorded
verdict for `cut-branch` (`CUT <name> at <sha>`), or before the cut for `release-delta` (`ITEMS
<n> at <sha>`), read from the runner's `status`
(`${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/references/workflow-runner.md`), never from memory;
for an adopted branch with no marker, `git merge-base origin/<name> origin/<releaseSource>`, said
so. With no release branch, the dev deploy wait reads `<reviewedHead>` from the review's recorded
verdict in the same way.

## Verdict

`RELEASE BRANCH: CUT <branch> | ADOPTED <branch> | NOT CONFIGURED | NAME TAKEN <branch> | REFUSED <files>`

## Result

`state`: `cut`, `adopted`, `not-configured`, `name-taken` or `refused`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-delta.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-pr.md`,
  `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/dev-deploy-wait.md` — where the cut point
  is read
