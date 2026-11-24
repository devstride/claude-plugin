---
load: contract
---
# Prove the CI hold — CI can stay last before anything opens

`release-steps`' `ci-hold-proof@1` step. It reads only. CI runs last and once: the release pull
request is a draft whenever pull-request workflows exist, and the review's ready flip releases CI
on the final reviewed head. This step proves that can hold before any pull request is opened.

1. Inspect the repository's pull-request workflows, leaving out the convention-only shape defined
   in `${CLAUDE_PLUGIN_ROOT}/skills/setup/references/ci-cost-patterns.md` (a policy notice, not a
   CI gate).
2. **None left** → `NO PULL-REQUEST CI`: a valid release with no CI. Say so; the release pull
   request then opens without the draft flag.
3. **Every expensive pull-request workflow carries every draft-hold flag, each true** → `PROVEN`.
4. **Anything else** → `NOT PROVEN`, naming the workflow and the facts found, and pointing at
   `/devstride:setup ci`. A flag that is false, facts that are mixed across workflows, or facts
   that cannot be read prove no hold: never open a release on them.

## Verdict

`CI HOLD: PROVEN | NO PULL-REQUEST CI | NOT PROVEN <facts>`

## Result

`state`: `proven`, `no-pull-request-ci` or `not-proven`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
