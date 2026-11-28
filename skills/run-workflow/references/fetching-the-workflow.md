---
load: contract
---
# Fetching the workflow for an item

Read by `build-item` and `run-workflow` at the point where they call `workflow.py start`. It asks
DevStride which workflow the organization published for this item, so that its own workflow runs
instead of the built-in one. **A failed fetch never stops the run**: the built-in workflow runs
exactly as it would have.

The fetch is on by default for every install connected to DevStride, with nothing to set up. The
one switch that turns it off is the one that turns the run history off: `workflows` set to `null`
in `.claude/ds-config.json`, or the machine variable `DEVSTRIDE_WORKFLOWS=0`. With it off, skip
steps 1 to 4 and start with the built-in definition alone.

1. **Once per run, at its start.** One attempt; never a retry, never a message per step. Where
   the server's tools load on demand, one tool search for `get_workflow_for_item` is the only
   lookup. A tool that is not in the tool list, or that one search does not find, is `ABSENT`:
   never try another tool or route in its place (no `invoke_api_operation`), and never retry. An
   older server and an unreachable server also count as the one failed attempt.
2. **The repository**: `python3 -B "${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/scripts/workflow.py" repository`
   (no input) prints `{"repository": "host/owner/name"}`, or `null` outside a repository or with
   no usable remote. Never send the raw remote address, which can carry a credential.
3. **Call `get_workflow_for_item`** on the agent's own DevStride connection with `itemNumber`,
   `trigger` (`build-item`: always `item-picked-up`; `run-workflow`: the trigger its invocation
   names, `on-demand` when it names none), `repository` (left out when null) and
   `includeDefinition: true`.
4. **Pass the answer to `start`** as `fetched`, beside the built-in definition the entry skill
   always passes, with `trigger` in the `context`. On failure pass instead
   `{"error": "<code>"}`: `ABSENT` (the tool is not offered), `FORBIDDEN` (the key is refused),
   `UNREACHABLE` (the server could not be reached) or `ERROR` (anything else).
5. **Say the runner's `notice` line verbatim** when it is not null, once. It is set only when
   the organization's workflow runs, or when DevStride sent a workflow this plugin could not run;
   never for "no workflow" and never for an unavailable server, which stay silent.

The runner checks what came back and decides; the entry skill never judges the answer itself.
An answer's `runOutcomes`, where the tracker sends one, lists the run endings it accepts; an ending
a step recorded is named to the tracker only when listed (`workflow-runner.md`, History).
It pins the definition it chose for the whole run: `next`, `done`, `status` and `resume` read only
that copy, and a second `start` for a run under way keeps it, so a workflow published or archived
meanwhile changes only the next run. `status` names the workflow (`workflow`) and where it came
from (`source`, for example `built-in (DevStride unavailable)`).

## A step that runs a skill file from the repository

A step whose `run` answer has `skill: null` carries `instructions` instead: `{source: "repo", ref,
version, hash, text}`, read from the committed file at the commit the checkout is on, never from
an uncommitted edit. Treat `text` as that step's skill: do the one thing it says, then answer
`done` with the verdict line its contract names, exactly as for a built-in skill. The runner still
checks every proof the contract requires. A file that cannot be used (not committed, a link, an
unsafe path, over 64 KB, not text, no repository) stops the run with a plain reason: fix the file
or the workflow, commit, then `resume`.
