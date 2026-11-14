---
load: contract
---
# `setup boards` — which board each kind of item goes on

Asks the engineer where work belongs and writes the answer as ordered rules. It reads DevStride
and **never writes to it**: no item is moved here. Every check and every resolution is
`python3 ${CLAUDE_PLUGIN_ROOT}/skills/setup/scripts/board-placement.py` — never decided by eye.
The build loop's half is `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/board-placement.md`;
doctor's read-only half is `${CLAUDE_PLUGIN_ROOT}/skills/doctor/references/boards.md`.

## The block (`.claude/ds-config.json`)

`boardPlacement`: `null`, or `{ rules: [ { name?, match?, place } … ] }`, read top to bottom,
**first match wins**.

- `match` — every condition named must hold, and a list holds when any entry does: `workType`
  (names, any case), `team` (team ids), `tag` (tag names, any case), `customField`
  (`{ "<field id>": [values] }`: the values as items carry them, so a choice field's option
  ids, never their labels), `under` (item or workstream numbers: the item sits anywhere
  beneath one). No `match` matches every item.
- `place` — exactly one of `{ board: <board id> }` (one long-lived board), `{ cycleFolder:
  <board folder id> }` (the dated board directly in that folder whose dates cover the day the
  work starts) or `{ none: true }` (stays off boards).

Work is placed **when it starts**, never when it is planned: `plan` and the insert skills still
create items with no board, the build loop places each item and its release unit as it picks
them up, and a one-off is placed as it is created. **An absent or null block changes
nothing**: nothing is placed, a one-off's board is asked as before, and personal rules are
ignored. A rule may never place on `activeAgents.boardId`; that board holds plan roots, and only
`build-item` places them.

## Personal rules — one contributor, one machine

`/devstride:setup boards personal` runs the same mode for the person at the keyboard and writes
only the file `personal-path` prints (outside the repository, shared by every checkout of it on
that machine): `{ rules: [ … ] }`, the same rule shape. Personal rules are read **before** the
repository's, so a contributor states only what differs for them. They only override a
repository block: with none, say so and offer the repository run first. Never written to the
repository, never committed, and never created unasked.

## 0. A full `/devstride:setup` run asks too

`validate` first. `NOT CONFIGURED` → the full run asks §2's questions with its other Phase D
questions (after §1's inventory, read-only), then applies §3 — the scratch check, the plan and
its own typed yes — and only then writes the block with the rest of the config in Phase E; an
engineer who declines gets one plan line, "Board placement: not set; `/devstride:setup boards`
asks later". `VALID` → one Phase B row: the rules in order, in plain
words. `INVALID` → its `ERROR` lines as Phase B failures. No DevStride connection → said so,
nothing asked, nothing written.

## 1. Inventory — read-only

- The organization's name (`get_workspace_context`), so the answers are given for the right one.
- **The placed types**: every leaf type (`hierarchyRoles.leaf`, else the hierarchy's childless
  levels) and the release unit (`hierarchyRoles.releaseUnit`, else as the hierarchy resolves it),
  from `get_work_type_hierarchy`. Levels above the release unit are not asked about.
- **The boards**: `list_boards` (every page; archived ones left out). A board with `startDate`
  and `endDate` is a **cycle board**; its `boardFolderId` is a **cycle folder**, named by the last
  folder label in the board's `hierarchy`. Every other board is **perpetual**. One folder can
  hold both kinds, and a cycle folder can sit inside another: each folder is its own answer.
  Leave `activeAgents.boardId` out of every list of choices; the script still gets every board.
- Teams (`list_teams`), and tags and custom fields with their options
  (`get_organization_metadata`, `include: "all"`), for §2's exceptions and §3's check.
- The rules already there (`validate`'s second line), shown first: a run changes what the
  engineer names and keeps the rest. Keep only those whose `source` is `repository` (a personal
  run: `personal`), and write them back without the `source` key. `INVALID` prints no rules:
  show its `ERROR` lines and read the rules from the file itself.

## 2. The questions

Ask in this order; one question at a time, each with the inventory's real names:

1. **How the team works.** No cycle folder → the choices are the perpetual boards. No perpetual
   board → the cycle folders. Both → say so and let the engineer mix.
2. **Each placed type, one at a time**: "Where does a <type> go when work on it starts?" The
   choices are each cycle folder ("the <folder> cycle running that day — today that is <board>",
   from `current --folder <id>`, stdin `{ boards, date }`), each perpetual board, and "no
   board". Propose, never assume: one perpetual
   board and no cycles → that board for every type; two cycle folders, one inside the other or
   one with longer cycles → the longer cycles for the release unit and the shorter for the
   leaves. Types given the same answer share one rule.
3. **Exceptions.** "Does any work go somewhere else — by team, tag, a custom field's value, or
   the part of the map it sits under?" Each yes becomes a rule placed **before** the type rules,
   most specific first; resolve every name to what the rule stores (`resolve_team`, the tag's
   name, the custom field's id and a choice's option id, `resolve_item` for a number) and ask
   again until the answer is no. Never invent an exception the engineer did not state.
4. **Everything else.** Offered only when a placed type is still unanswered: a last rule with no
   `match`, or leaving that type off boards.

`personal`: ask only "what differs for you?" — question 3's shape — and stop at the first no.

## 3. The plan, then a typed yes

Copy the whole config (on a first full run, the one about to be written), with the proposed
block in it, to a file in a temporary directory outside the repository (the rules are checked
against the rest of the config, `activeAgents.boardId` included). Pass it as `--config`, and a
`--personal` beside it, to all three commands: for a personal run the scratch file holding the
proposed personal rules, for a repository run a path that does not exist, so the engineer's own
rules never colour the team's check. `validate`, then `classify` with the inventory (`boards`, today's `date`,
`placedTypes`, `workTypes`, `teams` (ids), `tags` (names), `customFields` (ids)). Print the organization's name; the
rules in order, one plain sentence each; then, per placed type, where an item of that type
starting today would go (`resolve`, `item` `{ workType: <type>, boardId: null }`). Print every `classify` finding. A FAIL finding → fix the
answer with the engineer first; never write rules that fail. `no-current-cycle` alone is the
exception: only the owner can create that cycle's board, so say it plainly and go on. Then ask, and write only on a
**typed yes** naming this plan; anything else writes nothing.

## 4. Write

- **Repository**: merge `boardPlacement` into `.claude/ds-config.json` by setup's Phase F rule,
  touching no other key. Give each rule a `name` in the engineer's words.
- **Personal**: write the file `personal-path` prints, creating its folder; nothing in the
  repository changes. An emptied personal answer deletes that file, after saying so.

Then `validate` on what was written, and report `Changed:` and `Result:` in plain words, with
the line: "Work already on a board stays where it is; new work is placed as it starts."
Running the mode again with nothing to change prints `boards: nothing to change`.

## Cited by

- `skills/setup/SKILL.md` (the `boards` mode, and a full run's questions)
- `skills/build-item/references/board-placement.md`
- `skills/doctor/references/boards.md`
- `skills/setup/references/config-defaults.md` (Board placement)
