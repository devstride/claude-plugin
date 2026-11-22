---
load: contract
---
# Check the previous release — no merge on top of a release that is not healthy

`release-steps`' `previous-release@1` step: the same step before the recap and again on the yes.
The gate is `${CLAUDE_PLUGIN_ROOT}/skills/release/references/clearance.md` "Scope
`cut-to-deploy`" and "Scope `merge-and-deploy`", cited, not copied and unchanged. It never blocks
the cut, the review or a hotfix.

1. **Config wins.** Load `.claude/ds-config.json`: `release.clearance` and its `scope`. No
   clearance block, or the default scope `release` → `NOT GATED`. Shape `MERGED`
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`) → `NOT GATED`.
2. **Read the gate**: `${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/previous-release-gate.sh`,
   which reads the previous release merge's `release/post-deploy` status. How it is called:
   - Scope `cut-to-deploy`: with `--wait`, in the background with a long timeout (it polls a
     pending status for up to 45 minutes).
   - Scope `merge-and-deploy`, this session not holding the tower (it waits outside it): WITHOUT
     `--wait`, one read every 60 seconds for at most 45 minutes while it reads `2`. This is the
     normal case for a release prepared on top of the one ahead, so the wait sends no notice.
   - Scope `merge-and-deploy`, this session holding the tower (after the final claim; its local
     clearance record says so): ONE read.
3. **Act on the exit, exactly:**
   - `0` → `SUCCESS` (`NOT GATED` when the script printed that).
   - `2` → `PENDING`, naming that release and `/devstride:release post-deploy only`. Holding the
     tower under `merge-and-deploy`, first run the provider's `release --step-aside`, which owes
     nothing: the release goes back to waiting on the gate, an owner yes already given is kept,
     and no yes lifts a pending gate.
   - `1` → `FAILED <release>`: "Production merge refused: release <name> (#<n>) failed its
     post-deploy check." Only the owner's own words in the payload's `answer` override it: record
     them as ONE comment on this pull request, then answer `NOT GATED` (state `overridden`).
   - `3` (no status: the first release under this scope, or one from before it) → `UNREADABLE`,
     saying which; the owner is asked once, and their yes in `answer` → `NOT GATED`.
   - `4` (unreadable, a config error too) → `UNREADABLE`.
4. A yes is read only from the payload's `answer`; it is never written for the owner. The line
   printed and its exit go on the evidence lines: the go-ahead's standing-yes check reads them.

## Verdict

`PREVIOUS RELEASE: SUCCESS | PENDING | FAILED <release> | NOT GATED | UNREADABLE`

## Result

`state`: `success`, `pending`, `failed`, `not-gated`, `overridden` or `unreadable`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
