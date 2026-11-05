---
load: contract
---
# The train claim, releases that start themselves, and the standing yes

Three rules, each opt-in. With no `claims` block, `release.autoStart` and
`release.lightRelease.standingYes` unset, nothing here applies.

## The train claim — every release, when a `claims` block is configured

- **Kind `release-train`, key `<owner>/<repo>`** (`python3
  ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/auto-start.py key`). Step 0b claims it BEFORE it
  opens or adopts a train pull request, for a hand-started and an auto-started run alike. The
  calls, holder, verdicts and takeover of a lapsed holder are `story-claims.md`'s (build-item's
  references) with this kind and key; decide with its `story-claim.py decide`, item `the release
  train`, mode `named` for a hand-started run and `select` for an auto start. Expiry:
  `claims.expiryMinutes["release-train"]`, else 30.
- **Never degrades.** `decide` answering `degrade` (the store unreachable, unsupported or
  forbidden) does NOT mean "carry on without it" here: an auto start does nothing, saying so once;
  a hand-started run falls back to the holder-marker rule of `clearance.md` for this run, as with no
  `claims` block, but ONLY at the first claim, before any train mutation. Once won, a heartbeat that
  degrades cannot prove the claim is still held: STOP. No train pull request is opened, adopted or pushed to without a won claim or,
  in that fallback, the marker check.
- **Heartbeat** at each step transition and through EVERY wait until the release — review, CI, the
  train's pre-ship suites, the clearance wait — at least every `min(10, expiry ÷ 3)` minutes
  (phase: the step). NOT HOLDER or LOST to a live holder → STOP: another session owns the train
  phase now.
- **Release it NON-final**: `release` with outcome `handed-on`, never `done` and never final
  (`final: true`, `--final`), so the next cycle can claim it. It is handed on right after the tower
  `claim` at the cut succeeds, so the next train phase runs while this release holds the tower, but
  ONLY with `release.clearance` and `release.releaseBranchPattern` both set; without either, the
  release pull request has no tower or its own branch to protect it, so the claim is held until the
  run ends. A train with nothing to ship changes neither point: the claim waits for the cut (or, held,
  for the run's end). Released early only when the whole run ends: nothing to ship at all, or stopped.
- **Another release in flight.** A live session holding the tower owns its release pull request:
  this run never adopts it (step 0), but runs 0b under the train claim, then waits at the tower claim
  and, once cleared, re-reads step 0's shape before cutting (`clearance.md`).
- **Lost to a live holder**: a hand-started run names who holds it and STOPs; an auto start carries
  on with its caller's loop, logging no failure.
- **Won with an open train pull request present** (its previous holder lapsed): `release-branch.md`
  §1 step 2 ADOPTS it, never opens a second. The old session learns at its next heartbeat and stops.
- **The holder marker stays, and the claim decides it.** The train pull request body still carries
  `clearance.md`'s `release-train-holder` marker, written from this session's identity. On a won
  claim a marker is adoptable when it is this session's, absent, or names the holder whose lapsed
  claim this one took over (the marker's digest is a prefix of that claim's `holderDigest`). Any
  other marker belongs to a session that never held the claim (one on an older plugin): STOP, name
  it, adopt only on the owner's yes and their word that it stopped.

## Auto start — `release.autoStart.enabled`

Honoured only with a `claims` block (doctor: an ERROR; at run time it does nothing). Triggers:

1. `build-item`, after a one-off lands on the release train (`release-train.md`);
2. `build-item`, after step 8 merges an epic release pull request onto the train
   (`epic-release-steps.md`);
3. `release`, at the end of step 6, after its own close-out.

At a trigger run `python3 ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/auto-start.py check`
(it fetches the train and the release source). `SKIP <reason>` → carry on, saying nothing; `ERROR`
→ say it once and carry on. `START …` → claim the train (above, mode `select`): lost → carry on
silently; won → invoke **`release`** in this session, declaring `started-by: auto`; its step 0b
finds and adopts any open train pull request itself. When that release stops — at the owner's yes,
or merged — return to the caller's own loop. Never resume, message or adopt another session's
release; the fleet's hourly machine check never starts one. No batching wait: each release carries
whatever landed during the previous cycle, and there is never a second concurrent release.

## Unattended stop

A `started-by: auto` release that reaches step 4 without a MERGE from the standing yes sends ONE
`PushNotification` (where the tool exists): the release, READY or BLOCKED, why it is not eligible
(the `ASK` reason, or "standing yes off"), and the pull request link. Then it waits for the yes,
holding the tower as any release does.

## The standing yes — `release.lightRelease.standingYes`

At step 4, after the pre-merge check and the recap, run
`python3 ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/standing-yes.py --pr <n> --head <head>
--class "<classify-release line>" --checks green|red --unresolved <count>
--pre-ship "<2b verdict line>" --previous-release <gate exit> --dev-deploy <exit>|not-applicable --tower
"<provider status output>"`. `--head` is the release pull request's head. The script reads its live head
and finds the reviewed train itself: the latest merged train pull request into the release source
(`release-branch.md`'s two-title search), merged into that head; it computes both trees. With
`release.devDeployVerification` set the dev-deploy wait runs BEFORE this check, whatever the delta,
and passes its exit; unset, `not-applicable` (omitting it is an ERROR). `MERGE <sha>` only
when all of its nine conditions hold (the script's header lists them); anything else prints
`ASK <reason>`. Without `release.clearance` there is no `On final` line, so it always asks.

- **`MERGE <sha>`** is the owner's yes for this pull request at exactly `<sha>`: run step 4's "On
  the yes" checks, merge with `gh pr merge --match-head-commit <sha>`, and 5a approves the deploy on
  the same yes. Post ONE comment on the pull request:
  "Merged on the standing yes for light releases identical to the reviewed train
  (release.lightRelease.standingYes, owner decision <the date the owner set it>)."
- **`ASK` or `ERROR`** → the owner's in-the-moment yes, exactly as before. A FULL release, a tree
  that differs from the reviewed one, a waived pre-ship check or a failed previous release always
  asks. A return to step 2 voids it like any yes.
