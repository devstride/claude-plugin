---
load: contract
---
# Claim the release train — one session runs the train phase

`release-steps`' `train-claim@1` step, the first step of every full release. The claim's rules are
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/auto-start.md` "The train claim", cited, not
copied; the calls, the holder and the takeover of a lapsed holder are
`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/story-claims.md`'s.

1. **Config wins.** Load `.claude/ds-config.json`. No `claims` block → `NOT CONFIGURED`, and the
   marker-only rule of `${CLAUDE_PLUGIN_ROOT}/skills/release/references/clearance.md` protects the
   train pull request instead.
2. **Train, then tower: one lock order for every run.** This claim comes before an open release
   pull request is adopted, before the tower claim and before a train pull request is opened or
   adopted, so no session ever holds the tower while waiting for the train.
3. **Claim** kind `release-train`, key from `python3
   ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/auto-start.py key`, expiry
   `claims.expiryMinutes["release-train"]`, else 30 minutes. An auto start (the payload's
   `startedBy` is `auto`) already holds it from its trigger; this claim refreshes it.
4. **Never decide by eye.** Pipe the answer to `python3
   ${CLAUDE_PLUGIN_ROOT}/skills/build-item/scripts/story-claim.py decide`, item `the release
   train`, mode `named` for a hand start and `select` for an auto start.
5. **Answer.**
   - Won, renewed, or taken over from a lapsed holder → `WON`. From here the run holds the train
     claim, and it is heartbeated as `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
     "Heartbeats" says.
   - Held by a live session → `LOST`, naming who holds it and since when. The run ends there. A
     hand start says so to the person; an auto start logs no failure and its caller carries on.
   - `decide` answers `degrade` (the store unreachable, unsupported or forbidden) → `DEGRADED`
     naming the outage. The train claim never carries on degraded: another session may hold the
     claim this one cannot read. An auto start does nothing more, saying so once.

## Verdict

`TRAIN CLAIM: WON | LOST <holder> | DEGRADED <reason> | NOT CONFIGURED`

## Result

`state`: `won`, `lost`, `degraded` or `not-configured`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
