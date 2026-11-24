---
load: contract
---
# Merge the train — through the merge gate, never a push

`release-steps`' `train-merge@1` step. The procedure is
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-branch.md` §1 step 5, with its "The
exclusion check" and "Release holds"; all cited, not copied.

1. **The train gate**
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/train-finish.md` "The train phase").
   Not applicable, or nothing in flight → `NOT APPLICABLE`. On a re-run after the merge (none
   open, and the latest merged train pull request is the one this run settled) → `MERGED` for
   it, merging nothing.
2. **`<reviewedHead>`** is the head the review step settled: the pull request is ready, its CI is
   settled at that head and nothing was pushed since. The train's pre-ship checks ran at that
   head before this step; a red one already stopped the run, and a fix returns to review, never
   here. A head that moved → `REFUSED`, saying so.
3. **Release holds again, on the final head** (late arrivals, an adopted snapshot), by the helper
   of `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/release-holds.md`. Held → `REFUSED`,
   naming each item and reason.
4. **The exclusion check again**: `git fetch origin <releaseSource>`, then `python3
   ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/train_exclusions.py --config .claude/ds-config.json
   --source-before <sourceBefore> --head <reviewedHead>` (source merges are not train work, and a
   reviewed release unit is allowed). Exit 1 → `REFUSED`, naming the files; exit 2 → `ERROR`.
5. **Merge** by running the `MERGE` line of `python3
   ${CLAUDE_PLUGIN_ROOT}/skills/pr/scripts/merge-gate.py <n> <reviewedHead> --delete-branch` (the
   snapshot is disposable). `REFUSE` → `REFUSED`; `ERROR` → `ERROR`; each with its reason.
   **Never a direct push to the release source**: its own required checks run on the pull request.
6. **Answer** `MERGED`, with the pull request and the merge commit. One-offs that landed on the
   live train after the snapshot ship in the next release.

## Verdict

`TRAIN MERGE: MERGED <pr> | REFUSED <reason> | ERROR <reason> | NOT APPLICABLE`

## Result

`state`: `merged`, `refused`, `error` or `not-applicable`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
