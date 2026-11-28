---
load: contract
---
# Run history — the runner sends it, the agent forwards nothing

The loop's steps are written down as data, `${CLAUDE_PLUGIN_ROOT}/workflows/build.json`, and the
step runner (`${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/references/workflow-runner.md`) keeps a
history of every run: one event for each thing that happens (the run starts; a step is handed out,
answered, decided without being run, or waits; the run stops, is resumed, goes back, changes hands
or ends). **The runner sends that history to DevStride itself**, with the machine's own DevStride
key, after each command. The agent forwards nothing: an answer holds no report to send, and no
DevStride tool is called to say where a run is. **History only observes:
it never chooses, reorders, gates or skips a step.**

## The switch

History is ON unless the repository's `.claude/ds-config.json` sets `workflows` to `null`, or the
machine sets `DEVSTRIDE_WORKFLOWS` to `0` (`false`, `off` and `no` also count). An absent key means
on. Off → nothing is kept and nothing is sent for the whole run; switched off part-way, what
already waits is not sent while it is off.

## What the agent does: say one line, once

An answer may carry `say`. Say that line to the person once, in plain words, and carry on:

- *"This run's history is not reaching DevStride yet; the run carries on, and the history is sent
  once DevStride can be reached."* DevStride could not be reached, refused the call, or is a
  version that does not take history yet. The events wait in a file beside the run's state, the
  runner tries again no sooner than a minute later, and a later command sends them in order: one
  of this run, or, once this run is over, one of a later run in the same repository.
- A line saying the rest of this run's history is not kept: DevStride holds as much as it keeps
  for one run, or the waiting file outgrew its size. The run carries on, and nothing more is said.

**Never retry a send, never wait on one, never stop or slow a step because of one.** The runner
gives each command one bounded try, a few seconds in all, and hands out the step whatever became
of it. There is nothing to send again by hand: `status` with `"all": true` and `"unsent": true`
lists the runs whose history DevStride does not hold yet, and `/devstride:doctor` reports them.

## What is never sent

No folder of the machine (a path under a home folder starts at `~`), no transcript, no key or
token. A wait reason that looks like a credential is withheld, and a step's evidence is cleaned as
its verdict is.

## Cited by

- `skills/build-item/SKILL.md` — the run's steps ("the runner sends the run's history itself").
- `skills/run-workflow/SKILL.md`, `skills/run-workflow/references/workflow-runner.md` and
  `skills/run-workflow/references/step-agents.md` — what the runner keeps and sends, and what a
  step agent therefore leaves alone.
- `skills/plan/SKILL.md`, `skills/rebalance/SKILL.md`, `skills/release/SKILL.md` and
  `skills/branch-hotfix/SKILL.md` — each loop's History step.
- `skills/build-item/references/progress-table.md` — the `Run history` row.
- `skills/setup/references/config-defaults.md` and `README.md` — the `workflows` switch.
