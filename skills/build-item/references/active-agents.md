---
load: contract
---
# The build loop's Active Agents step

Only when `.claude/ds-config.json` holds an `activeAgents` block, and only in plan mode: a one-off
has no plan root and does nothing here. **An absent or null block writes nothing and runs
nothing.** The block and its setup: `${CLAUDE_PLUGIN_ROOT}/skills/setup/references/agents-mode.md`.
Every decision and command is `python3 ${CLAUDE_PLUGIN_ROOT}/skills/setup/scripts/active-agents.py
<subcommand>`, never judged by eye; `run <start|end> <root>` takes only an item number, exports
`ACTIVE_AGENTS_ROOT`, `ACTIVE_AGENTS_TAG` and `ACTIVE_AGENTS_STALE_MINUTES`, runs from the
repository root with a 10-second limit and prints one line.

## 1. Every pickup: resolve the board root, place it

At **each** item picked up (every iteration, a given item number too), after step 0 selects it:

- **`resolve-root`**, on stdin: `chain` — the item, then every ancestor upward (`get_item`,
  `view: 'full'`: number, work type, description), `deferred: true` on the deferred container and
  all under it (`deferred-container.py members`); `rootLevel` — `activeAgents.rootLevel`, else
  the release unit's first permitted parent (`get_work_type_hierarchy`; the release unit is
  `hierarchyRoles.releaseUnit`, else the working base's derivation); `leafTypes`; `argument` —
  the item `--board-root I<n>` names (number, work type); `planRoot` — step 0's root. First match
  wins: the argument, the nearest description carrying `<p><strong>Active Agents root:</strong>
  this item</p>` (the owner's per-plan override; no skill writes it unasked), the nearest
  `rootLevel` item, the plan root. A workstream, a leaf or a deferred item is never a root.
  `ROOT NONE` → one progress-table line, nothing placed. **Never a question, never a stop.**
- **Place** (`boardId` set): `get_item` the root; Done or already on that board → no write. Else
  `move_to_board` it to `boardId`, then `add_comment` with the `{ html }` of `comment placed
  --board <its old board id> --label <its label>` (bare `comment placed` from no board): the
  reversal record. A root taken off by hand comes back at the next pickup. Only a resolved root is
  ever placed — never a leaf (a Story or Defect). `boardId` null → nothing placed; commands run.
- **`start` once per root per run**, after its first placement check. A pickup resolving another
  root (or `ROOT NONE`) runs `end` for the old one first.

## 2. After each merge and at every terminal exit: a finished plan comes off

After step 6 records a merge, and at every terminal exit (plan complete, DRY-CHAIN, an explicit
stop, an unrecoverable error), for each root this run started (at a terminal exit before any
pickup: the root `resolve-root` gives with the plan root as the item):

1. `remaining` — its value leaves by step 7's count: `hierarchyRoles.leaf` descendants neither
   Done nor landed; the deferred container counts in neither.
2. `get_item` it (on `boardId`?); `came-from` on `list_comments` (html, `dateAdded`); `get_board`
   the board that names (exists, archived).
3. `settle`: `KEEP` → nothing; `MOVE <id>` → `move_to_board` there; `OFF` → `update_item` with
   `boardId: null`. After either, `add_comment` with `comment removed` (`--board <id> --label
   <label>` for `MOVE`).
4. `remaining` zero, or a terminal exit → `end` for it, once.

Two plans under one root: off only when both finish. Off, then new work → back on at its next
pickup. **The tag is never touched here**: it follows the repository's claims, which `end`
releases. A crash runs no `end`; `staleMinutes` covers it, and the next pickup or this step
settles the placement.

## 3. Fail open

`FAILED`, a timeout, a missing command, an exit 2 from the script, or a 403 on a move or comment is
one line in the progress table, and the loop goes on: presence never blocks a story.

## Cited by

- `skills/build-item/SKILL.md` step 0 (Active Agents)
- `skills/setup/references/agents-mode.md`
- `skills/setup/references/config-defaults.md` (Active Agents)
