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
rootLevel (a work type name or null, default null: the level directly above the release unit),
commands: { start, end } }`. `rootLevel` is the level whose nearest item above a picked-up item
counts as its plan on the board. `commands.start` must contain `<root>`; `commands.end` may. Both
are the repository's own commands; the plugin never writes or guesses them, and asks for them when the
block has none. `boardId: null` means "not adopted yet": the build loop places no root until this
mode sets it. **An absent or null block writes nothing and runs nothing, ever** — in the build loop
and doctor. This mode is how a block comes to exist: with none, it asks for the two commands
first and writes nothing anywhere until they and the plan get the typed yes.

## 0. The scan — every full `/devstride:setup` run too

Read-only, the same scan doctor runs (`${CLAUDE_PLUGIN_ROOT}/skills/doctor/references/agents.md`,
"No block"): with no block, `list_boards` into `classify` with `configured: false`. A full run
reports its finding with the other Phase B rows and, when the block is absent, adds one line to
its plan: "Active Agents: <the finding>; `/devstride:setup agents` sets it up after a typed yes".
No DevStride connection → the scan is UNVERIFIABLE, said so. A full run never writes the block,
and never writes to DevStride: only this mode does, on its own typed yes.

## 1. Inventory — read-only

`validate`, then: the connected organization's name (`get_workspace_context`); the board
(`get_board` for a configured id, else `list_boards` for a board labelled exactly "Active
Agents"); tags, tag groups (label collections) and work types (`get_organization_metadata` with
`include: "all"`); the hierarchy (`get_work_type_hierarchy`). The **plan-root types** are every work
type that is not a leaf role (`hierarchyRoles.leaf`, else the childless levels of the hierarchy).
Views: `list_views` with location `board`, piped to `pick-view`. A board table view is offered
on every board, not only this one.

## 2. The plan, then a typed yes

Print the organization's name, then one line per change: the tag to create (or the colour it
would change), each tag group to change as `merge-labels`' exact before and after, the board to
adopt or create, the view to adopt or create (each `VIEW DUPLICATE` named for the owner to
remove), `rootLevel` (proposed as the level above the release unit, spelled as
`get_work_type_hierarchy` spells it; the owner may name another non-leaf level), and the block to
write or merge. Nothing to change → print
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
4. **The view.** Adopt before creating: `pick-view`'s `VIEW ADOPT <id>` is the view, and its
   columns are left exactly as the owner made them; each `VIEW DUPLICATE` is reported, never
   deleted or renamed. `VIEW CREATE` → `create_table_view` with location `board`, label "Active
   Agents", visibility `internal`, `show` `identifier`, `status`, `progress`, `priority`,
   `pullRequests`, `tags` (Item, Status, Progress, Priority, Pull Requests, Tags) and `others`
   `hide`; then read it back with `get_view_columns` and confirm those six show, in that order.
   Columns are set only when the view is created, never re-applied to an existing one; later
   changes are the owner's (`set_view_columns`, or the app). **The DevStride connection
   lacks these tools, or the read-back differs → create everything else, report the view NOT
   created (or not as planned) with that reason, and name it as the one owner step.**
5. **The block.** Create it, or merge `boardId` (and any default the owner confirmed, `rootLevel`
   included) into an existing one; never overwrite an existing block's commands, and never change
   an existing `rootLevel` the plan did not name.

This mode never moves, edits or removes an item, never takes anything off a board, and never
changes a tag on an item. A 403 on any write STOPS the mode, naming the permission (tags and tag
groups need `MANAGE_LABELS`), after printing what was already done.

## 4. Report

Per step: `Changed:` and `Result:` in plain words. Then each tag group's previous list, so the
change can be reversed by hand. Running the mode again prints `agents: nothing to change`.

## Cited by

- `skills/setup/SKILL.md` (the `agents` mode, and a full run's scan)
- `skills/build-item/references/active-agents.md`
- `skills/doctor/references/agents.md`
- `skills/setup/references/config-defaults.md` (Active Agents)
