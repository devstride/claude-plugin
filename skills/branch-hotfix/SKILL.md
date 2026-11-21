---
name: branch-hotfix
description: Create a new hotfix branch off a fresh copy of the production branch, for urgent fixes that must not carry unreleased work
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

**Goal:** a correctly named hotfix branch cut from a freshly pulled production branch and pushed,
with the local environment brought back in step with production code — never carrying the
development branch's unreleased work — and then the fix, its review, the merge to production and
the deploy, each on the person's word. Branch name argument: $ARGUMENTS (none → ask for one).

The hotfix is the built-in **Hotfix workflow**, `${CLAUDE_PLUGIN_ROOT}/workflows/hotfix.json`:
thirteen steps in two phases, each run by a step skill (`hotfix-steps` for its own, `risk-check`,
`local-checks` and `review-story` for the three it shares with Build). Every rule of each step
lives in that step's reference, `${CLAUDE_PLUGIN_ROOT}/skills/hotfix-steps/SKILL.md` lists them.

## Floors

- **Config wins**: `.claude/ds-config.json` is read first and beats every default; no file means
  the shipped defaults, said so.
- **The tree must be clean** before anything switches branch; the preflight step stops otherwise.
- **A hotfix never claims release clearance** (`release.clearance`, when set): it is cut, reviewed and merged into the production branch whoever holds the runway, and the release in flight learns of it from the provider's `status`.
- **The previous branch is kept**; nothing here deletes a branch.
- The merge and the deploy approval happen only on the person's explicit yes in this session;
  never set `DEVSTRIDE_MERGE_GUARD=0`.

## Run it

Every command is `python3 -B "${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/scripts/workflow.py"
<command>` with one JSON object on stdin (a file or a here-document, never inside quotes). **Read
`${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/references/workflow-runner.md` in full before the first
command, and again after a compaction.**

1. **`start`** with `definitionFile` `${CLAUDE_PLUGIN_ROOT}/workflows/hotfix.json` and the context:
   `branchArgument` (the text after the command, possibly empty), `itemNumber` and `item` (only when
   the person passed one, or the branch argument carries one), `profile` (resolved as
   `/devstride:build-item` resolves it), `workingBase` (the production branch, `hotfixBaseBranch`),
   `oneOff` `true`, `route` `develop-pr` (a one-off pull request into a protected branch, never a
   release route) and `reviewMoment` `pr-boundary` (the full review before CI). A start refused
   `run-open` means this session already has a hotfix open: `resume` it, or finish or abandon it
   first.
2. **For each `run` answer**: invoke the named skill through the Skill tool with `argument`
   unchanged (plus ` answer: <it>` when the payload carries a person's `answer` and the argument
   does not), then `done` with `stepId`, `attempt` and the skill's WHOLE answer as `output`.
3. **Reports**: forward every `reports` object, in order, exactly as
   `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/workflow-reports.md` says. Reporting is on
   by default, checked once per run, and fails open: a failure is silent or one line, never a stop.
4. **On `stopped`** whose reason starts `NEEDS ANSWER`, `NEEDS INPUT`, `DIRTY`, `NEEDS DIRECTION`,
   `WAITING FOR YES`, `OWNER TO CONFIRM` or `PRODUCTION`: show the step's evidence in plain words and
   ask; once the person replies, `resume` with their reply as `answer`. Any other stop: say its
   reason and what can be done about it, then stop.
5. **On `finished`**: say the outcome in plain words (`completed`, `abandoned` or
   `environment-declined`), with the branch, the merge commit and the deploy as they stand.

After a restart or a compaction: `status`, then `resume`. A step that already acted (a merge that
landed) is reported with `done`, never run again.

## No runner

With no `python3`, or when the runner itself fails (exit 1, not a refusal), the procedure is the
same, read by hand and needing nothing from DevStride: read `${CLAUDE_PLUGIN_ROOT}/workflows/hotfix.json`
and `${CLAUDE_PLUGIN_ROOT}/schemas/step-contracts.json`, run each step's skill by name, with the
step's contract as its mode, in the listed order; read the verdict on its first line; continue on a
verdict the catalog classes as continue or skipped, end on one it classes as an end, and stop and ask
on any other.
