---
name: run-workflow
description: "Run a workflow step by step with the step runner; each step is a skill."
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

Arguments: $ARGUMENTS — `<workflow id> [<item>]`.

For the Build workflow use `/devstride:build-item`, which resolves the profile, working base and
route this skill does not.

This skill only does what the step runner says: it never chooses, reorders, skips or judges a step.

**Read `${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/references/workflow-runner.md` in full before the
first command, and again after a compaction**: commands, answers, stop kinds and the reporting rule. **Read
`${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/references/workflow-contracts.md` in full before writing
or changing a definition**: what `start` refuses, payloads and proofs. A `fetch-skill` answer, or a
step run from the organization's skill library:
`${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/references/library-skills.md`.

## The loop

Every command is `python3 -B "${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/scripts/workflow.py" <command>`
with one JSON object on stdin (a file or a here-document, never inside quotes) and one JSON answer on
stdout. Exit 2 is a refusal: say its one line in plain words and stop; nothing changed. Exit 1: the
runner failed; say its line and stop, never retrying.

1. **Resolve the definition**: `${CLAUDE_PLUGIN_ROOT}/workflows/<workflow id>.json`, and fetch the
   organization's (`${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/references/fetching-the-workflow.md`).
   Neither applies to the trigger: say
   "No workflow applies to this work." and stop.
2. **`start`** with that path as `definitionFile`, the answer as `fetched`, and a `context` holding `trigger` and every key the
   reference's Commands section lists (`mode` is a story-claim mode, `named` for a named item).
   The person starting the run supplies them; a missing one is refused (`context-missing`).
3. **For each `run` answer**: run it where its `agent` says, as
   `${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/references/step-agents.md` says (read it in full
   first): a step agent, or here (send its heartbeat, invoke the named skill with `argument`
   unchanged, then `done` with `stepId`, `attempt` and its WHOLE answer as `output`). Read
   `${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/references/gates.md` in full when an answer is
   `request-gate`, `parked` or `address-changes`, and
   `${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/references/conditions.md` in full on `need-facts`.
4. **Forward no history.** The runner keeps the run's history and sends it itself
   (`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/workflow-reports.md`); say an answer's
   `say` once. It fails open.
5. **On `stopped`**: say the reason in plain words and what the person can do about that kind of
   stop, then stop. `resume` continues the run once the cause is fixed.
6. **On `finished`**: say the outcome in plain words, and each non-empty list of
   `continuedPastFailures`, `openCheckpoints` and `skippedByCondition`.

After a restart or a compaction: `status` (where the run is), then `resume` (the issued step again). A step that already acted (a merge that landed) is reported with `done`, never run again.
