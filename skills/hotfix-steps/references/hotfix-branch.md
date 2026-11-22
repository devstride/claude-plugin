---
load: contract
---
# Cut the branch — from a fresh copy of production

`hotfix-steps`' `hotfix-branch@1` step.

- **Name**: `<user-prefix>/hotfix/<date>/<branch-name>` — the `/hotfix/` infix is fixed; the prefix
  and the date format come from `branchNaming` (`branchNaming.dateFormat`, shipped default
  `MM-DD-YY`, today). `<user-prefix>` = first name from `git config user.name`, lowercased
  ("Jane Doe" → `jane/hotfix/01-23-26/fix-login-crash`); the preflight's `hotfix-name.py` made it.
- **Steps.** `git checkout <hotfixBaseBranch>`, then `git pull`; `git checkout -b <hotfix-branch>`,
  then `git push -u origin <hotfix-branch>`; with `claims` set, declare it through
  `${CLAUDE_PLUGIN_ROOT}/skills/build-item/scripts/ship-intent.py` (`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/ship-intent.md`):
  route hotfix, target the production branch, stage building. Without a `claims` block: none, and no
  mention.
- **Safe to re-run.** The branch already exists at the base with nothing beyond it → check it out and
  answer `CUT`; a local branch of that name already carrying commits beyond the base → `FAILED
  name-collision`, never reset.
- **Never delete the previous branch** — keep it until the hotfix merges.
- **On failure** name the failed step and its output, say which branch the checkout is on now (a
  failure in the checkout or pull, or in the cut before the branch exists, leaves it ON the
  production branch — easy to overlook), and ask before changing anything else.

## Verdict

`HOTFIX BRANCH: CUT <branch> | FAILED <step>`

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/hotfix-steps/SKILL.md`
