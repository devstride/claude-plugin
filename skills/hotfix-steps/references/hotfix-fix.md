---
load: contract
---
# Make the smallest fix

`hotfix-steps`' `hotfix-fix@1` step. It stands in for the Build step (`build@1` lists it in
`satisfiedBy`), so its result carries the Build keys: the four lists empty for a hotfix, `scopeLine`
one sentence, `head` the commit SHA.

- No fix described, in the payload's `answer` or earlier in the session → `NEEDS DIRECTION what is
  the fix`: ask.
- Make the smallest change that fixes it, then commit and push through the push skill (the
  repository's commit conventions and type-check), and print the commit SHA → `COMMITTED <sha>`.
- The person drops the hotfix → `ABANDONED`, which ends the run.

## Verdict

`HOTFIX FIX: COMMITTED <sha> | NEEDS DIRECTION <what> | ABANDONED`

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/hotfix-steps/SKILL.md`
