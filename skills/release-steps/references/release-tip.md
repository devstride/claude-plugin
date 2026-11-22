---
load: contract
---
# Read the production tip — the baseline the checks start against

`release-steps`' `release-tip@1` step (the step `checks-tip`), the first step of the checks under
scope `merge-and-deploy`, which run before the tower is claimed. The phase is
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/clearance.md` "Scope `merge-and-deploy`" (0p),
cited, not copied; the stamp's rules are the header of
`${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/release_checks.py`.

1. **The head the checks test**: this run's release branch head
   (`git fetch origin <productionBranch> <branch>`), checked out DETACHED (`git switch --detach
   origin/<branch>`), so the class, pre-ship, dev deploy and pre-merge checks after this step all
   see exactly that tree. A dirty checkout → no verdict line, naming the files: nothing is
   discarded.
2. **FIRST, before any check**: `python3
   ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/release_checks.py tip` → `PRODUCTION TIP <m>`.
   The stamp's baseline is the production tip the checks STARTED against, so a merge that lands
   while they run (the release ahead merging during a long dev deploy wait) reads as changed,
   never as the baseline.
3. Answer `AT <m>`, the full SHA; the runner keeps the line for the stamp
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-stamp.md`). A shape of
   `MERGED` reads the tip all the same: it changes nothing.
4. Any failure (a fetch, an unknown commit) → no verdict line, naming it: the runner stops, never
   a guessed tip. No heartbeat is sent in this phase: nothing is held, and one would answer exit 4
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md` "Heartbeats").

## Verdict

`PRODUCTION TIP: AT <sha>`

## Result

`state`: `at`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-stamp.md` — its baseline
