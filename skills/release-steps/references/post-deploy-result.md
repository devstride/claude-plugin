---
load: contract
---
# Post the health result — the status the next release's merge waits on

`release-steps`' `post-deploy-result@1` step (the step `post-deploy-status`), right after the
health check under scopes `cut-to-deploy` and `merge-and-deploy`, and in the post-deploy-only
entry. The rule is `${CLAUDE_PLUGIN_ROOT}/skills/release/references/clearance.md` "Scope
`cut-to-deploy`" (what each health verdict posts) and
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/post-deploy-check.md` "What `release` does with
it", cited, not copied.

1. **Config wins.** Load `.claude/ds-config.json`: `release.clearance` and its `scope`,
   `release.postDeployCheckSkill`. The payload's `scope` wins when set. No clearance block, or
   scope `release` → `NOT APPLICABLE`: no status is posted under the default scope.
2. **Inputs**, from this run's recorded verdicts and results (the runner's `status`, never
   memory): the merge commit (`production-merge`'s `sha`, else `merged-release`'s; the full SHA)
   and the health check's verdict line with its evidence. Here the check
   (`post-deploy-check-owed@1`) never stops the run, so every outcome reaches this step.
3. **What to post** with `${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/post-deploy-status.sh
   <sha> <state> "<description>"` (the description names the release, the machine and the session
   name, as `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/post-deploy-pending.md` step 3
   builds it, then the result):
   - `PASS` → `success` → `SUCCESS POSTED`.
   - `NOT CONFIGURED` → `success`, "no post-deploy check configured", so a pending status never
     holds the next release → `SUCCESS POSTED`.
   - `FAIL` → `failure`, then `FAILURE POSTED`: the run stops for the owner's rollback decision.
     Documentation, notes and the close-out never run on top of it.
   - `NOT RUN`, and the payload's `answer` starts with yes → `success`, "not run - owner
     accepted: <reason>" → `SUCCESS POSTED`; starts with no → `error` → `ERROR POSTED`, and the
     run stops; no answer, or neither → post nothing yet: `NEEDS DECISION <question>`, asking
     the owner to accept the unrun check, with its reason. The runner issues this step again
     with the answer.
   - A check verdict that cannot be read → `error` → `ERROR POSTED`, and the run stops.
   Safe to re-run: it posts from the recorded check verdict each time.
4. **The script's line.** `SKIPPED` or `NOT GATED` → `NOT APPLICABLE`. `FAILED` or exit `1` → one
   more try; still failing → no verdict line, naming the error, and the run stops.
5. **Settle the owed item** once posted: the provider's `owed --done post-deploy-check` (never with
   a provider without `commands.owed`; the owed file is advisory, so this never fails). Under
   `FAIL` it is settled too: the check ran and its result is recorded.

## Verdict

`POST-DEPLOY STATUS: SUCCESS POSTED | FAILURE POSTED | ERROR POSTED | NEEDS DECISION <question> | NOT APPLICABLE`

## Result

`state`: `success-posted`, `failure-posted`, `error-posted`, `needs-decision` or `not-applicable`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
