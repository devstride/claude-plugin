---
load: contract
---
# Doctor check for workflows

All read-only. It lists tools; it never calls one.

## Workflows (§3)

- **The switch.** `workflows` set to `null` in `.claude/ds-config.json`, or the machine variable
  `DEVSTRIDE_WORKFLOWS=0` → report `workflows: off` (runs use the built-in workflow and keep no
  history; that is a choice, never a gap). Otherwise report `workflows: on (default)`.
- **When on**, check that the connected DevStride server offers `get_workflow_for_item` (which
  workflow applies to an item) and `record_workflow_run_events` (a run's history) by listing tools
  (ToolSearch), **never by calling one**. Both offered → PASS. One missing → INFO, not FAIL,
  a normal state: without the first, runs use the built-in workflow; without the second,
  history waits here.
- **Unsent history.** The runner's `status` with `{"all": true, "unsent": true}` (read-only)
  lists runs whose history DevStride does not hold yet: none → PASS; each → INFO, never FAIL,
  naming its item or run id, events waiting and since when (a later command sends them).
- **`get_agent_skill`** (a skill from the organization's library): offered → PASS; missing → INFO,
  never WARN or FAIL: "needed only when your organization's workflow uses library skills".
- **`request_workflow_gate` and `get_workflow_gate`** (an approval gate: ask a person, read their
  answer): both offered → PASS; either missing → INFO, never WARN or FAIL: "needed only when your
  organization's workflow has an approval gate; without them such a run stops at the gate".
- **No DevStride connection at all** → N/A.
- A run that fell back says why in `workflow.py status` (`source`, for example
  `built-in (DevStride unavailable)`); doctor names that one line when asked about a run.
