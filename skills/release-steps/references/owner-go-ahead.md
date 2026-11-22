---
load: contract
---
# The go-ahead — the recap, then the owner's yes or the standing yes

`release-steps`' `owner-go-ahead@1` step: the same step when the recap is first shown and, under
scope `merge-and-deploy`, again at the final gate. What the recap carries is
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/merge-and-deploy.md` "Step 4 — the human recap";
the standing yes and the unattended stop are
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/auto-start.md`. Both cited, not copied. This is
answered in the session; it is never an approval gate somewhere else.

1. **Config wins.** Load `.claude/ds-config.json`: `release.autoDeployOnMerge` (quoted back,
   never assumed), `stage.resolve`, `release.clearance`, `release.lightRelease.standingYes`,
   `release.fullRelease.standingYes`, `release.devDeployVerification`, `release.deployApproval`,
   `needsYou.label`.
2. **Shape** (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`): `MERGED`
   → `YES (already merged)`, naming the pull request. Nothing is asked and nothing is merged: the
   merge already happened on a yes given then.
3. **Heartbeat.** Send the tower `heartbeat final` as the recap is shown, only when this session
   holds the tower (`resume-rules.md` "Heartbeats"). After a wait for a person, heartbeat the
   train claim before anything else.
4. **Gather what the earlier steps of this run answered**, word for word from their verdict and
   evidence lines (the run's status table keeps each): the release class, the pre-ship result,
   the pre-merge verdict, the previous-release gate's exit, the dev deploy wait's exit, the
   documentation plan, and `<reviewedHead>` from the payload's `releaseReview`. Under scope
   `merge-and-deploy` the pre-ship result and the dev deploy wait's exit are the checks phase's
   (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/auto-start.md`). A line that cannot
   be read is never guessed: the standing yes is not tried, and the recap says what is missing.
5. **Show the recap.** Lead with `READY` or `BLOCKED`, then everything `merge-and-deploy.md`
   lists: each change in plain English, the class, the pre-merge verdict, each pre-ship entry as
   passed at the train, at the checks, skipped by path or waived (never "covered by CI"), the
   documentation plan, the release-notes decision, the consequence notices, what merging triggers
   quoted from `release.autoDeployOnMerge`, "this merge deploys to `<stage>`" when `stage.resolve`
   answers, the provider's `status`, every approved migration the release carries
   (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/migration-approval.md`), and under
   `merge-and-deploy` the checks stamp and the release it was prepared on top of.
6. **The standing yes.** Run `python3
   ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/standing-yes.py --pr <n> --head <head> --class
   "<class line>" --checks green|red --unresolved <count> --pre-ship "<pre-ship line>"
   --pre-merge "<pre-merge line>" --previous-release <gate exit> --dev-deploy
   <exit>|not-applicable --tower "<status output>" --reviewed-head <reviewedHead>`. It prints
   `MERGE <sha>` and a `COMMENT` line only when one route's conditions all hold: post the
   comment's text as ONE comment on the pull request (never twice) and answer `YES (standing)`.
   `ASK` or `ERROR` → the owner decides.
7. **The owner's yes** is read only from the payload's `answer`: their own words, in this
   session, for this pull request at this head → `YES (owner)`. It is never written for them,
   never relayed, never taken from invoking the release, and void once any step returned to
   review. A no → `NO`.
8. **At the final gate** (`merge-and-deploy`, this session now holding the tower): run the
   standing yes again, with `--tower` read after the claim. `MERGE` → `YES (standing)`. Else the
   yes the owner gave this run's earlier go-ahead (its `GO-AHEAD: YES (owner)` line, at the same
   `<reviewedHead>`) is applied → `YES (owner)`. Neither → `NOT YET`.
9. **No yes yet** → `NOT YET`, saying what is waited for. A run the payload's `startedBy` says
   was started `auto` sends ONE push notification where there is one and, with `needsYou.label`
   set, queues one notice (`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/needs-you.md`); no
   reply to that notice can start the merge. Under `merge-and-deploy` the wait holds nothing.

## Verdict

`GO-AHEAD: YES <source> | NOT YET | NO`

## Result

`state`: `yes-owner`, `yes-standing`, `already-merged`, `not-yet` or `no`; `answer`: the owner's
own words when they gave any, otherwise left out.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
