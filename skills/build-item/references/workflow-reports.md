---
load: contract
---
# Workflow reports — telling the tracker which step the loop is on

The loop's steps are also written down as data, `${CLAUDE_PLUGIN_ROOT}/workflows/build.json`. As it
runs, the loop reports which of those steps it is on and what each produced. **Reports only
observe: they never choose, reorder, gate or skip a step.**

## The gate

Reporting is ON unless the repository's `.claude/ds-config.json` sets `workflows` to `null`, or the
machine sets `DEVSTRIDE_WORKFLOWS` to `0` (`false`, `off` and `no` also count). An absent key means
on. Pass the helper the key's value as `config`: `{}` when the key is absent, `null` when it is
`null`, else the block itself. The helper decides; never decide by eye.

- **Provider `devstride`** (the default, and what an absent block means): call your own DevStride
  tool `record_workflow_step` with the `arguments` of the helper's `call`, verbatim. Where tools
  load on demand, load it first. A session that has no such tool reports nothing for the whole run.
- **A `commands` block**: run `workflows.commands.report` with those arguments as one JSON object on
  stdin; its first stdout line is `OK`, `ABSENT`, `FORBIDDEN`, `UNREACHABLE` or `ERROR`. A block
  that names both a provider and a command is a config error; the helper uses the command.

## The two calls

Write each input to a file or a here-document, never inside quotes on the command line (a verdict
may hold an apostrophe):

```bash
H="${CLAUDE_PLUGIN_ROOT}/skills/build-item/scripts/workflow_report.py"
python3 "$H" payload <<'JSON'
{"config": {}, "item": "I20110", "reports": [{"step": "select", "status": "done", "verdict": "I20110 — one-off, base develop"}]}
JSON
python3 "$H" outcome <<'JSON'
{"item": "I20110", "answer": {}}
JSON
```

1. `payload` prints `{"skip": "<reason>"}` (send nothing; no `outcome` either) or `{"via", "call":
   {"tool", "arguments"}}`. A report takes `step`, `status` (`running`, `done`, `failed`,
   `waiting`, `skipped`), a one-line `verdict`, a few `evidence` lines and `links` (`pullRequest`,
   `commit`, `comment`, `branch`); at most four reports per call. The last call of a run adds
   `"run": {"outcome": "completed"}` (or `failed`, `interrupted`).
2. Make that one call, then tell `outcome` how it went, as `answer`: `{}` when it was taken (a
   command's `OK`); `{"outcome": "DEFINITION_REQUIRED"}` when the tool answered that, and then run
   `payload` once more with the same reports and send that; else `{"error": "<kind>"}` with
   `ABSENT` (no such tool or command), `FORBIDDEN`, `UNREACHABLE` or `ERROR`.

## Fail open, silently

**Any non-zero exit, unparsable output, skip or tool failure means: send nothing and carry on.**
The first report of a run is its availability check; once any answer is an error the helper skips
every later report of that run, and the next run tries again. Never retry in a loop, never wait on
a report, never stop because of one, and never say or explain anything about reporting to the
person; the progress table's `Workflow report` row is the only trace. When a `payload` prints
`"stateKept": false` the helper cannot remember: after an error answer, stop reporting for the
run yourself.

## When each step is reported

At the loop's own transitions, beside the progress-table render and the claim heartbeat: one call
carries the step just finished and the step just started. Unless a line below says otherwise a
step is `running` when it starts and `done` when it ends; **a step that runs again in the same run
is reported `running` first**, which is what gives it a new attempt. The verdict is the progress
row's own text, the evidence what that row measured (counts, commands, a short commit id), the
links only addresses the loop already holds. Never session text, a prompt or file contents.

- `select` — `done` once the story is chosen (the run starts here), verdict the step-0 row.
- `claim` — `done` with the row's word (won, renewed, took over), or `skipped` with "Claims are not
  configured" or the degrade reason.
- `start` — `done` with the status it moved to. `branch` — `done` with the branch name (also its
  `branch` link).
- `build` and `risk-check` — `running` when `ultracode-build` is invoked; both `done` in one call
  when it returns, the risk check's verdict from its report.
- `review-local` — the configured local review (in 4a, or inside the pull request in 4b), verdict
  its row. `complete` — step 6. `file-findings` — step 6.5, verdict "No findings filed" or the
  items filed.
- At the review fork, once: on the fast path `pull-request-review` is `skipped` ("Fast path: no
  pull request for an epic-branch story"); on the pull-request path `local-checks` is `skipped`
  ("Pull request path: CI is the gate"). `local-checks` may end `failed`, counts in the evidence.
  `pull-request-review` is `waiting` only while the loop waits on a reviewer or CI it started, and
  ends `done` (verdict such as "PR #42 settled, CI green", its `pullRequest` link) or `failed`.
- `merge` — `running` before release holds and consequence notices; a release hold is `waiting`
  with the hold named, and a hold the loop moves on from closes the run `interrupted`; `done`
  carries the commit's short id in the evidence.
- `sync` — its `done` closes the run with outcome `completed`.
- A STOP reports its step as `failed` (or `waiting` when it is a question for the person) and
  closes the run `failed` or `interrupted`. A story resumed later starts a new run.

## Cited by

- `skills/build-item/SKILL.md` — the Progress table section's pointer ("Read … in full at the first
  transition or after a compaction").
- `skills/build-item/references/progress-table.md` — the `Workflow report` row.
- `schemas/seam-registry.json` — the `workflows` hook's contract.
