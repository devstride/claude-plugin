---
load: contract
---
# Read the production tip — the baseline the checks start against

`release-steps`' `release-tip@1` step, the FIRST step of the checks a `merge-and-deploy` release
runs before it claims the tower
(`${CLAUDE_PLUGIN_ROOT}/skills/release/references/clearance.md` "Scope `merge-and-deploy`", "0p").
It reads only.

1. **Config wins.** Load `.claude/ds-config.json`: `release.productionBranch` (shipped default
   `master`).
2. **Put the checkout at the head the checks test**: fetch, then a detached checkout at the
   release branch's head (`git switch --detach origin/<release branch>`). Every later check of
   this phase runs there.
3. `python3 ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/release_checks.py tip` prints
   `PRODUCTION TIP <sha>` → `AT`, naming that SHA. An `ERROR` line (exit 1) → no verdict line:
   say why and stop.
4. **It runs before any check, never after.** The stamp's baseline is the production tip the
   checks STARTED against, so a merge that lands while they run reads as changed and is never
   silently taken as the baseline. The verdict line is kept in the run's record; the stamp step
   reads the SHA back from the run's `status`
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-stamp.md`).
5. **No heartbeat in this phase**: nothing is held
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md` "Heartbeats"). A
   `MERGED` release changes nothing here: it answers `AT` with production's present tip.

## Verdict

`PRODUCTION TIP: AT <sha>`

## Result

`state`: `at`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-stamp.md`
