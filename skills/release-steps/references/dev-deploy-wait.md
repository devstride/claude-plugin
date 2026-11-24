---
load: contract
---
# Wait for the staging deploy — never merge production over a failed one

`release-steps`' `dev-deploy-wait@1` step, at three positions the payload's `step` names. The seam
is `release.devDeployVerification`, its row in
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/docs-hooks.md`; when it runs is
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/merge-and-deploy.md` "Step 4 — on the yes" and,
for scope `merge-and-deploy`, `${CLAUDE_PLUGIN_ROOT}/skills/release/references/clearance.md` (0p),
all cited, not copied.

1. **Config wins.** Load `.claude/ds-config.json`. No `release.devDeployVerification` →
   `NOT APPLICABLE`. The payload's `shape` is `MERGED` → `NOT APPLICABLE`.
2. **Whether this position waits:**
   - `dev-deploy-wait` (scope `merge-and-deploy`, in the checks): every release.
   - `dev-deploy-before-decision` (scopes `release`, `cut-to-deploy`): only when a standing yes is
     configured (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/auto-start.md` "The standing
     yes"), whatever the delta.
   - `dev-deploy-after-yes` (scopes `release`, `cut-to-deploy`): only after the owner's own yes
     (this run's recorded go-ahead verdict, from the runner's `status`), and only when the delta
     touches a `release.releaseBranchFixExclusions` path, matched by the anchored rule of
     `${CLAUDE_PLUGIN_ROOT}/skills/release/references/branch-patterns.md`. A standing yes already
     waited before the decision.
   - Otherwise → `NOT APPLICABLE`.
3. **`RELEASE_COMMIT`**: with a release branch, ALWAYS the cut `<sourceHead>`, on every round
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-branch.md` "Where the cut point
   is read"): the source never deploys a release branch's own commits until the sync, so a later
   round passes the first round's exit through. Without one, `<reviewedHead>`.
4. **Wait**: run the command with `RELEASE_COMMIT` set, in the background. Exit `0` → `SERVING`.
   Exit `2` (not deployed yet) → again every 60 seconds, heartbeating the train claim while the
   run holds it (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
   "Heartbeats") and shown as waiting through the runner's `wait`
   (`${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/references/workflow-runner.md`), for at most 45
   minutes, then `TIMED OUT`. Exit `1`, or any other exit →
   `FAILED`, naming it: production is never merged over a failed development deploy.

## Verdict

`DEV DEPLOY: SERVING | FAILED <reason> | TIMED OUT | NOT APPLICABLE`

## Result

`state`: `serving`, `failed`, `timed-out` or `not-applicable`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-stamp.md` — the round after
  `CHANGED`
