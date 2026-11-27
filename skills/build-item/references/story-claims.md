---
load: contract
---
# Story claims — one agent per story, across machines

**Goal:** two agents reading the same ready-set must not build the same story. A claim is one row
per (kind, key), won by exactly one holder and kept alive by heartbeats. It is a speed bump, not a
lock: a person or an older plugin that never claims can still move the item.

## When it applies

Only when the config has a `claims` block (registry contract for `claims`). No block → no claims, no
heartbeats, no message; build exactly as before. Hotfixes never take a `story` claim. `build-item` never calls
`adopt_claim`; adoption stays the owner's, in `release`.

## The claim

- **Kind `story`, key the item number.** Expiry minutes: the `story` entry of `claims.expiryMinutes`,
  else 240 (outside 1..1440 is ignored with a warning).
- **`provider: devstride`**: call your own DevStride MCP tools `claim_work`, `heartbeat_claim`,
  `release_claim`, `get_claim`. `holder` is the output of
  `${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/clearance-github.sh identity` (one holder rule for
  every claim), the other fields from the record below. The holder is bearer-like: pass it only
  as that argument, never print it, log it or put it in a comment; the server returns its digest
  (`holderDigest`) instead.
- **`commands`**: run `claims.commands.<verb> "story <I#####>"` plus `--purpose`, `--phase`,
  `--expiry`, `--takeover <holderDigest>` (claim), `--phase` (heartbeat), `--outcome` (release); the
  holder goes in env `CLAIM_HOLDER`, never on argv. The verdict is stdout's first line (`WON`,
  `LOST`, `OK`, `NOT HOLDER`, `ABSENT`, `FORBIDDEN`, `UNREACHABLE`, `ERROR`), then the claim JSON.
  Exit 0 won or ok, 2 lost, 4 not the holder, 1 anything else.
- **Never decide by eye.** Pipe the answer to
  `python3 ${CLAUDE_PLUGIN_ROOT}/skills/build-item/scripts/story-claim.py decide` (stdin
  `{mode, item, response, me, now, tz}`; `me` is the digest of your holder, `digest` prints it from
  stdin) and follow its `action`: `proceed`, `skip`, `stop`, `takeover` (claim again with its
  `takeoverDigest` as the takeover's expected holder digest), `reclaim` (claim again, plainly) or
  `degrade`; say its `message`, which names times in the local time zone with its abbreviation.

## The record

Every `claim_work` call takes `machine`, `sessionName` (when printed) and `payload`, and every
`heartbeat_claim` the `payload` (so the branch stays current), verbatim from
`python3 ${CLAUDE_PLUGIN_ROOT}/skills/build-item/scripts/claim_record.py`, run in the checkout
before each call.
Never type a machine or session name, or add a payload key. Exit 1 degrades as `identity` does.

## When

**Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/ship-intent.md` when the first story is
claimed**, and again after a compaction: every story heartbeat below (3) also declares, renews or
moves what this session is about to ship — the stage each step's run answer names in its
`heartbeat` (`building` at the build, `verifying` at the local checks, `reviewing` at the review,
`landing` at the merge) — and completion (4) also releases that declaration, outcome `landed`.

1. **Selection.** The loop claims a chosen candidate (`claim-story`, `mode: select`) before the
   runner resumes or starts its run, and the Build workflow's first step claims it again BEFORE it
   moves to In Progress. Held by a live holder → no run starts (or the run ends held) and the loop
   drops it, says who holds it and takes the next candidate (the gating check's shape). Expired →
   take over. Already yours (a resumed story) → renewed, carry on. Before
   it, with `provider: devstride`, step 0 reads the live story claims once and drops candidates
   other agents hold (`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/parallel-building.md`):
   that read saves a claim, and this claim still decides.
2. **A story the user NAMED, or the handoff's resumed story** (`mode: named` / `resume`) held by
   another live holder → the run ends held and the loop STOPS, naming that holder's machine and
   session and since when. Expired → take over, as in selection. Your own earlier session (after a
   restart or `/clear`) counts as another holder: wait out the expiry, or the owner releases it
   (`release_claim` with `force`) and the loop claims it afresh. Every candidate held → DRY-CHAIN,
   "N held by other agents".
3. **Heartbeats.** `heartbeat_claim` with `phase` = the `heartbeat.phase` of each step the runner
   issues (null: no heartbeat), and at each `ultracode-build` phase (`mode: heartbeat`). NOT HOLDER
   → STOP naming the holder: another agent took the story after it lapsed. A phase longer than the
   expiry lets the claim lapse, unless the repository's presence command renews it while the
   session is active; the next heartbeat claims it again if free (`reclaim`/`takeover`) and STOPs
   if taken.
4. **Completion** (`story-lifecycle`'s complete step, whether the story is Done or landed).
   `release_claim` with outcome `done`. A STOP releases nothing itself: the claim expires, or that
   presence command releases it when the session ends, so a person can resume without a takeover.

## When claims are not usable

`ABSENT` (the server has no `claim_work`), `UNREACHABLE`, `FORBIDDEN` (the key's user lacks
`MANAGE_AGENT_CLAIMS`, named in the message) or any other error → `degrade`: carry on WITHOUT claims
and say so once per session. A failing `identity` (no session id to claim with) degrades the
same way. A claims outage never stops delivery.

## Progress row

`Claim`: won, renewed, took over, skipped N held, not configured, or degraded (reason).

## Cited by

- `skills/claim-story/SKILL.md` — the pointer before the first call (the claim, the record, the
  modes).
- `skills/story-lifecycle/references/complete.md` — releasing the claim at completion.
- `skills/build-item/SKILL.md` — The run's heartbeats.
- `skills/ultracode-build/SKILL.md` — the phase heartbeats.
- `skills/run-workflow/references/workflow-runner.md` — the heartbeat and the claim mode.
- `skills/build-item/references/ship-intent.md` — sending a declaration as a claim is sent.
- `skills/build-item/references/parallel-building.md` — the holder, the record and the degrade
  rules for plan slots and the epic-release claim.
