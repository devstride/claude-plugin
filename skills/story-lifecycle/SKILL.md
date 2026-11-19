---
name: story-lifecycle
description: "Start a story (move it to In Progress) and finish it when it lands."
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/step-skills.md` first: the rule every step skill follows.

Arguments: $ARGUMENTS — one JSON object, the payload of the step being run
(`${CLAUDE_PLUGIN_ROOT}/schemas/step-contracts.json`). `start@1`: `item`, `workingBase`, `oneOff`.
`complete@1`: those plus `profile`, `releaseUnit`, `route` and the earlier steps' results `merge`,
`build`, `riskCheck` and `review`. The reserved `contract` key says which step this call runs.

Two steps of the Build workflow share this skill: the two that only Build runs and nobody re-runs
alone. They run at two places in the workflow, one per call.

## Verdict

`START: MOVED [<status>] | UNCHANGED | FAILED [<reason>]` for the start step, and
`COMPLETE: DONE | LANDED | FAILED [<reason>]` for the complete step.

## Steps

1. Dispatch on the payload's `contract`:
   - `start@1` → **read `${CLAUDE_PLUGIN_ROOT}/skills/story-lifecycle/references/start.md` in full
     before acting on the start**, then do it: place the item when configured, move it to its
     in-progress status through `item-status.py`, and read it back before any branch exists.
   - `complete@1` → **read `${CLAUDE_PLUGIN_ROOT}/skills/story-lifecycle/references/complete.md` in
     full before acting on the completion**, then do it: the landed status and comment through
     `item-status.py`, the dates (only with the auto-scheduler off), the link to the code, the
     as-built reconciliation, the claim and ship-intent releases, and the report.
   - Any other contract, or none → no verdict line: say this skill carries only `start@1` and
     `complete@1`, and stop.
2. A non-zero exit of `item-status.py` → `FAILED` with its line: move nothing, post nothing.

It never starts the plan's Closing or the release auto-start: those belong to the loop.

## Result

After the verdict and its evidence, one fenced `json` block. Start: `statusBefore`, `statusAfter`
(the same when unchanged) and `boardPlaced`. Complete: `status` (`done` or `landed`),
`statusName`, `startDate`, `dueDate`, `pullRequest`, `asBuilt` (`reconciled`, or
`shipped as specified`), `claimReleased` and `shipIntentReleased`.

**Step rules.** One step per call; verdict first; safe to re-run (a status already set stays, a
comment already posted is not posted twice); config wins; it never starts a subagent and never
decides what runs next.
