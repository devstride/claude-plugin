---
load: contract
---
# Merge to production — through the merge gate, never a push

`release-steps`' `production-merge@1` step. It runs one command: the `MERGE` line of the merge
gate. The floor it keeps is
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/merge-and-deploy.md` "Step 4 — on the yes" and
"Step 5a — the merge and the deploy" (Merge), cited, not copied.

1. **Config wins.** Load `.claude/ds-config.json`: `release.productionBranch`,
   `release.autoDeployOnMerge`, `release.clearance`.
2. **Already merged** — the payload's `shape` is `MERGED`
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`), or the pull request
   already reads `MERGED` → `MERGED <pr>` with its merge commit. A release is never merged twice.
3. **What must hold.** The payload carries the review (`releaseReview`, its `reviewedHead`), the
   pre-ship result, the go-ahead (a yes) and the confirmations (`confirmed`), all for the same
   tree. Under scope `merge-and-deploy`, also the run's last stamp verify (`stamp-verify-final`)
   reads `CHECKS STAMP: UNCHANGED` for this head
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-stamp-verify.md`). One missing
   or not a pass → `REFUSED`, naming it. No yes is ever written for the owner.
4. **A hotfix that landed meanwhile.** `git fetch origin <productionBranch>`: on a release
   branch, a production branch that is not an ancestor of the head → `REFUSED hotfix landed`. The
   catch-up, the review and the go-ahead run again first.
5. **The head to merge.** `<reviewedHead>` is the `reviewedHead` of the payload's `releaseReview`, or the
   pull request's current head when it moved from that SHA only by an advance that keeps the tree
   (`review` 7.3's empty re-trigger commit, a catch-up that answered `SAME TREE`): the rule the
   confirmations applied. Any other head → `REFUSED head moved`.
6. **Run the gate** from the repository's checkout:
   `python3 ${CLAUDE_PLUGIN_ROOT}/skills/pr/scripts/merge-gate.py <n> <reviewedHead> --all-green`,
   and act only on its `MERGE` line (`MERGE <cmd>`, `REFUSE <reason>` or `ERROR <reason>`): run
   exactly that command and nothing else. Never a push to the production branch, never
   `--delete-branch` on a protected branch. `REFUSE` → `REFUSED`; `ERROR`, or no line → `ERROR`.
   The gate's migration rule never covers a pull request into production: each migration was
   approved before it joined
   (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/migration-approval.md` "Where it runs"), and
   the standing yes checks each by content at the go-ahead.
7. **Read it back.** The pull request reads `MERGED` → `MERGED <pr>`; its merge commit is `sha`,
   which the deploy approval and confirmation read. The deploy then runs by itself
   (`release.autoDeployOnMerge`): say it is in flight; never trigger or gate it here.

## Verdict

`PRODUCTION MERGE: MERGED <pr> | REFUSED <reason> | ERROR <reason>`

## Result

`sha`: the merge commit; `pullRequest`: its number. Both absent on a stop.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
