---
name: merge-story
description: "Land a reviewed change onto its working base, never onto production."
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/step-skills.md` first: the rule every step skill follows.

Arguments: $ARGUMENTS — one JSON object, the `merge@1` payload
(`${CLAUDE_PLUGIN_ROOT}/schemas/step-contracts.json`): `item`, `profile`, `workingBase`, `route`,
`branch` (the story branch), the results of the review (`review`), the build (`build`), the risk
check (`riskCheck`) and the local checks (`localChecks`), the review's proof (`reviewProof`), and
`commit`: the full commit the local checks and the review were just proven on. **Read `${CLAUDE_PLUGIN_ROOT}/skills/merge-story/references/merge-paths.md` in full before the
first git command**: the order, both merge paths and every refusal are spelled there.

## Verdict

`MERGE: LANDED [<target>] | REFRESHED | HELD [<reason>] | BLOCKED [<reason>]`

## Steps

1. **Already landed?** `commit` on `origin/<workingBase>` (fast) or its pull request merged at that
   head → `LANDED` with the merge found; nothing merges twice.
2. **Holds**, on a landing onto the train or the base branch only (an epic-branch story
   accumulates under a hold): a release hold on the item or an ancestor → `HELD <reason>`; the
   story branch waits.
3. **Never production**: a working base equal to `release.productionBranch` → `BLOCKED`.
4. **Exactly this commit**: the branch no longer at `commit`, or the base moved and was merged in
   (fast) or rebased onto (pull request) → `REFRESHED`, so the runner re-earns what went stale and
   asks again.
5. **The path is the review's**: its `path` `fast-local` → the fast merge, `pull-request` → the
   pull-request merge, each exactly as the reference spells it, the consequence notices last
   before it.
6. On the pull-request path a red check or an open thread goes back through `review`, never merged
   red; the durable review proof follows the head (carried when the tree is the reviewed one,
   else re-earned through `review`); anything the reference stops on → `BLOCKED`, said, with the
   checkout restored to the story branch first.
7. **Landed is landed**: once the push or the pull-request merge succeeded, answer `LANDED`, naming
   any clean-up left undone; never `BLOCKED`.

## Result

After the verdict and its evidence, one fenced `json` block: `target` (the branch it landed on),
`sha` (the merge commit), `pullRequest` (its number, or null), `deletedBranch`, `links` (the https
addresses of the `commit` and the `pullRequest` when there is one) and `proof`: `head`, which must
be `commit`. A landing that names another commit stops the run.

**Step rules.** This step only; verdict first; safe to re-run (a landed commit is reported, never
merged again); config wins; it starts no subagent beyond `review` and never decides what runs next.
