---
load: contract
---
# The train claim, releases that start themselves, and the standing yes

Three rules, each opt-in. With no `claims` block, `release.autoStart`,
`release.lightRelease.standingYes` and `release.fullRelease.standingYes` unset, nothing here applies.

## The train claim — every release, when a `claims` block is configured

- **Kind `release-train`, key `<owner>/<repo>`** (`python3
  ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/auto-start.py key`). **One lock order, train then
  tower, for every run:** step 0 claims it FIRST — before it adopts an open release pull request,
  before 0a's tower claim, and before 0b opens or adopts a train pull request — for a hand-started
  and an auto-started run alike, so neither ever holds the tower while waiting for the train. (An
  auto start already holds it from its trigger; step 0's claim by the same session refreshes it.) The
  calls, holder, verdicts and takeover of a lapsed holder are `story-claims.md`'s (build-item's
  references) with this kind and key; decide with its `story-claim.py decide`, item `the release
  train`, mode `named` for a hand-started run and `select` for an auto start. Expiry:
  `claims.expiryMinutes["release-train"]`, else 30.
- **Never degrades.** `decide` answering `degrade` (the store unreachable, unsupported or
  forbidden) does NOT mean "carry on without it" here: an auto start does nothing, saying so once;
  a hand-started run STOPs, naming the outage (another session may hold the claim it cannot read).
  Once won, a heartbeat that degrades cannot prove the claim is still held: STOP too. The marker-only
  rule of `clearance.md` is for repositories with no `claims` block. No train pull request is opened, adopted or pushed to without a won claim or,
  in that fallback, the marker check.
- **Heartbeat** at each step transition and through EVERY wait until the release — review, CI, the
  train's pre-ship suites, the clearance wait — at least every `min(10, expiry ÷ 3)` minutes
  (phase: the step). NOT HOLDER or LOST to a live holder → STOP: another session owns the train
  phase now. A wait for a person (step 4's yes) cannot heartbeat, so a claim still held there (no
  hand-on, below) may lapse: on the owner's answer, heartbeat it before anything else; NOT HOLDER or
  LOST → with the tower held, carry on under the tower (it protects this release pull request, and
  the new holder waits at the tower), else STOP before merging (another session may have adopted
  the pull request).
- **Release it NON-final**: `release` with outcome `handed-on`, never `done` and never final
  (`final: true`, `--final`), so the next cycle can claim it. It is handed on once 0c has cut the
  release branch while this run holds the tower, so the next train phase runs during the deploy, but
  ONLY with `release.clearance` and `release.releaseBranchPattern` both set (5b's train leveling
  later re-claims it, `release-branch.md` §2 step 3); without either, the
  release pull request has no tower or its own branch to protect it, so the claim is held until the
  run ends. A train with nothing to ship changes neither point: the claim waits for the cut (or, held,
  for the run's end). Released early only when the whole run ends: nothing to ship at all, or stopped.
- **Another release in flight.** A live session holding the tower owns its release pull request:
  this run never adopts it (step 0) and, under `cut-to-deploy`, runs 0b under the train claim, then waits at the tower claim
  and, once cleared, re-reads step 0's shape before cutting (`clearance.md`).
- **Lost to a live holder**: a hand-started run names who holds it and STOPs; an auto start carries
  on with its caller's loop, logging no failure.
- **Won with an open train pull request present** (its previous holder lapsed): `release-branch.md`
  §1 step 2 ADOPTS it, never opens a second. The old session learns at its next heartbeat and stops.
- **The holder marker stays, and the claim decides it.** The train pull request body still carries
  `clearance.md`'s `release-train-holder` marker, written from this session's identity. On a won
  claim a marker is adoptable when it is this session's or names the holder whose lapsed claim this
  one took over (the marker's digest is a prefix of that claim's `holderDigest`). Every train pull
  request opened with a `claims` block carries it (`release-branch.md` §1 step 4), so an ABSENT
  marker is ambiguous, as is any other: a session that never held the claim (one on an older
  plugin) may own it. STOP, name it, adopt only on the owner's yes and their word that it stopped.

## Auto start — `release.autoStart.enabled`

Honoured only with a `claims` block (doctor: an ERROR; at run time it does nothing). Triggers:

1. `build-item`, after a one-off lands on the release train (`release-train.md`);
2. `build-item`, after step 8 merges an epic release pull request onto the train
   (`epic-release-steps.md`);
3. `release`, at the end of step 6, after its own close-out;
4. `build-item`, at every clean story boundary (step 7's sync, after ANY story lands, epic stories
   included) and when its loop starts. A trigger lost to a live holder is never retried by itself,
   and the release that holds the claim hands it on at its cut so the next train phase can run
   during the deploy; this is the look that notices the hand-on.

At a trigger run `python3 ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/auto-start.py check`
(it fetches the train and the release source; a renamed train is an `ERROR` naming the cutover). `SKIP <reason>` → carry on, saying nothing;
`ERROR` → say it once and carry on. `START …` → claim the train (above, mode `select`): lost → carry on
silently; won → invoke **`release`** in this session, declaring `started-by: auto`; its step 0b
finds and adopts any open train pull request itself. When that release stops — at the owner's yes,
or merged — return to the caller's own loop. The caller keeps its checkout lease until then and
the release runs in that checkout; it is returned only after (a pool member handed back mid-release
could be leased by another session while the release still uses it). Never resume, message or adopt another session's
release; the fleet's hourly machine check never starts one. No batching wait: each release carries
whatever landed during the previous cycle, and there is never a second concurrent release.

**The backstop** (`release.backstop.mode` shadow or live) enters this same path, on a schedule, only
when landed work has waited too long. Read
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/backstop.md` in full before acting on a backstop check.

## Unattended stop

A `started-by: auto` release that reaches step 4 without a MERGE from the standing yes sends ONE
`PushNotification` (where the tool exists): the release, READY or BLOCKED, why it is not eligible
(the `ASK` reason, or "standing yes off"), and the pull request link. With `needsYou.label` set it
also queues a NOTICE (build-item's `needs-you.md`): no reply to it can start the merge. Then it
waits for the yes, holding the tower as any release does — under scope `merge-and-deploy`, after
stepping aside (`clearance.md`).

## The standing yes — `release.lightRelease.standingYes`, `release.fullRelease.standingYes`

At step 4, after the pre-merge check and the recap, run
`python3 ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/standing-yes.py --pr <n> --head <head>
--class "<classify-release line>" --checks green|red --unresolved <count>
--pre-ship "<2b verdict line>" --pre-merge "<pre-merge-check verdict line>" --previous-release <gate exit> --dev-deploy <exit>|not-applicable --tower
"<provider status output>" --reviewed-head <reviewedHead>`. `--head` is the release pull request's
head; `--reviewed-head` is step 2's `<reviewedHead>`. With `release.devDeployVerification` set the
dev-deploy wait runs BEFORE this check, whatever the delta, and passes its exit (scope
`merge-and-deploy`: `--pre-ship` and `--dev-deploy` come from 0p, and `--tower` is read after the
claim or re-claim); unset,
`not-applicable` (omitting it is an ERROR). The script reads the config from the head itself and
prints `MERGE <sha>` and a `COMMENT <text>` line only when one route's conditions all hold (its
header lists them); anything else prints `ASK <reason>`. Without `release.clearance` there is no
`On final` line, so it always asks.

- **Light route** (`release.lightRelease.standingYes`): a `LIGHT` release whose tree equals the
  reviewed train's (the script finds that train itself, by `release-branch.md`'s two-title
  search), a classifier configured, and every gate below.
- **Full route** (`release.fullRelease.standingYes`: the owner's WRITTEN yes, dated by
  `ownerDecision`): a `LIGHT` or `FULL` release, non-draft, at exactly `<reviewedHead>` (or
  review's same-tree re-trigger), and every gate below, and every migration file it adds or
  changes (`migrationGlobs`, against `origin/<productionBranch>`) approved BY CONTENT: its blob id
  is an `approvedMigrations` entry. A new or changed migration, or a deleted one, asks.
- **Gates, both routes**: every required check green, zero unresolved threads, pre-ship
  `PASS (<n> ran, 0 waived)` or `NOTHING TO RUN`, pre-merge `CLEAR` (`NOT CONFIGURED` only with no
  hook), the previous-release gate 0, the dev-deploy wait 0, and this pull request alone `On final`.
- **Approving a migration** happens only on the owner's own words, in the moment, never on a
  relayed yes: add `{"blob": "<git rev-parse HEAD:<path>>", "path", "item": "I#####", "approved":
  "<today>"}` to `release.fullRelease.approvedMigrations` in a commit of its own (`approve
  migration <path> [I#####]`). The blob pins the content: a renumber keeps it; any edit needs a new
  approval. The script cannot tell who wrote an entry, so step 4's recap and the merge comment name
  every approved migration the release carries, and the owner sees each one.
- **`MERGE <sha>`** is the owner's yes for this pull request at exactly `<sha>`: run step 4's "On
  the yes" checks, merge with the `MERGE` line of `merge-gate.py <n> <sha> --all-green` (step 4), and 5a approves the deploy on
  the same yes. Post the `COMMENT` line's text as ONE comment on the pull request.
- **`ASK` or `ERROR`** → the owner's in-the-moment yes, exactly as before. A waived pre-ship check,
  a pre-merge `HOLD` or `NOT RUN`, a failed previous release or an unapproved migration always
  asks. A return to step 2 voids it like any yes.
