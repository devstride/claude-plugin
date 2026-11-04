---
load: contract
---
# `setup agents` — the Active Agents board, tag and shared view

The one setup mode that WRITES TO DEVSTRIDE, and only to create or adopt what the
`activeAgents` block needs: a board, a tag, the tag's place in tag groups, a shared table view,
and the block itself. Opt-in: a repository without the block, or one that never runs this mode,
gets no DevStride write from the plugin for this feature. Every check, merge and command
substitution is `python3 ${CLAUDE_PLUGIN_ROOT}/skills/setup/scripts/active-agents.py` — never
decided by eye. The build loop's half is
`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/active-agents.md`; doctor's read-only half is
`${CLAUDE_PLUGIN_ROOT}/skills/doctor/references/agents.md`.

## The block (`.claude/ds-config.json`)

`activeAgents`: `{ boardId: string | null, tagName (default "agent active"), tagColor (default
"green", one of `create_label`'s colours), staleMinutes (positive whole number, default 20),
commands: { start, end } }`. `commands.start` must contain `<root>`; `commands.end` may. Both are
the repository's own commands; the plugin never writes or guesses them, and asks for them when the
block has none. `boardId: null` means "not adopted yet": the build loop places no root until this
mode sets it. **An absent or null block writes nothing and runs nothing, ever** — in the build loop
and doctor. This mode is how a block comes to exist: with none, it asks for the two commands
first and writes nothing anywhere until they and the plan get the typed yes.

## 1. Inventory — read-only

`validate`, then: the connected organization's name (`get_workspace_context`); the board
(`get_board` for a configured id, else `list_boards` for a board labelled exactly "Active
Agents"); tags, tag groups (label collections) and work types (`get_organization_metadata` with
`include: "all"`); the hierarchy (`get_work_type_hierarchy`). The **plan-root types** are every work
type that is not a leaf role (`hierarchyRoles.leaf`, else the childless levels of the hierarchy).
Views: `invoke_api_operation` with `findStoredViews` for the board's location (read
`describe_api_operation` first; never guess an operation's input).

## 2. The plan, then a typed yes

Print the organization's name, then one line per change: the tag to create (or the colour it
would change), each tag group to change as `merge-labels`' exact before and after, the board to
adopt or create, the view to create, and the block to write or merge. Nothing to change → print
`agents: nothing to change` and stop: no write. Otherwise ask, and act only on a **typed yes**
naming this plan; anything else writes nothing.

## 3. Apply — in this order, each step reading before it writes

1. **The tag.** Missing → `create_label` with `tagName` and `tagColor`. Present with another
   colour → changed only when the plan named it.
2. **The tag groups.** Each DISTINCT tag group of a plan-root type, once: read its current list,
   pipe it with the tag's id to `merge-labels`, print the difference, and send `after` with
   `update_label_collection`. That call REPLACES the whole list —
   **never replace a tag group with only the new tag**. A plan-root type with no tag group is
   reported and skipped; creating a tag group is out of scope.
3. **The board.** The configured id when that board exists and is not archived; else a
   non-archived board labelled "Active Agents"; else `create_board` labelled "Active Agents",
   asking once for the board folder and status collection it needs. A configured board that is
   missing or archived is named in the plan, and the board that replaces it is written to
   `boardId` in step 5; this mode never unarchives a board.
4. **The view.** A shared table view of the board named "Active Agents" (`createStoredView`,
   visibility `internal`) with the columns Item, Status, Progress, Priority and Tags. An internal
   view of that name already on the board is the view: never a second one. The view's data has a versioned format
   the plugin must not guess: copy the shape and version of an existing internal table view of
   the same kind (`findStoredViews`) and change only its column list. **No view to learn from →
   create everything else, report the view NOT created with that reason, and name it as the one
   owner step**; never write a view the plugin cannot verify.
5. **The block.** Create it, or merge `boardId` (and any default the owner confirmed) into an
   existing one; never overwrite an existing block's commands.

This mode never moves, edits or removes an item, never takes anything off a board, and never
changes a tag on an item. A 403 on any write STOPS the mode, naming the permission (tags and tag
groups need `MANAGE_LABELS`), after printing what was already done.

## 4. Report

Per step: `Changed:` and `Result:` in plain words. Then each tag group's previous list, so the
change can be reversed by hand. Running the mode again prints `agents: nothing to change`.
