---
load: contract
---
# doctor `agents` — the Active Agents block, read-only

**Doctor writes nothing here**, in DevStride or anywhere else: only `list_boards`, `get_board`,
`search_items`, `list_comments`, `get_organization_metadata`, `get_work_type_hierarchy`,
`list_views`, `get_view_columns` and `python3 ${CLAUDE_PLUGIN_ROOT}/skills/setup/scripts/active-agents.py`
(`validate`, `classify`). The block and what it needs:
`${CLAUDE_PLUGIN_ROOT}/skills/setup/references/agents-mode.md`. Each finding's severity is the
`severity` `classify` gives it.

- **No block** (absent or null) → still look for the board: `list_boards` (every page) into
  `classify` with `configured: false` and `boards` (id, label, archived). `not-adopted` → INFO
  "Active Agents board found but not adopted; run `/devstride:setup agents`". `no-board` → INFO
  "no Active Agents board; `/devstride:setup agents` creates one". Neither is a FAIL, and nothing
  else is checked.
- **The block is valid** — `validate`; each `ERROR` line is a FAIL.
- **`boardId` null** → FAIL: the board is not adopted, so the build loop places no root.
- **The snapshot** — build `classify`'s input: the board (`get_board`: exists, archived); its
  items with their work types (`search_items`, every page), and for each item that is not a leaf
  its `remaining` value leaves (`hierarchyRoles.leaf` descendants neither Done nor landed, the
  deferred container counting in neither; without git, a leaf counts as landed by its status or
  landed comment); the leaf types (`hierarchyRoles.leaf`, else the hierarchy's childless levels)
  and the plan-root types (every other type) with each one's tag group; `rootLevel` as the block
  sets it; the tag (by `tagName`) and every tag group's list (`get_organization_metadata`,
  `include: "all"`); the items carrying the tag, with whether each is Done (`search_items` on the
  tag); the board table views (`list_views`, location `board`), the adopted one with its columns
  (`get_view_columns`: identifier and visible; a layout it does not save is an empty list).
  - `board` — missing or archived; `tag` — missing; `tag-allowed` — a plan-root type whose tag
    group lacks the tag. Fix for these three: `/devstride:setup agents`.
  - `root-level` — `rootLevel` names no work type above the leaves (matched case-insensitively,
    so an organization's own spelling works when written that way). Fix: the block, by hand.
  - `done-on-board` — a plan root on the board with nothing left to build: the numbers. Fix, by
    the owner: move it back by hand, or run `/devstride:build-item <root> --board-root <root>`
    (its terminal exit takes that root off, back to the board it came from, but the run may first
    carry landed work on to its release). Report only: doctor never runs or offers that run.
  - `leaf-on-board` — leaf items (Stories, Defects) on the board: the count, then the first five
    numbers. `tag-on-done` — the tag on a Done item: the numbers. Fix: those items, by hand.
  - `tag-group` — a plan-root type with no tag group: INFO, skipped by setup.
  - `view` — INFO, never a FAIL (the owner may have changed the columns on purpose): no shared
    Active Agents table view (fix: `/devstride:setup agents`), more than one (the duplicates are
    for the owner to remove), or a starting column the view does not show.
- **The commands** — both present, `<root>` in `start`, and each resolves by doctor's §4 rule
  (every `&&` and `;` segment's first word, shell builtins skipped, `command -v`),
  **never executed**.
- **The DevStride connection lacks `list_views` or `get_view_columns`** → the `view` check is
  UNVERIFIABLE, said so; the rest still runs.

## Cited by

- `skills/doctor/SKILL.md` §8
- `skills/setup/references/agents-mode.md` (the scan)
