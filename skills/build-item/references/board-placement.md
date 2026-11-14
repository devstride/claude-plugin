---
load: contract
---
# The build loop's board placement step

Only when `boardPlacement` is set in `.claude/ds-config.json`, and then only when `python3
${CLAUDE_PLUGIN_ROOT}/skills/setup/scripts/board-placement.py validate` prints `VALID`. **An
absent or null block does nothing here, ever**; `INVALID` is one progress-table line and nothing
is placed. The rules and how they are set: `${CLAUDE_PLUGIN_ROOT}/skills/setup/references/boards-mode.md`.
Work is placed when it STARTS, so this runs in plan mode and for a one-off alike, and every
decision is the script's `resolve`, never judged by eye.

## 1. Every pickup: place the item, then its release unit

At **each** item picked up, as step 1 starts it (before its status moves) and after the Active
Agents step (when it is configured) has resolved its root:

- **Once per run, the boards**: `list_boards` (every page, archived ones included) → for each
  `id`, `label`, `boardFolderId`, `archived`, `startDate`, `endDate`. Read again only after a
  `PLACE UNRESOLVED`, then resolve that item once more. With them, the organization's tags
  (`get_organization_metadata` → `labels`: each `id` and `name`): an item carries tag ids, a
  rule stores names.
- **The two items**: the picked-up item, then its release unit (the nearest ancestor of the
  `hierarchyRoles.releaseUnit` type, else as the working base derives it). Skip the release unit
  when there is none, when it is the deferred container or sits under it
  (`deferred-container.py members`), when it is the root the Active Agents step resolved, or
  when it sits on `activeAgents.boardId` (a plan root there is that step's alone; any other is
  doctor's to report).
- **`resolve`** for each, on stdin: `item`; `boards`; `date` — today. Build `item` from
  `get_item` with `fields: ["number", "workType", "teamId", "labels", "customFields",
  "hierarchy", "boardId", "completedAt"]`: `workType` — the type's name; `teamId` and
  `customFields` — as the answer carries them; `tags` — the NAME of each id in its `labels`,
  an array; `ancestors` — the `itemNumber` of every `hierarchy` entry but its own, an array;
  `boardId` — its board now, null when the answer carries none; `done` — `true` only when
  it has a `completedAt`. A field the item lacks is left out, never guessed.
  - `PLACE MOVE <id>` → `update_item` with `boardId: <id>` and nothing else; `get_item` to
    confirm it landed. Never set a status here: the item keeps its own.
  - `PLACE KEEP`, `PLACE NONE` → no write. `PLACE NONE` never takes an item off a board.
  - `PLACE UNRESOLVED` → no write, one progress-table line carrying its reason (a cycle with no
    board for today is the owner's to create; `/devstride:doctor agents` lists it).
- A release unit already placed in this run is not resolved again until the day changes.

Only these two items are ever placed here — never an item above the release unit, never one
the loop did not pick up, and never onto `activeAgents.boardId`.

## 2. Fail open

Any non-zero exit from the script, a 403 or any other failure on the move, or a missing
DevStride tool is one line in the progress table, and the loop goes on: a board never blocks a story. **Never
a question, never a stop.**

## Cited by

- `skills/build-item/SKILL.md` step 1, through `skills/build-item/references/item-status.md`
- `skills/setup/references/boards-mode.md`
- `skills/create-story/references/one-off-handoff.md` step 0
- `skills/setup/references/config-defaults.md` (Board placement)
