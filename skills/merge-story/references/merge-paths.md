---
load: contract
---
# Merge paths — landing exactly the reviewed and checked commit

`merge-story`'s procedure. The payload's `commit` is the commit the runner found the local checks'
tree and the review's patch to hold for when it issued this step; whatever merges is exactly that
commit, and the proof's `head` names it.

## Before any merge, on either path

1. **Already landed** (a re-run after an interruption): fast path, `git fetch origin` and `git
   merge-base --is-ancestor <commit> origin/<workingBase>` → find the merge commit that brought it
   (`git log --merges --first-parent --format=%H -n 1 --ancestry-path <commit>..origin/<workingBase>`)
   and answer `LANDED`; pull-request path, `gh pr view <n> --json state,headRefOid,mergeCommit`
   merged with `headRefOid` = `commit` → `LANDED` with its merge commit. Another head merged →
   `BLOCKED`, naming it.
2. **Release holds first**, before any merge onto the train or `baseBranch` (one-off or plan
   story): a hold on the item or an ancestor
   (`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/release-holds.md`) → no merge; the story
   branch waits, said: `MERGE: HELD <reason>`. The item stays in progress and the run ends held.
3. **Never production.** A working base equal to `release.productionBranch` → `MERGE: BLOCKED`:
   production merges are the owner's, through `/devstride:release`.
4. **Exactly this commit.** `git rev-parse HEAD` on the story branch is not `commit` → the branch
   moved on after its checks: `MERGE: REFRESHED`, nothing merged.
5. **Deploy configuration and migrations never ride the train** (`route` `train`): check the real
   diff again (`git diff --name-only --no-renames origin/<train>...<commit>` into `routing.py
   excluded`). A match → `MERGE: BLOCKED excluded paths: <paths>`: the one-off ships to `baseBranch`
   by its own pull request, which the loop starts (`skills/build-item/SKILL.md`, The run).
6. **Consequence notices** just before the merge command, on the head that merges, every profile,
   never a gate: `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/consequence-notices.md`.

## Fast merge (review path `fast-local`)

- Clean tree, every review fix committed.
- **Base moved** (`origin/<workingBase>` not an ancestor of `commit` after `git fetch origin`) →
  merge the refreshed base INTO the story, push the story branch, and answer `MERGE: REFRESHED`:
  the runner re-runs the local checks on the new tree (and the review when the patch changed), then
  asks again. A conflict that cannot be resolved → `MERGE: BLOCKED` for a person.
- **The landing gate** (release train): in the story's checkout, before switching branches,
  `python3 ${CLAUDE_PLUGIN_ROOT}/skills/build-item/scripts/review-gate.py check` with `{"base":
  "origin/<train>", "head": "<commit>"}` must answer `small`, `reviewed` or `not-applicable`. Exit 2
  → invoke `review` in LOCAL-FULL mode for its follow-up on this head
  (`${CLAUDE_PLUGIN_ROOT}/skills/review/references/local-full.md`, "A later change to the patch"),
  which records the review, then check again; a follow-up that changed the head answers
  `REFRESHED`. A moved train merged into the story is a new head: check again. Never merge on a
  non-zero exit.
- `git checkout <workingBase> && git pull --ff-only`; merge the story `--no-ff <commit>` per
  `commitConventions.epicMergeFormat` (fallback
  `merge: <itemNumber> [<N>] <short scope> into <epic-slug> integration`). On the train the subject
  is `merge: <itemNumber> <short scope> into <train>`: the item number always leads, whatever
  `epicMergeFormat` says, because `release` reads it later. The BODY carries the review's
  `mergeBody` (each dismissed finding from the risk check and the review, with its rationale, and
  the landing gate's lines) and the commands and counts of the verification receipt for this tree.
- Push. **Only once that push SUCCEEDS** delete the story branch locally AND remotely. A refused
  push → `MERGE: BLOCKED`, nothing deleted.

## Pull-request merge (review path `pull-request`)

- **The rebase already happened** in `review` step 7; rebase again only if the base moved, via
  `/devstride:push` (conflict → `BLOCKED`, a fork for a person). A rebase makes a new head: answer
  `MERGE: REFRESHED`. Compare patches: the runner does, on the review's proof — a changed patch
  sends the story back through the review with its ledger; a tree-identical head keeps its receipt.
- **Carry the proof** when `commit` is not the `head` of the review's proof (a rebase whose patch held):
  `python3 ${CLAUDE_PLUGIN_ROOT}/skills/review/scripts/reviewed-status.py post <new head> --from
  <reviewed head> --pr <n> --base <ledger's Base branch>`. Then RECOMPUTE
  `verify.skipDuringStoryBuilds` applicability from the new SHA.
- **Observe greenness**: non-draft, every applicable check succeeded — actually RAN — at the
  CURRENT head SHA. Re-poll only after a re-push, with `review` step 7's background poll; never
  `gh pr checks --watch`.
- **Red CI** → `review` step 7's ladder (failed to trigger, flaky, real). Never merge red; never
  quit after one failure. A fix it pushes is a new head: `REFRESHED`.
- Slow suites (`verify.skipDuringStoryBuilds`): story PRs into an epic branch never wait on them; on
  develop each follows its applicability; an empty list settles an absent check. **Read the config
  before concluding either.**
- **Zero unresolved threads immediately before merging** (`review`'s paginated query); else back
  through `review` steps 3–6.
- Run the `MERGE` line of `python3 ${CLAUDE_PLUGIN_ROOT}/skills/pr/scripts/merge-gate.py <n> <head>
  --delete-branch` (`<head>` is `commit`: the review's final reviewed head, or its tree-identical
  rebase; never the live one; the line carries `--match-head-commit`)
  (integration-branch or train base: add `--subject "Merge pull request #<n> from <owner>/<head branch>"`); `REFUSE` or `ERROR`
  → `BLOCKED` with its reason — **never `--delete-branch` on a head matching `protectedBranches`**
  (anchored: `${CLAUDE_PLUGIN_ROOT}/skills/release/references/branch-patterns.md`).

## Cited by

- `skills/merge-story/SKILL.md` — the pointer before the first git command ("Read … in full before
  the first git command").
