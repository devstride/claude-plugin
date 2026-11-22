---
load: contract
---
# Wait in the release queue — first cut, first merged

`release-steps`' `tower-queue@1` step, scope `merge-and-deploy` only, at two positions the
payload's `step` names: `queue` before the cut, and `queue-final` on the yes. The queue's rule is
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/clearance.md` "Scope `merge-and-deploy`", cited,
not copied: no release is cut while another release pull request is open into production, so
releases merge in the order they were cut. It claims nothing and writes nothing.

1. **Config wins.** Load `.claude/ds-config.json`. `release.clearance.scope` is not
   `merge-and-deploy` (or no `release.clearance` block) → `NOT APPLICABLE`. The payload's
   `shape` is `MERGED` → `NOT APPLICABLE`.
2. **Whose pull request is this run's.** At `queue-final`, or when `shape` is `ADOPTED`, this
   run's release pull request is open: pass `--own-pr <n>` (the shape's `pullRequest`, else the
   open release pull request into production whose `devstride:release-holder` marker is this
   session's), so only an OLDER one is ahead. At `queue` with a `NEW` shape, no `--own-pr`.
3. **Read the queue**: `python3 ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/tower-queue.py check
   [--own-pr <n>] --waited-minutes <m>`, `<m>` the minutes this release has waited at this
   position so far.
4. **Act on the exit:**
   - `0` → `CLEAR`.
   - `2` (`WAIT #<n>`, or the status unreadable, which is never clear) → do not cut and do not
     claim: read again every 60 seconds, in the background, heartbeating the train claim while the
     run holds it (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
     "Heartbeats"), and shown as waiting behind `#<n>` through the runner's `wait`
     (`${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/references/workflow-runner.md`). At `queue-final`
     the yes is kept while it waits. Still waiting after
     `release.clearance.waitMinutes` (default 180) → `TIMED OUT #<n>`, naming the pull request
     ahead.
   - `3` (waited `staleMinutes` behind it) → a one-time NOTICE, never a stop
     (clearance.md's rule): tell the owner once per run (a `PushNotification` where there is one)
     which pull request this release waits behind, and that they may say whether that release's
     session has stopped. Record through the runner's `wait` that it was asked (`asked owner
     about #<n>`; the runner's `status` shows it to a later attempt, which does not ask again),
     then keep polling exactly as for `2`, the train claim heartbeated, until `CLEAR` or
     `TIMED OUT`: a stopped run could not heartbeat the train claim it holds, so the claim would
     lapse. An exit `3` after the notice, or with an `answer` in the payload, is read as `2`.
     Nothing here needs the owner's answer to go on, so this step never answers `ASK`. It never
     adopts the release ahead and never cuts beside it: if the owner says that session stopped,
     answer `WAIT #<n>`, saying that release must be closed, or adopted at a tower claim once its
     clearance is stale, before this one can go on.
   - `1` (a config error) → no verdict line, naming the error: the runner stops, never clear.

## Verdict

`QUEUE: CLEAR | WAIT <pr> | ASK <pr> | TIMED OUT <pr> | NOT APPLICABLE`

## Result

`state`: `clear`, `wait`, `ask`, `timed-out` or `not-applicable`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
