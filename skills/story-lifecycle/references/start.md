---
load: contract
---
# Start — the story moves to In Progress before its branch exists

`story-lifecycle`'s `start@1` step. The status rule itself is
`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/item-status.md`, which stays the contract; this
file is the order the step follows.

1. **Board placement first.** With `boardPlacement` set in `.claude/ds-config.json`, apply
   `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/board-placement.md` in full before the status
   moves (item-status.md: its step 0 places the item first), so the move reads the board the item
   starts on. Unset → nothing; `boardPlaced` is `false`. A placement failure is one line of evidence
   and never stops the start.
2. **Read** the item (`statusId`; its board's `statusCollectionId` via `get_board`, else its team's)
   and `get_workspace_context` (`statuses`, `statusCollections`).
3. **Decide**: pipe `python3 ${CLAUDE_PLUGIN_ROOT}/skills/build-item/scripts/item-status.py decide`
   the request with `event: start` (item-status.md step 2).
4. **Move**: exit 0 with a `statusId` → `update_item` to it, then read the item back and confirm it
   moved before branching (`START: MOVED <status name>`); no `statusId` → leave the status
   (`START: UNCHANGED`, its `message` as evidence). Exit 2 or 1 → move nothing, post nothing, and
   answer `START: FAILED` with its `item-status:` line.
5. A read-back that does not show the new status → `START: FAILED`, naming the status it shows:
   the branch must never exist while the tracker says the story has not started.

A re-run on a story already In Progress answers `UNCHANGED`: the decision leaves a current status
alone.

## Cited by

- `skills/story-lifecycle/SKILL.md` — the `start@1` dispatch ("Read … in full before acting on the
  start").
