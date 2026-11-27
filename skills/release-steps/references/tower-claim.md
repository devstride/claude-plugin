---
load: contract
---
# Claim the tower — one cleared release at a time

`release-steps`' `tower-claim@1` step: the same step wherever the clearance scope puts it (right
after the train claim under scope `release`, just before the cut under `cut-to-deploy`, at the
final gate under `merge-and-deploy`). The contract is
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/clearance.md`, cited, not copied and unchanged:
its provider commands, exit codes and "Where the release skill calls it".

1. **Config wins.** Load `.claude/ds-config.json`. No `release.clearance` block →
   `NOT APPLICABLE`, with nothing more said. A hotfix never claims.
2. **Claim in the BACKGROUND with a long timeout**: a call a tool kills yields no verdict, and no
   verdict is exit `1`. The call is `claim --wait --purpose release`; at the final gate of
   `merge-and-deploy` it is `claim --wait --branch <release branch> --pr <n>`, followed at once
   by `heartbeat final`. The branch and number: the payload's `shape` when it is `ADOPTED`; when
   it is `NEW` (its `pullRequest` and `branch` are null: this run cut and opened them after the
   shape was read), `open-release-pr`'s `pullRequest` (the runner's `status` with `evidence`
   `true`, never memory) when it carries this session's `devstride:release-holder` marker, else
   the open release pull request into the production branch with that marker; another holder's
   is never adopted silently
   (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/clearance.md` "Scope `merge-and-deploy`").
   Then that pull request's head branch. It must be open. None, more than one, or closed →
   `ERROR`, saying so.
3. **While it waits** (the provider polls every 60 seconds, up to `waitMinutes`), say who holds the
   tower, shown as waiting through the runner's `wait`, and heartbeat the train claim while this
   run holds it (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
   "Heartbeats").
4. **Act on the exit, exactly:**
   - `0` → `CLEARED`; say who was waiting when stderr said so. Nothing reads the shape again:
     a release left stale meanwhile ends the wait with exit `3`. Under `cut-to-deploy` with a
     `claims` block, the next step (the cut, `release-branch`) levels the train again first,
     under the train claim this run still holds.
   - `2` (still held when the wait ran out) → `BUSY`, naming the holder. The run stops; nothing
     is cut or merged uncleared.
   - `3` → `STALE`, naming the pull request. Ask the owner once: adopt the named branch and pull
     request, or keep waiting. On the owner's yes in the payload's `answer`, run `adopt --yes`,
     record `adopted: true` and answer `CLEARED`; "keep waiting" runs the claim again.
   - `5` → `STUCK`. Tell the owner ONCE (a push notification where there is one) the line's phase,
     minutes, machine and session, then on the next attempt run `claim --wait --ignore-stuck`.
     Adopting a release that is still alive needs the owner's yes AND their word that its session
     has stopped: only then `adopt --yes --original-stopped`, `adopted: true`, `CLEARED`.
   - `1`, or no verdict → `ERROR`, a release blocker. Never proceed uncleared.
5. A yes is read only from the payload's `answer`, in the owner's own words; it is never written
   for them and never carried over from an earlier attempt.

## Verdict

`TOWER CLAIM: CLEARED | NOT APPLICABLE | BUSY <holder> | STALE <pr> | STUCK <holder> | ERROR <reason>`

## Result

`state`: `cleared`, `not-applicable`, `busy`, `stale`, `stuck` or `error`; `adopted`: true only
when this step ran `adopt`, so every later step takes the adopted path.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
