---
load: contract
---
# The ship plan — a starting release waits a short, fixed time for a nearly-ready peer

**Goal:** work a peer session says is nearly ready rides THIS release, not a second one with its
own cloud tests and deploy. The wait is at most `release.coordination.peerWaitMinutes` (15), is
fixed when the release starts and never extended; with nobody nearly ready there is no wait at
all. Reading declarations decides only how long the driver waits, **never who drives**: the
`release-train` claim does that.

## When it applies

With a `claims` block, `release.coordination.enabled` not `false` and `peerWaitMinutes` above 0.
Only the session that holds the `release-train` claim runs it, and only on the path that CUTS a
train snapshot (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-branch.md` §1 step 3):
an adopted train pull request already fixed what it carries. A hotfix never waits and is never
waited for. The person saying "go now" is `goNow: true` for that release.

## Who is nearly ready

Another live session's declaration (never the driver's own) on route `train` or `epic-release`
whose `target` is the release train, not held, and either at stage `verifying` or `landing` or
with a `readyBy` still ahead and inside the window. A build past its estimate is not nearly
ready. The script decides this; the list is here so a person can predict it.

## The driver — before the fetch that fixes the snapshot

1. **The plan already on the claim**: `get_claim` (kind `release-train`, key `<owner>/<repo>`) and
   take its payload's `plan`; null ONLY when the read succeeded and there is none. A read that
   failed is passed as `{"error": "<NAME>"}`, which ends the wait. Read it back every time, after
   a compaction too: passing null while one exists would start a second wait.
2. **The declarations**: `list_claims` (kind `ship-intent`, state `live`; EVERY page, following
   `cursor`; a `commands` provider's `list`), plus, for each member of an existing plan not in
   that list, its own row (`get_claim`, kind `ship-intent`, key the unit, `includeReleased`): the
   rows together. No time cutoff: a member missing from the rows reads as dropped. A failure is
   `{"error": "<NAME>"}`, never an empty list.
3. **The held units**, once, when the plan is first made: the unit keys of peers under a release
   hold (`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/release-holds.md`) or with an open
   Needs-you notice. Unknown → leave it out.
4. **Never decide by eye**: `python3 ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/ship-plan.py
   decide`, stdin `{now, peerWaitMinutes, enabled, train, me, claims, plan, held, goNow, tz}`.
   `me` is `{"holderDigests": [<story-claim.py digest of this session's holder>], "sessionIds":
   [<claim_record.py's payload.sessionId>]}`.
5. `wait` → heartbeat the `release-train` claim with phase `gathering` and the record's payload
   plus ONE key more, `plan` (its plan, whole, never edited by hand: the exception
   `story-claims.md`'s record rule allows here, as `backstop.md` has its own). Say its `message`
   once. Then wait in the background — the shorter of a minute, the claim's heartbeat cadence
   (`auto-start.md`) and the time left — and run 1–4 again. Stop waiting after
   `peerWaitMinutes` of this session's own elapsed time whatever the script says.
6. `go` → with a plan: heartbeat the claim with the finished plan and the next step's phase, say
   its `message`, and keep `ship-plan.py marker`'s one line for the train pull request body. Then
   carry on with §1 step 3's fetch: what is on the train now is the release. With no plan:
   nothing to record.

**When it cannot run, the release goes.** `decide` or `marker` exiting non-zero → no wait, no
marker, said once. A provider that refuses the `plan` payload → heartbeat again WITHOUT it and go
without waiting. Neither loosens `auto-start.md`'s rule: the claim's ordinary heartbeat must
still succeed before the snapshot is cut, and one that is lost or degrades STOPs as it says. The wait happens
inside the train phase, so it holds the tower only under scope `release`, which holds it through
that phase already. The late-arrivals rule, the backstop and the standing yes are unchanged; an
absorbed late arrival does not rewrite the marker.

## The durable record

The train pull request's body carries the marker as a line of its own, beside the range marker:
`<!-- devstride:release-gather waited <minutes> carried <units|none> missed <units|none> -->`.
A claim does not outlive its release; this line does. `ship-plan.py parse` reads it back. A
release that did not gather writes none.

## The peer — a session about to land on the train

At `merge-story`, before the merge (and for an epic's release, before its merge): read the
`release-train` claim (`get_claim`, key `<owner>/<repo>`, one row; a `commands` provider's `get`,
when it has one) and pipe it to `ship-plan.py peer` (stdin `{unit, declaration?, response, now,
tz}`). A `message` is said, once; nothing else changes. The session still lands, releases its
declaration with outcome `landed` (that is what the driver counts as carried), still tries to
start its own release afterwards, and simply loses the claim. A read that fails, or no `get`,
says nothing.

## Cited by

- `skills/release/references/release-branch.md` §1 step 3 and `skills/release/references/auto-start.md`
- `skills/build-item/references/ship-intent.md` (the peer's side)
- `skills/setup/references/config-defaults.md` (`release.coordination.peerWaitMinutes`)
