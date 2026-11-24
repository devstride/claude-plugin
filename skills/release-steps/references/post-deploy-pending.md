---
load: contract
---
# Post the pending status — the next release reads "pending", never "no status"

`release-steps`' `post-deploy-pending@1` step (the step `post-pending-status`): under scope
`merge-and-deploy` right after the production merge, under `cut-to-deploy` after the close-out's
branch work and before the hand-back. The rule is
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/clearance.md` "Scope `cut-to-deploy`" (the
pending post) and "Scope `merge-and-deploy`" (posted at the merge), cited, not copied.

1. **Config wins.** Load `.claude/ds-config.json`: `release.clearance` and its `scope`. The
   payload's `scope` wins when it is set. No clearance block, or scope `release` →
   `NOT APPLICABLE`: no status is posted under the default scope.
2. **The merge commit**, from this run's recorded results (the runner's `status`, never memory):
   `production-merge`'s `sha`, else `merged-release`'s (shape `MERGED`,
   `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`: this step still runs,
   so a release adopted after its merge posts the status too). The full 40-character SHA; none
   readable → no verdict line, naming what is missing.
3. **The description** names the release, the machine and the session NAME, never the holder:
   `<release> by <machine> / <session name>: deploying` under `merge-and-deploy`,
   `…: post-deploy check running` under `cut-to-deploy`. `<release>` is the release branch name
   (the pull request's head; `#<n>` when there is no release branch); `<machine>` and
   `<session name>` are the `machine` and `session` of this session's local clearance record
   (`clearance.md` "The local record"; no session name → the machine alone).
4. **Post it:** `${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/post-deploy-status.sh <sha> pending
   "<description>"`.
   - `POST-DEPLOY STATUS: POSTED pending …` → `PENDING POSTED`, quoting that line.
   - `SKIPPED` or `NOT GATED` (the script read the default scope) → `NOT APPLICABLE`.
   - `FAILED` or exit `1` → one more try; failing again → no verdict line, naming the error. The
     run stops before the deploy approval, keeping whatever it holds; re-running this step is the
     recovery. Nothing is posted by hand around the script.
5. Safe to re-run: posting `pending` again on the same commit replaces the same status.

## Verdict

`POST-DEPLOY STATUS: PENDING POSTED | NOT APPLICABLE`

## Result

`state`: `pending-posted` or `not-applicable`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/post-deploy-result.md` — the description
