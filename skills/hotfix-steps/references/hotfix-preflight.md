---
load: contract
---
# Preflight — the tree is clean and the branch has a name

`hotfix-steps`' `hotfix-preflight@1` step, the first step of the Hotfix workflow. It reads only.

- **Config wins.** Load `.claude/ds-config.json` first: `hotfixBaseBranch` (shipped default
  `master`) is the base wherever `master` appears below; `protectedBranches`; `branchNaming`;
  `localEnvironment`; `stage`. Inline literals are defaults — **if the file disagrees, the file
  wins**; no file → defaults, said so (`configSource`: `file` or `defaults`).
- **Clean tree first.** `git status --porcelain` dirty → `DIRTY`: STOP and ask whether to stash or
  commit; never carry changes onto the production branch.
- **Recommend stopping any running dev server BEFORE the switch** — production code under a server
  or a database migrated to the development schema causes confusing failures. It runs in the user's
  terminal, so remind them now; you cannot stop it.
- **The name** comes from `python3 ${CLAUDE_PLUGIN_ROOT}/skills/hotfix-steps/scripts/hotfix-name.py`, given
  `{config, userName, branchArgument, today}` on stdin (`userName` from `git config user.name`,
  `today` the local date). No branch argument and none in `answer` → `NEEDS INPUT branch name`; an
  empty or ambiguous user name (exit 2) → `NEEDS INPUT user name`: ask.

## Verdict

`HOTFIX PREFLIGHT: READY <branch> | DIRTY | NEEDS INPUT <what> | FAILED <why>`

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/hotfix-steps/SKILL.md`
