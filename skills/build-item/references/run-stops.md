---
load: contract
---
# Run stops — what the loop does when the Build run stops

`build-item`'s answer to a `stopped` run, beyond a question (`needs-person`) and a red local check,
which its The run section handles itself. Read in full before acting on any other stop.

- **A merge stop**: a `stopped` answer carrying `mayHaveLanded` (from `done`, or from `resume`,
  which answers with that stop until told otherwise). First check whether exactly the stopped
  merge's commit landed (`merge-paths.md`, "Already landed", for the stop's `commit`). Exactly it → report it with `done` on the stopped merge (its `attempt`), its
  result naming the merge and its proof's `head` that commit; never `resume`, which would read the
  moved checkout as new work. Another commit landed carrying it → a person decides, said plainly:
  what landed was never checked or reviewed. Nothing landed → put the checkout back on the story
  branch, then `resume` with `"landed": false`: at once for a push refused in a race (the merge
  step tries again), otherwise once its cause is fixed.
- **A merge `BLOCKED` on excluded paths** (a train one-off carrying deploy configuration or a
  migration): never on a protected or merge-only head (`protectedBranches`, an epic or plan
  integration branch, the train:
  `${CLAUDE_PLUGIN_ROOT}/skills/release/references/branch-patterns.md`, "Protected and merge-only
  heads") → a person. Read `pushed=$(git rev-parse origin/<branch>)`, move the story branch by name
  with `git rebase --onto origin/<baseBranch> origin/<train> <branch>`, then push that one ref
  with an explicit lease: `git push --force-with-lease=refs/heads/<branch>:$pushed origin
  refs/heads/<branch>:refs/heads/<branch>` (its receipt is void). Then `start` again with `replace`, the base branch as working base, route
  `develop-pr` and `reviewMoment` `pr-boundary`. The new run's branch step answers `EXISTS` on it
  and its build step finds the story already built (`ultracode-build`, "Already built"), so the
  risk check, the local checks and the pull-request review run on the moved branch.
- **Any other stop, or a question left unanswered: the run waits for this session.** Keep the
  lease (`checkout-pool-commands.md`: a STOP this session will resume keeps it), say in one line
  what is still held (the lease, the story branch, the open run and its step) and how to go on
  (`/devstride:build-item <item>` resumes it), and end the turn. Never `return-checkout` here.

## Cited by

- `skills/build-item/SKILL.md` — The run, its `stopped` answer ("read … in full before acting on
  it").
- `skills/build-item/references/checkout-pool-commands.md` — the stops that keep the lease.
