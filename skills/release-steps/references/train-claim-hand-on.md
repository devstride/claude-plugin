---
load: contract
---
# Hand on the train claim — so the next release's train phase can start

`release-steps`' `train-claim-hand-on@1` step. The rule is
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/auto-start.md` "The train claim" (release it
NON-final), cited, not copied; the release call is
`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/story-claims.md`'s, with kind `release-train`
and the key `auto-start.py key` prints.

1. **Config wins.** Load `.claude/ds-config.json`. No `claims` block → `NOT APPLICABLE`. The
   payload's `shape` is `MERGED` → `NOT APPLICABLE`.
2. **Where it runs.** Scopes `release` and `cut-to-deploy`: right after the cut, while this run
   holds the tower. Scope `merge-and-deploy`, which holds no tower until the final gate: after the
   release pull request is open and the train is level again, since that open pull request is what
   queues every later release behind it.
3. **Only with both `release.clearance` and `release.releaseBranchPattern` set.** Either missing →
   `HELD`, naming it: the release pull request has no tower or branch of its own to protect it, so
   the claim is held until the run ends.
4. **Already handed on** (this run's recorded verdict for this step) → `HANDED ON` again, nothing
   sent.
5. **Release it NON-final**: outcome `handed-on`, never `done`, never `final: true` and never
   `--final`, so the next cycle can claim it. `NOT HOLDER` or `ABSENT` (it lapsed, or another
   session took it over) → also `HANDED ON`, saying who holds it now: either way this run holds it
   no more.
6. From here this run holds no train claim: the loop stops heartbeating it, and the close-out's
   train levelling claims it again (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-branch.md`
   §5 step 3).

## Verdict

`TRAIN CLAIM: HANDED ON | HELD <why> | NOT APPLICABLE`

## Result

`state`: `handed-on`, `held` or `not-applicable`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
