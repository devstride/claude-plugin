---
load: contract
---
# Workflow reports — telling the tracker which step the loop is on

The loop's steps are written down as data, `${CLAUDE_PLUGIN_ROOT}/workflows/build.json`, and the
step runner (`${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/references/workflow-runner.md`) hands back,
with every answer, the reports that say which step the run is on and what each produced: `reports`,
a list of ready argument objects for the tracker's `record_workflow_step` tool. The loop only sends
them. **Reports only observe: they never choose, reorder, gate or skip a step.**

## The gate

Reporting is ON unless the repository's `.claude/ds-config.json` sets `workflows` to `null`, or the
machine sets `DEVSTRIDE_WORKFLOWS` to `0` (`false`, `off` and `no` also count). An absent key means
on. Off → send nothing for the whole run.

- **Provider `devstride`** (the default, and what an absent block means): call your own DevStride
  tool `record_workflow_step` with each object as its arguments, verbatim. Where tools load on
  demand, load it first. A session that has no such tool reports nothing for the whole run.
- **A `commands` block**: run `workflows.commands.report` with each object as one JSON object on
  stdin (a file or a here-document, never inside quotes: a verdict may hold an apostrophe); its
  first stdout line is `OK`, `ABSENT`, `FORBIDDEN`, `UNREACHABLE` or `ERROR`. A block that names
  both a provider and a command is a config error; the command is used.

Send the objects in the order the answer lists them, one call each, never edited, merged or
reordered. When the tracker answers that it needs the definition (`DEFINITION_REQUIRED`), the
object it refused was not recorded: run `status` with the item and `includeDefinition` once, take
the `definition` from the object it returns, and send the REFUSED object again with that
`definition` added (its `reports` and `run` unchanged), once; then carry on with the next object.
The `status` object alone carries no step reports, so sending only it would lose the refused batch.

## Fail open, silently

**Any tool failure, refusal, error line or missing tool means: send nothing and carry on.** The
first report of a run is its availability check; once any call fails, send nothing more for that
run, and the next run tries again. Never retry in a loop, never wait on a report, never stop or slow
a step because of one, and never say or explain anything about reporting to the person; the
progress table's `Workflow report` row is the only trace.

## Cited by

- `skills/build-item/SKILL.md` — The run's reports step ("read … in full before the first forward
  of a run, or after a compaction").
- `skills/run-workflow/SKILL.md` and `skills/run-workflow/references/workflow-runner.md` — the
  authority for sending.
- `skills/build-item/references/progress-table.md` — the `Workflow report` row.
- `schemas/seam-registry.json` — the `workflows` hook's contract.
