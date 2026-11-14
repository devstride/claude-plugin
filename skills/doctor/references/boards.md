---
load: contract
---
# doctor — board placement rules, read-only

Part of the `agents` section. **Doctor writes nothing here**: only `list_boards`, `list_teams`,
`get_work_type_hierarchy`, `get_organization_metadata` and `python3
${CLAUDE_PLUGIN_ROOT}/skills/setup/scripts/board-placement.py` (`validate`, `classify`). The
rules and how they are set: `${CLAUDE_PLUGIN_ROOT}/skills/setup/references/boards-mode.md`. Each
finding's severity is the `severity` `classify` gives it.

- **`validate`.** `NOT CONFIGURED` → INFO "no board placement rules; `/devstride:setup boards`
  asks where each kind of item goes"; a `NOTE` line under it (personal rules that are ignored
  without a repository block) is a second INFO, and nothing else is checked. `INVALID` → each
  `ERROR` line is a FAIL and nothing else is checked; fix: the named rule, by hand or with
  `/devstride:setup boards`. (`classify` names these `not-configured`, `personal-ignored` and
  `invalid`.)
- **The snapshot** — `classify`'s input: `boards` (`list_boards`, every page, archived ones
  included: `id`, `label`, `boardFolderId`, `archived`, `startDate`, `endDate`); `date` — today;
  `placedTypes` — every leaf type (`hierarchyRoles.leaf`, else the hierarchy's childless levels)
  and the release unit; `workTypes`, `teams` (ids), `tags` (names) and `customFields` (ids) as
  the organization has them (`get_work_type_hierarchy`, `list_teams`,
  `get_organization_metadata` with `include: "all"`).
  - `rule-board` — a rule's board is missing or archived, or today's board in its cycle folder
    is the Active Agents board. `rule-folder` — a rule's cycle folder
    holds no dated board. `unknown-worktype`, `unknown-team`, `unknown-tag`, `unknown-field` — a
    rule names something the organization does not have. `uncovered-type` — a leaf type or the
    release unit that no rule answers for. Fix for all of these: `/devstride:setup boards`.
  - `no-current-cycle` — no dated board in a rule's folder covers today, so work starting today
    is not placed. Fix, by the owner: create that cycle's board in DevStride; doctor never does.
  - `no-next-cycle` — INFO: no board covers the day after today's cycle ends; name that day.
  - `unreachable` — INFO: a rule that an earlier rule with no conditions always beats.
  - `personal` — INFO: this machine's personal rules apply before the repository's; name the
    file, so a placement that differs from a teammate's is explained.
- **No DevStride connection** → the snapshot is UNVERIFIABLE, said so; `validate` still runs.

## Cited by

- `skills/doctor/references/agents.md` (board placement)
- `skills/setup/references/boards-mode.md`
