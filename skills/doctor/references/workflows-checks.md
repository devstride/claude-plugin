---
load: contract
---
# Doctor check for workflows

All read-only. It lists tools; it never calls one.

## Workflows (§3)

- **The switch.** `workflows` set to `null` in `.claude/ds-config.json`, or the machine variable
  `DEVSTRIDE_WORKFLOWS=0` → report `workflows: off` (runs use the built-in workflow and send no
  step reports; that is a choice, never a gap). Otherwise report `workflows: on (default)`.
- **When on**, check that the connected DevStride server offers `get_workflow_for_item` (which
  workflow applies to an item) and `record_workflow_step` (step reports) by listing tools
  (ToolSearch), **never by calling one**. Both offered → PASS. One missing → INFO, not FAIL:
  "this DevStride server does not offer workflows yet, or the key's user cannot read the item;
  runs use the built-in workflow". That is a normal state.
- **No DevStride connection at all** → N/A.
- A run that fell back says why in `workflow.py status` (`source`, for example
  `built-in (DevStride unavailable)`); doctor names that one line when asked about a run.
