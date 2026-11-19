---
load: contract
---
# Run stops — what the loop does when the Build run stops

`build-item`'s answer to a `stopped` run, beyond a question (`needs-person`) and a red local check,
which its The run section handles itself. Read in full before acting on any other stop.

- **A merge stop**: a `stopped` answer carrying `mayHaveLanded` (from `done`, or from `resume`,
  which answers with that stop until told otherwise). Check the stop's `commit` with the landing
  test (`${CLAUDE_PLUGIN_ROOT}/skills/merge-story/references/merge-paths.md`, "Already landed"),
  which has three answers. Exactly it → report it with `done` on the stopped merge (its `attempt`),
  its result naming the merge and its proof's `head` that commit; never `resume`, which would read
  the moved checkout as new work. Landed, but the check cannot prove how → stop for a person,
  saying exactly that: "it landed, but this check cannot prove how" (never that it went unchecked:
  after a release fast-forward it was checked and reviewed). The run waits, lease kept. The person
  confirms what landed, then either reports the merge with `done` on the stopped attempt, its
  proof's `head` the handed commit (completion then runs), or ends the run with `resume` and
  `"close": true`. Nothing landed → put the checkout back on the story branch, then `resume` with
  `"landed": false`: at once for a push refused in a race (the merge step tries again), otherwise
  once its cause is fixed. Step 0 of `SKILL.md` applies the same three answers to a run it resumes
  while its merge row is `issued` or stopped; a merge row `done` is carried on, never checked
  again.
- **A merge `BLOCKED` on excluded paths** (a train one-off carrying deploy configuration or a
  migration): never on a protected or merge-only head (`protectedBranches`, an epic or plan
  integration branch, the train:
  `${CLAUDE_PLUGIN_ROOT}/skills/release/references/branch-patterns.md`, "Protected and merge-only
  heads") → a person. Move the story branch by name off the train and push that one ref with an
  explicit lease, in ONE shell call, because the lease reads a value that same call records:
  `git fetch origin && pushed=$(git rev-parse --verify --quiet refs/remotes/origin/<branch>) && git
  rebase --onto origin/<baseBranch> origin/<train> <branch> && git push
  --force-with-lease=refs/heads/<branch>:$pushed origin refs/heads/<branch>:refs/heads/<branch>`.
  A branch never pushed (that `rev-parse` prints nothing, so the call stops before the rebase) →
  `git rebase --onto origin/<baseBranch> origin/<train> <branch> && git push origin
  refs/heads/<branch>:refs/heads/<branch>`: a plain first push, no lease. Either way its receipt
  is void. Then `start` again with `replace`, the base branch as working base, route
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
- `skills/build-item/SKILL.md` — step 0, an unfinished run's three cases.
- `skills/build-item/references/checkout-pool-commands.md` — the stops that keep the lease.
