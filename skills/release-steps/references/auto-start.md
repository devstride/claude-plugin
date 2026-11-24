---
load: contract
---
# Decide the next release — at the very end, unless the levelling already started it

`release-steps`' `auto-start@1` step (the step `auto-start-next`), the last step of a release run:
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/auto-start.md` "Auto start —
`release.autoStart.enabled`" trigger 3, cited, not copied: the `check` answers and how the train
claim is taken.

1. **Config wins.** Load `.claude/ds-config.json`: `release.autoStart.enabled` and the `claims`
   block. Not enabled, or no `claims` block (auto start is honoured only with one) →
   `NOT CONFIGURED`.
2. **Already started.** The train levelling at close-out (`train-level-final`) recorded
   `autoStart` `START` in its result (trigger 5, from this run's recorded results: the runner's
   `status`, never memory) → `SKIP started at the levelling`: that release is the loop's to start,
   and never a second beside it.
3. **Look**: `python3 ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/auto-start.py check` (it fetches
   the train and the release source).
   - `SKIP <reason>` → `SKIP <reason>`, saying nothing more.
   - `ERROR <why>` (a renamed train names the cutover) → `ERROR <why>`, said once. The run ends
     normally.
   - `START …` → step 4.
4. **Claim the train**, ONE claim in mode `select` (`auto-start.md` "The train claim"), never a
   wait:
   - Won → `START`. The evidence line carries the instruction for the loop that runs this
     release: invoke **`release`** in this session declaring `started-by: auto`, in this checkout,
     keeping its lease. This step never starts it itself.
   - Lost to a live holder → `SKIP train claim held by <holder>`, carrying on silently.
   - `stop` or `degrade` → `ERROR <why>`, said once.
5. Never resume, message or adopt another session's release from here.

## Verdict

`AUTO START: START | SKIP <reason> | NOT CONFIGURED | ERROR <why>`

## Result

`state`: `start`, `skip`, `not-configured` or `error`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
