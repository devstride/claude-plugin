---
load: contract
---
# The build loop's Active Agents step

Only when `.claude/ds-config.json` holds an `activeAgents` block, and only in plan mode: a one-off
has no plan root and does nothing here. **An absent or null block writes nothing and runs
nothing.** The block and its setup: `${CLAUDE_PLUGIN_ROOT}/skills/setup/references/agents-mode.md`.
Every command goes through `python3 ${CLAUDE_PLUGIN_ROOT}/skills/setup/scripts/active-agents.py
run <start|end> <root>`, which refuses anything but an item number for `<root>`, exports
`ACTIVE_AGENTS_ROOT`, `ACTIVE_AGENTS_TAG` and `ACTIVE_AGENTS_STALE_MINUTES`, runs from the
repository root with a 10-second limit and prints one line.

- **Place the root, once per run, after step 0 resolves it.** With `boardId` set: `get_item` the
  root; when it is neither Done nor already on that board, `move_to_board` it there and
  `add_comment` on the root once, naming the board it came from (an item sits on one board, so
  that comment is the reversal record). Already there → no write. Only the plan root is ever
  placed — never a leaf (a Story or Defect), never a grouping item below the root. `boardId` null →
  place nothing; the commands still run.
- **`start`, once per run** (not per story), right after placement.
- **`end` at every terminal exit**: plan complete, DRY-CHAIN, an explicit stop, an unrecoverable
  error. A crash runs no `end`; the repository's own expiry (`staleMinutes`) covers it.
- **Fail open.** `FAILED`, a timeout or a missing command is that one line in the progress table,
  and the loop goes on: presence never blocks a story.
