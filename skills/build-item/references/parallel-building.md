---
load: contract
---
# Parallel building — several agents on one plan, up to a stored limit

**Goal:** a person starts the build command on one plan in a second terminal, in a second checkout,
and that agent takes the next story nobody is building whose prerequisites have landed. How many
agents may build one plan at once is an organization setting stored in DevStride (Parallel building,
under Agents, Fleet; 3 unless changed, 1 for one at a time). Claims decide everything here; a
speed bump, not a lock: a person or an older plugin that never claims is not counted.

Every decision is `python3 ${CLAUDE_PLUGIN_ROOT}/skills/build-item/scripts/plan-slot.py
<decide|mine|free|full|room|machine>` (JSON on stdin; exit 2 is one refusal line), never judged by eye. The
holder, the record and the degrade rules are `story-claims.md`'s; the holder is never printed,
only its digest.

## When it applies

Only with `claims.provider: devstride` and a resolved plan root. A one-off or a hotfix takes no
slot. No `claims` block, or a `commands` provider → no limit; say so once per session.

## The plan slot — taken in step 0

Kind `plan-slot`, key `<plan root>#<n>` (`I20100#2`), expiry the `plan-slot` entry of
`claims.expiryMinutes` when set (outside 1..1440: ignored with a warning), else the server's
default. Taken after `lease-checkout` (a full pool ends the run before any slot), once the plan
root and its release scope resolve, before selection. Kept across loop iterations like the lease;
released (`release_claim`, outcome `released`) at EVERY terminal exit — step 0's, step 7's, a
named or resumed story ending held, step 8's release-ready stop with auto-release off — and when
the session moves to another plan. A STOP keeps it, as it keeps a story claim: the session may
resume.

1. `list_claims` kind `plan-slot`, `keyPrefix` `<root>#`, `state` `all`, `holderDigest` this
   session's, `limit` 500 (other sessions' history never pushes its own row off the page); `mine` with `{root, rows,
   me}` names this session's unreleased slot. One → `claim_work` on its key and `decide` with mode
   `renew`: `proceed` carries on, even above a lowered limit; `next` (it was taken over) → items 2 and 3.
2. Else read the limit: `get_active_agents_settings`' `maxParallelBuilds` (any member may read it),
   and the live slots: `list_claims` kind `plan-slot`, `keyPrefix` `<root>#`, `state` `live`.
   **Room**: `room` with `{root, limit, rows, me, now, tz}` counts the other holders' live slots,
   whatever their number, so a lowered limit holds back new agents while one above it still builds
   (a freed low slot is no room): `full` → Full, below, with its message. Then **one machine, one shared environment**: unless `localEnvironment.instanceBoundTo` is
   `directory` (each checkout its own instance), checkouts on one machine share one local
   environment, test database included, so two agents there would run their tests on it at once.
   `machine` with the same rows and `{root, rows, me, machine (claim_record.py's), shared:
   true|false, now, tz}`: `busy` → say its message, take no slot, `return-checkout` and end, as for
   a full plan; `ok` → item 3. Sessions started together both pass that look, so once a slot is won
   with `shared` true, read the live slots again and run `machine` with `slot` n: `busy` (a
   same-machine holder of a lower slot) → release the slot and end the same way.
3. For n from 1 to the limit: `claim_work` kind `plan-slot`, key `<root>#<n>`, the holder,
   `machine`, `sessionName` and `payload` from `claim_record.py`, purpose "building under <root>";
   `decide` with `{mode: "take", root, slot: n, limit, response, me, now, tz}` (`limit` null when
   the server has no such field). `proceed` → taken; `next` → its `nextSlot`; `takeover` → claim
   once more with its `takeoverDigest` and decide again; `full` → below; `degrade` → build with no
   limit, said once (`story-claim.py`'s reasons, plus an older server with no limit).

Each key has one winner in the database, so sessions racing for the last slot win exactly as many
as are free. **Full** → `list_claims` again (`state` `live`), then `full` with `{root, limit, rows,
now, tz}`: say its message unchanged (it names the agents building, since when in local time, the
setting and where it lives), take no story claim, `return-checkout` (every step-0 exit does) and
end. A story the person named under a full plan stops with the same message.

Progress row `Plan slot`: taken n of L, renewed, full, machine busy, not configured, or degraded
(reason).

## Which story a second agent takes

Selection is `next-unblocked.md`'s rule over the same ready-set; two agents differ only in what the
claims remove. After step 0's fetch and landed-set read, read the live story claims once
(`list_claims` kind `story`, `state` `live`, `limit` 500) and run `free` with the candidates in
rule order, the rows and `me`: it drops every candidate another live holder holds, naming each, and
keeps this session's own (a resume). The first remaining candidate is claimed (`claim-story`, mode
`select`) BEFORE the runner resumes or starts its run, so no other session's run is adopted:
`HELD` → the next candidate, lease kept, no run; any other answer → the run, whose own claim step
renews it. The read saves a claim; the claim decides.

- **Free**: selectable by every rule of `next-unblocked.md` AND not held by another holder's live
  story claim. In Progress with no live claim is free: claims are the only arbiter.
- **Unblocked** is unchanged. So a blocker another agent is still building is not satisfied until
  its merge is on the integration branch on origin, and no agent builds on a branch that lacks it;
  the landed set is derived from `git fetch` and the branch's first-parent merges at EVERY pickup,
  never from handoff memory or another session's report; landed under another release unit counts
  only when Done.
- **Nothing free** → exit with `free`'s message ("Nothing is free right now: N held by other agents
  … M waiting on stories those agents are building …"; pass `waiting`, each candidate blocked only
  by a held one, with its blocker), then release the slot and `return-checkout`. Never wait or
  poll: running the command again picks up later work.

## Two agents on one integration branch

- **Landings.** The remote orders them: the first push wins. A refused push whose fetch shows the
  branch moved answers `MERGE: REFRESHED` (`merge-story`'s fast merge): the base is merged into the
  story, the runner re-earns the local checks and asks again.
- **Never by name.** No story step checks out the shared branch, which another worktree on the
  machine may hold: stories branch from `origin/<branch>`, land from a detached HEAD and sync back
  detached.
- **The first story of an epic.** Two agents may both create its integration branch. Create it
  without checking it out: `git fetch origin && git push origin origin/<from>:refs/heads/<epic branch>`
  (`<from>`: `baseBranch`, or `plan-scope.md`'s epic base). A refused
  push of a NEW integration branch → run the `git ls-remote --heads origin` resolve again and adopt
  the branch that exists; a second name is never minted.

## Exactly one epic release

Step 8 starts from step 7 (the unit at zero after a landing) or from step 0 (the dry-chain's
"awaiting their release", or the recovery close-out). Both first claim kind `epic-release`, key the
release unit's number (plan scope: the plan's unit), expiry the `epic-release` entry of
`claims.expiryMinutes` when set, else the server's default, holder and record as above, through
`story-claim.py decide` mode `select`. `proceed` or `takeover` → step 8 as written (a taken-over
release finds its open pull request through `pr`'s re-entry); `skip` → say "<unit> is being
released by <who>" and carry on with this session's loop, or, reached from the dry chain, exit
(back to step 0 would meet the same held claim); `degrade` → step 8 without the claim,
said once per session, as story claims degrade; `stop` (an answer it could not read) → cut
nothing, say so and stop, the release left for a later run. Auto-release off → no
claim, report release-ready; `"ask"` → the claim comes before the question, so one session asks.
Heartbeat it beside the release's ship-intent stages (`reviewing`, `verifying`, `landing`); release
it after the close-out, outcome `released`, NOT final (a later splice may reopen the unit). A STOP
keeps it; a session that dies leaves it to expire, and the next run's claim takes over.

## Handoff memory and Active Agents

Step 7's handoff keeps one in-progress line per session name, and a resume reads only its own. Each
session already takes its own Active Agents claim, so the plan's tag stays while any one is live.

## Cited by

- `skills/build-item/SKILL.md` — the "Parallel by claim" floor, step 0 (the slot, selection, the
  exits), the working base's new-branch race, steps 7 and 8.
- `skills/build-item/references/next-unblocked.md` — free and unblocked with several agents.
- `skills/build-item/references/story-claims.md` — selection reads the live claims once.
- `skills/build-item/references/epic-release-steps.md` — the release claim.
- `skills/merge-story/references/merge-paths.md` — a refused push on a moved branch.
