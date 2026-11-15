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

## The driver — before the fetch that fixes the snapshot

1. List the declarations: `list_claims` (kind `ship-intent`, state `all`, limit 200; a `commands`
   provider's `list`). A failure is `{"error": "<NAME>"}`, never an empty list.
2. The held units, when any peer unit has a release hold
   (`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/release-holds.md`) or an open Needs-you
   notice: their unit keys. Unknown → leave it out.
3. **Never decide by eye**: `python3 ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/ship-plan.py
   decide`, stdin `{now, peerWaitMinutes, enabled, train, me, claims, plan, held, goNow, tz}`.
   `me` is this session's holder digest(s) and session id; `plan` is the one already on the
   `release-train` claim's payload, else null.
4. `wait` → heartbeat the `release-train` claim with phase `gathering` and payload `{"plan":
   <its plan>}` (the one payload key this adds to the record; sent whole, never edited by hand),
   say its `message` once, wait about a minute (in the background, never a held foreground
   sleep), and run 1–3 again with that plan. The plan is never widened and its `waitUntil` never
   moves later.
5. `go` → with a plan: heartbeat the claim with the finished plan and the next step's phase,
   say its `message`, and keep `ship-plan.py marker`'s one line for the train pull request body.
   Then carry on with §1 step 3's fetch: what is on the train now is the release. With no plan:
   nothing to record.

A heartbeat that loses the claim STOPs as `auto-start.md` says. The late-arrivals rule, the
backstop, the standing yes and the tower are unchanged.

## The durable record

The train pull request's body carries the marker as a line of its own, beside the range marker:
`<!-- devstride:release-gather waited <minutes> carried <units|none> missed <units|none> -->`.
A claim does not outlive its release; this line does. `ship-plan.py parse` reads it back. A
release that did not gather writes none.

## The peer — a session about to land on the train

At `build-item` step 5, before the merge (and for an epic's release, before its merge): read the
`release-train` claim (`get_claim`, key `<owner>/<repo>`, one row) and pipe it to `ship-plan.py
peer` (stdin `{unit, response, now, tz}`). A `message` is said, once; nothing else changes. The
session still lands, still tries to start its own release afterwards, and simply loses the claim.
A read that fails says nothing.

## Cited by

- `skills/release/references/release-branch.md` §1 step 3 and `skills/release/references/auto-start.md`
- `skills/build-item/references/ship-intent.md` (the peer's side)
- `skills/setup/references/config-defaults.md` (`release.coordination.peerWaitMinutes`)
