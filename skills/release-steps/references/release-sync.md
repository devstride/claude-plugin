---
load: contract
---
# Sync production back — the release branch's fixes reach the release source

`release-steps`' `release-sync@1` step (the step `sync-production`), the first of the close-out's
branch work. The procedure is `${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-branch.md`
§5 step 1, cited, not copied: the configured sync job's wait, the branch name, the merge and the
merge gate are read there.

1. **Config wins.** Load `.claude/ds-config.json`: `release.productionBranch`,
   `release.releaseSource`, `release.syncWorkflow`, `branchNaming`, `release.clearance` and its
   `scope` (the payload's `scope` wins when set).
2. **What must hold first**, from this run's recorded verdicts (the runner's `status`, never
   memory): the deploy confirmed, and under scope `release` the health check passed (`PASS`,
   `NOT CONFIGURED`, or an accepted `NOT RUN`); under `merge-and-deploy` its status posted
   (`SUCCESS POSTED`). Otherwise → `STOPPED <why>`: nothing is synced over a release whose health
   is in question.
3. **Heartbeat.** Scope `release` or `cut-to-deploy`: send the tower `heartbeat close-out` first,
   only when this session's local clearance record shows it holds the tower
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md` "Heartbeats"); exit
   `4` → no verdict line, and the run stops. Under `merge-and-deploy` nothing is held: no
   heartbeat.
4. **Fresh refs**: `git checkout <productionBranch> && git pull --ff-only`, the release source
   likewise, then `git fetch origin <productionBranch> <releaseSource>`. Already `git merge-base
   --is-ancestor origin/<productionBranch> origin/<releaseSource>` → `ALREADY SYNCED`.
5. **Sync** by §5 step 1 exactly. With the sync job configured: open nothing, re-fetch every
   minute until the source contains production, for at most 90 minutes; its pull request left
   open (a conflict, a failed check) or the time running out → `STOPPED <why>` with its link.
   Otherwise the `sync-<productionBranch>-into-<releaseSource>` branch, `git merge --no-ff
   origin/<productionBranch>` (a conflict → `STOPPED`, naming the files), push, **`pr` driven**
   with the base passed explicitly, `merge-only: true` and a scope manifest naming only the
   conflict resolutions, then the `MERGE` line of `python3
   ${CLAUDE_PLUGIN_ROOT}/skills/pr/scripts/merge-gate.py <n> <settled head> --delete-branch`
   (the sync branch is disposable; never a protected one). `REFUSE` or `ERROR` → `STOPPED`.
   Then `git fetch origin <productionBranch> <releaseSource>` again → `DONE`.
6. **Settle.** Under `merge-and-deploy`, after `DONE` or `ALREADY SYNCED`: the provider's
   `owed --done sync --pr <n>` (the release behind brings production in itself, so it never waited on
   this). The release-branch deletion and the train levelling follow as their own steps. A
   provider without `commands.owed` gets no `owed` call.

## Verdict

`SYNC: DONE | ALREADY SYNCED | STOPPED <why>`

## Result

`state`: `done`, `already-synced` or `stopped`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
