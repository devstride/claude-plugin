---
load: contract
---
# Release safety hooks — classifying a release and checking production before the merge

Two optional hooks let a repository tell `release` what only it knows: whether this release may
take the lighter path, and whether anything must be done in production before the merge. Both are
SAFETY hooks (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/step-skills.md`): when one is
missing, failing or unreadable, the release takes the stricter path. This file is the authority
for both; `classify-release`, `pre-merge-check`, `release` and `doctor` cite it.

## Config keys

```json
{ "release": { "classifySkill": null, "preMergeSkill": null } }
```

Each names a LOCAL skill (a directory under `.claude/skills/`), invoked with the Skill tool by that
name, a mode word, and a fenced JSON payload. `null` or absent means not configured.

## `release.classifySkill` — light or full

- **When:** `release` step 0, once the release head is known; the step is `classify-release`.
- **Invocation:** `classify` and `{ "productionBranch": "<name>", "releaseSource": "<name>",
  "head": "<sha>" }`.
- **First line:** exactly `RELEASE CLASS: LIGHT` or `RELEASE CLASS: FULL`, then one line giving
  the reason (the paths or rule that decided it). What "light" lets the release skip is the
  repository's own rule; the plugin only carries the class.
- **Unset, a name with no `SKILL.md`, a failing run or any other first line:** `RELEASE CLASS:
  FULL`, with the reason. A release is never light by default.
- **Where it goes:** the class and reason print in step 0's delta summary and the step-4 recap,
  and step 2b exports it to every pre-ship command as `RELEASE_CLASS=light|full`.

## `release.preMergeSkill` — anything production needs before the merge

- **When:** `release` step 4, after the PR is green and settled and BEFORE the owner is asked for
  the go-ahead; the step is `pre-merge-check`. Read-only: it reports, it never changes production.
- **Invocation:** `check` and `{ "productionBranch": "<name>", "releaseSource": "<name>",
  "head": "<sha>", "pullRequest": { "number": 0, "url": "..." } }`.
- **First line:** exactly one of `PRE-MERGE: CLEAR`, `PRE-MERGE: HOLD` or `PRE-MERGE: NOT RUN`,
  then evidence lines, each naming the command that produced it. A HOLD states the action that
  must happen first (a checkpoint, a backfill, a setting).

| Result | `release` |
|---|---|
| `CLEAR` | Print it in the go-ahead summary and ask for the yes as usual. |
| `HOLD` | STOP before asking: surface the stated action; ask again once it is done and the step re-run reads CLEAR. |
| `NOT RUN`, a failing run or an unreadable first line | Report `PRE-MERGE: NOT RUN` with the reason and ask the owner whether to proceed. Never a pass. |
| Unset | Print **pre-merge production check: not configured** in the go-ahead summary and the recap. Never read as "nothing needed". |

## Cited by

- `skills/classify-release/SKILL.md`, `skills/pre-merge-check/SKILL.md` — the two steps.
- `skills/release/SKILL.md` — steps 0, 2b and 4.
- `skills/doctor/SKILL.md` — section 7, the hook loop.
