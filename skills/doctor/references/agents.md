---
load: contract
---
# doctor `agents` — the Active Agents block, read-only

**Doctor writes nothing here**, in DevStride or anywhere else: only `get_board`, `search_items`,
`get_organization_metadata`, `get_work_type_hierarchy` and
`python3 ${CLAUDE_PLUGIN_ROOT}/skills/setup/scripts/active-agents.py` (`validate`, `classify`).
The block and what it needs: `${CLAUDE_PLUGIN_ROOT}/skills/setup/references/agents-mode.md`.

- **No block** (absent or null) → N/A: "agents: not configured (by design)". Never a finding.
- **The block is valid** — `validate`; each `ERROR` line is a FAIL.
- **`boardId` null** → FAIL: the board is not adopted, so the build loop places no root.
- **The snapshot** — build `classify`'s input: the board (`get_board`: exists, archived); its
  items with their work types (`search_items`, every page); the leaf types (`hierarchyRoles.leaf`,
  else the hierarchy's childless levels) and the plan-root types (every other type) with each
  one's tag group; the tag (by `tagName`) and every tag group's list
  (`get_organization_metadata`, `include: "all"`); the items carrying the tag, with whether each
  is Done (`search_items` on the tag). Each finding is a FAIL:
  - `board` — missing or archived; `tag` — missing; `tag-allowed` — a plan-root type whose tag
    group lacks the tag. Fix for these three: `/devstride:setup agents`.
  - `leaf-on-board` — leaf items (Stories, Defects) on the board: the count, then the first five
    numbers. `tag-on-done` — the tag on a Done item: the numbers. Fix: those items, by hand.
  - `tag-group` — a plan-root type with no tag group: INFO, skipped by setup.
- **The commands** — both present, `<root>` in `start`, and each command's first word found on
  the path or in the repository (`command -v`), **never executed**.
