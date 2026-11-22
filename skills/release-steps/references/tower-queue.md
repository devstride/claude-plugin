---
load: contract
---
# Wait in the release queue — first cut, first merged

`release-steps`' `tower-queue@1` step: before the cut, and again at the final gate once the owner
said yes. It claims nothing and writes nothing. The rule is
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/clearance.md` "Scope `merge-and-deploy`" ("The
queue, before the cut"), cited, not copied.

1. **Config wins.** Load `.claude/ds-config.json`. `release.clearance.scope` other than
   `merge-and-deploy`, or a `MERGED` shape
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`) → `NOT APPLICABLE`.
2. **Which read.** This run has an open release pull request (the shape's, or the one whose
   `devstride:release-holder` marker is this session's) → the final-gate read, `--own-pr <n>`:
   only an OLDER release pull request is ahead. None yet → the read before the cut.
3. **Read** `python3 ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/tower-queue.py check
   [--own-pr <n>] --waited-minutes <m>`, `<m>` being the minutes this release has waited in the
   queue so far. Act on the exit:
   - `0` → `CLEAR`. No release is cut while another release pull request is open into
     production, so the release ahead has merged or closed.
   - `2` → wait: read again every 60 seconds, saying which pull request is ahead, and heartbeat
     the train claim while this run holds it (`resume-rules.md` "Heartbeats"). Nothing is cut and
     nothing is claimed while it waits. At the final gate the owner's yes is kept through the wait.
   - `3` → the payload has no `answer` yet: `ASK`, naming the pull request this release waits
     behind. The owner is told ONCE (a push notification where there is one) that it may only
     be waiting for their go-ahead, and that if that release's session has stopped they may say
     adopt. With an `answer` already in the payload the owner has been told: keep waiting as for
     `2`, never asking again.
   - `1` (a config error), or a wait this call cannot carry on → `WAIT`, naming the pull request
     ahead or the error. Unreadable is never clear.
4. **After `release.clearance.waitMinutes`** (default 180) still waiting → `TIMED OUT`, naming
   the pull request ahead.
5. **Adopting the release ahead is never this step's.** It only waits; whose release an open pull
   request is, and how one is adopted, is `resume-rules.md` "Whose release it is".

## Verdict

`QUEUE: CLEAR | WAIT <pr> | ASK <pr> | TIMED OUT <pr> | NOT APPLICABLE`

## Result

`state`: `clear`, `wait`, `ask`, `timed-out` or `not-applicable`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
