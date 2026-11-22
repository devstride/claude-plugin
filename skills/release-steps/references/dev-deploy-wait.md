---
load: contract
---
# Wait for the staging deploy — never merge production over a failed one

`release-steps`' `dev-deploy-wait@1` step. The hook is `release.devDeployVerification`
(`${CLAUDE_PLUGIN_ROOT}/skills/release/references/docs-hooks.md`, its config table), cited, not
copied.

1. **Config wins.** Load `.claude/ds-config.json`. No `release.devDeployVerification`, or a
   `MERGED` shape (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`) →
   `NOT APPLICABLE`.
2. **Does the wait apply here?**
   - Scope `merge-and-deploy`: every release, in the checks before the tower.
   - Any other scope, with a standing yes configured (`release.lightRelease.standingYes` or
     `release.fullRelease.standingYes`): it applies whatever the delta, and runs BEFORE that
     decision (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/auto-start.md` "The standing
     yes").
   - Any other scope, with no standing yes configured: only when the release delta touches a
     `release.releaseBranchFixExclusions` path, and only AFTER the owner's yes. Called before
     the go-ahead was answered in this run → `NOT APPLICABLE`, saying it waits for the yes.
     When this session cannot tell whether the go-ahead was answered (a resumed run), wait: an
     early wait costs minutes, a skipped one could merge over a failed deploy.
   - Otherwise `NOT APPLICABLE`.
3. **`RELEASE_COMMIT`** is the head the release pull request merges FROM THE SOURCE: with a
   release branch, the cut `<sourceHead>` (the pull request's `devstride:release-branch`
   marker), on every round. The source's deploy never carries a release branch's own commits
   until the sync, so a later round passes the first round's answer through and never waits on
   a commit that source will not deploy. Without a release branch, the reviewed head.
4. **Run the command** with `RELEASE_COMMIT` set, and act on the exit:
   - `0` → `SERVING`. A second call for the same commit answers at once.
   - `2` (not deployed yet) → run it again every 60 seconds, for at most 45 minutes, saying it
     is waiting; then `TIMED OUT`.
   - `1`, or anything else → `FAILED`, naming what the command said. Production is never merged
     over a failed development deploy, and no yes lifts that.
5. The evidence names the command, the commit and how long it waited; the run's recap names the
   wait. The standing-yes decision is handed this step's exit, or `not-applicable`.

## Verdict

`DEV DEPLOY: SERVING | FAILED <reason> | TIMED OUT | NOT APPLICABLE`

## Result

`state`: `serving`, `failed`, `timed-out` or `not-applicable`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-stamp.md`
