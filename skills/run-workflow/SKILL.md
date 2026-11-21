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
what a person does about each, and the reporting rule are there. **Read
`${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/references/workflow-contracts.md` in full before writing
or changing a definition**: what `start` refuses, payloads and proofs. A `fetch-skill` answer, or a
step run from the organization's skill library: `references/library-skills.md`.

## The loop

Every command is `python3 -B "${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/scripts/workflow.py" <command>`
with one JSON object on stdin (a file or a here-document, never inside quotes) and one JSON answer on
stdout. Exit 2 is a refusal: say its one line in plain words and stop; nothing has changed. Exit 1
means the runner itself failed: say its line and stop, without retrying.

1. **Resolve the definition**: `${CLAUDE_PLUGIN_ROOT}/workflows/<workflow id>.json`, and fetch the
   organization's (`references/fetching-the-workflow.md`). Neither applies to the trigger: say
   "No workflow applies to this work." and stop.
2. **`start`** with that path as `definitionFile`, the answer as `fetched`, and a `context` holding `trigger` and every key the
   reference's Commands section lists (`mode` is a story-claim mode, `named` for a named item).
   This skill resolves none of them: the person starting the run supplies them, and a missing one is
   refused (`context-missing`).
3. **For each `run` answer**: send its heartbeat (the phase to the story claim, the ship-intent
   request to the ship-intent helper; skip whichever is null), invoke the named skill through the
   Skill tool with `argument` unchanged (`skill` null: follow `instructions.text` as that skill) (plus ` answer: <it>` when the payload carries a person's
   `answer` and the argument does not), then call `done` with `stepId` (the step's `id`),
   `attempt` and `output` (that skill's WHOLE final answer). Its answer is the next action.
4. **Send `reports`** in order exactly as
   `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/workflow-reports.md` says: its gate decides
   whether and how; it fails open, and a run's first failure is said once.
5. **On `stopped`**: say the reason in plain words and what the person can do about that kind of
   stop, then stop. `resume` continues the run once the cause is fixed.
6. **On `finished`**: say the outcome in plain words.

After a restart or a compaction: `status` (where the run is), then `resume` (the issued step again). A step that already acted (a merge that landed) is reported with `done`, never run again.
