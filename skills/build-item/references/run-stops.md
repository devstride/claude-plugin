---
load: contract
---
# Run stops — what the loop does when the Build run stops

`build-item`'s answer to a `stopped` run, beyond a question (`needs-person`) and a red local check,
which its The run section handles itself. Read in full before acting on any other stop.

- **A merge stop** (`merge` failed, or a `merge-lands-what-was-checked` proof stop): first check
  whether the commit landed (`merge-paths.md`, "Already landed"). Landed → report it with `done`
  on the stopped merge, its result naming the merge and its proof's `head` the commit the
  payload named; never `resume`, which would read the moved checkout as new work.
- **A merge `BLOCKED` on excluded paths** (a train one-off carrying deploy configuration or a
  migration): move the story branch with `git rebase --onto origin/<baseBranch> origin/<train>`,
  then `git push --force-with-lease` it, so its pushed copy is the rebased branch (its receipt is
  void); `start` again with `replace`, the base branch as working base, route `develop-pr` and
  `reviewMoment` `pr-boundary`. The new run's branch step answers `EXISTS` on it and its build
  step finds the story already built (`ultracode-build`, "Already built"), so the risk check,
  the local checks and the pull-request review run on the moved branch.
- **Any other stop, or a question left unanswered: the run waits for this session.** Keep the
  lease (`checkout-pool-commands.md`: a STOP this session will resume keeps it), say in one line
  what is still held (the lease, the story branch, the open run and its step) and how to go on
  (`/devstride:build-item <item>` resumes it), and end the turn. Never `return-checkout` here.

## Cited by

- `skills/build-item/SKILL.md` — The run, its `stopped` answer ("read … in full before acting on
  it").
