---
load: contract
---
# Report the cut

`hotfix-steps`' `hotfix-report@1` step. Confirm the current branch (`git rev-parse --abbrev-ref
HEAD`) and the push; report the full branch name, what happened at each step, and which environment
case was taken (`case`: `1`, `2`, `3` or `none`). Then say what comes next: describe the fix, and the
workflow makes it.

## Verdict

`HOTFIX CUT: DONE <branch>`

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/hotfix-steps/SKILL.md`
