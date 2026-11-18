---
name: run-workflow
description: "Run a workflow step by step with the step runner; each step is a skill."
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

Arguments: $ARGUMENTS — `<workflow id> [<item>]`.

For the Build workflow use `/devstride:build-item`, which resolves the profile, working base and
route this skill does not.

The step runner decides which step is next, checks each step's answer and proof, and remembers
where the run is, also across a restart or a cleared conversation. This skill only does what the
runner says: it never chooses, reorders, skips or judges a step itself.

**Read `${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/references/workflow-runner.md` in full before the
first command, and again after a compaction**: the commands and their answers, the stop kinds and
what a person does about each, and the reporting rule are there.

## The loop

Every command is `python3 -B "${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/scripts/workflow.py" <command>`
with one JSON object on stdin (a file or a here-document, never inside quotes) and one JSON answer on
stdout. Exit 2 is a refusal: say its one line in plain words and stop; nothing has changed.

1. **Resolve the definition**: `${CLAUDE_PLUGIN_ROOT}/workflows/<workflow id>.json`. No such file:
   say so and stop.
2. **`start`** with that path as `definitionFile` and a `context` holding the item (or null) and
   `"mode": "on-demand"`. A workflow whose step skills this plugin lacks is refused here
   (`skill-missing`), before anything is written.
3. **For each `run` answer**: send its heartbeat (the phase to the story claim, the ship-intent
   request to the ship-intent helper; skip whichever is null), invoke the named skill through the
   Skill tool with `argument` unchanged, then pass that skill's WHOLE final answer as `output` to
   `done`, with the step's `id` and `attempt`. The answer to `done` is the next action.
4. **Forward every object in `reports`**, in order, through the `workflows` seam
   (`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/workflow-reports.md`, The gate), failing
   open: the first time the tool is absent, refused or unreachable, say one plain line, send
   nothing more for this run, and carry on. A report never stops, slows or retries a step.
5. **On `stopped`**: say the reason in plain words and what the person can do about that kind of
   stop, then stop. `resume` continues the run once the cause is fixed.
6. **On `finished`**: say the outcome in plain words.

After a restart or a compaction: `status` (where the run is), then `resume` (the same step again).
