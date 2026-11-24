---
load: contract
---
# Gather the ship plan — a short, fixed wait for a nearly-ready peer

`release-steps`' `ship-plan@1` step. The rules, the script's input and the marker are
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/ship-plan.md`, cited, not copied: this step is
its section "The driver", run by the session that holds the `release-train` claim.

1. **The train gate**
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/train-finish.md` "The train phase").
   Not applicable → `NOT APPLICABLE`.
2. **When it applies** (`ship-plan.md` "When it applies"). `NOT APPLICABLE`, saying which, when
   there is no `claims` block, `release.coordination.enabled` is `false`,
   `release.coordination.peerWaitMinutes` is 0, or an open train pull request is about to be
   adopted (it already fixed what it carries: only the path that cuts a fresh snapshot gathers).
3. **Run "The driver" steps 1 to 4 as written**: the plan already on the claim (read back every
   time, after a compaction too), every page of the declarations, the held units once, then
   `python3 ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/ship-plan.py decide`. Never decide by eye.
   `goNow` is true only when the person said "go now" for this release in this session.
4. **`wait`** → its step 5: heartbeat the `release-train` claim with phase `gathering` and the
   plan, say its `message` once, wait in the background, and decide again. The wait ends after
   `peerWaitMinutes` of this session's own elapsed time whatever the script says; it is fixed
   when the release starts and never extended.
5. **`go`** → its step 6. With a plan: heartbeat the claim with the finished plan and say its
   `message`. The finished plan stays on the claim; the step that opens the train pull request
   reads it back there and writes the `devstride:release-gather` marker from `ship-plan.py marker`.
   A release that did not gather writes none.
6. **When it cannot run, the release goes** (`ship-plan.md`): `decide` exiting non-zero → no wait
   and no marker, said once; a provider that refuses the `plan` payload → heartbeat again without
   it and go. The claim's ordinary heartbeat must still succeed before the snapshot is cut: one
   that is lost or degrades is a stop, with no verdict line
   (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/auto-start.md` "Never degrades").
7. **Answer.** It waited → `WAITED`, with the whole minutes waited and who was carried or missed.
   Nobody was nearly ready, the person said go now, or it could not run → `GO`.

## Verdict

`SHIP PLAN: GO | WAITED <minutes> | NOT APPLICABLE`

## Result

`state`: `go`, `waited` or `not-applicable`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
