---
load: contract
---
# Merge paths — landing exactly the reviewed and checked commit

`merge-story`'s procedure. The payload's `commit` is the commit the runner found the local checks'
tree and the review's patch to hold for when it issued this step; whatever merges is exactly that
commit, and the proof's `head` names it. The payload also carries what this procedure reads after a
compaction: `reviewProof` (the review's proof: the `head` it settled on, its `base`, its `path` and
`pullRequest`) and `localChecks` (the local checks' result: the `commands` run and their `results`,
and the `receipt` for this tree).

## Before any merge, on either path

1. **Already landed** (a re-run after an interruption) has three answers: exactly `commit` landed;
   it landed, but this check cannot prove how; or nothing landed. Fast path, after `git fetch
   origin`: (a) `git rev-list --first-parent --parents origin/<workingBase> | awk -v c=<commit> 'NF
   == 3 && $3 == c { print $1; exit }'` prints a two-parent merge on the base's own first-parent
   line whose second parent is `commit` → `LANDED` with it; (b) else `git rev-parse
   origin/<workingBase>` printing `commit` itself → `LANDED` with `commit`; (c) else `git
   merge-base --is-ancestor <commit> origin/<workingBase>` succeeding → it landed some other way (a
   later commit on top of it, a merge off the first-parent line or with more parents, a release
   that fast-forwarded the base), and topology cannot tell a release from unchecked work:
   `BLOCKED landed, but this check cannot prove how: <commit>`, for a person, who reads
   everything the base gained past it, merges included, `git log --oneline
   <commit>..origin/<workingBase>`, for any later commit of this story and any merge commit made
   on the story's branch (a base merge into the story can carry changes). A hint, not decisive:
   a commit of `git rev-list <commit>..<story-ref>` (`<story-ref>`: `origin/<branch>` where it
   exists, else the local `<branch>`) that `git merge-base --is-ancestor <that>
   origin/<workingBase>` finds on the base is one to look at; an upstream commit the story branch
   merely contains (a rebase, a base merge) is not story work. Neither among it (a release or
   other checked landings) → `done` naming `commit`; either among it → not `done`: the run is closed and the person
   told that work landed without this run's checks and review; unsure → the stop stays. Never
   call `commit` itself unchecked or unreviewed: after a release it was both. Pull-request path: `gh pr view <n>
   --json state,headRefOid,mergeCommit` merged with `headRefOid` = `commit` → `LANDED` with its
   merge commit; merged with another head → (c). Anything else: nothing landed, go on.
2. **Release holds first**, before any merge onto the train or `baseBranch` (one-off or plan
   story; a story merging onto an epic's integration branch is not held: it accumulates there, and
   the hold applies at the epic's release): a hold on the item or an ancestor
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
  "origin/<train>", "head": "<commit>"}` must answer `small`, `reviewed` (here, or carried forward
  under an unchanged patch) or `not-applicable`. Exit 2
  → invoke `review` in LOCAL-FULL mode for its follow-up on this head
  (`${CLAUDE_PLUGIN_ROOT}/skills/review/references/local-full.md`, "A later change to the patch"),
  which records the review, then check again; a follow-up that changed the head answers
  `REFRESHED`. Never merge on a non-zero exit.
- `git checkout <workingBase> && git pull --ff-only`, then `git rev-list --count
  origin/<workingBase>..<workingBase>` must print `0`: a local base ahead of its remote →
  `MERGE: BLOCKED local <workingBase> is ahead of origin`, nothing merged. Record the tip: `git rev-parse
  HEAD` prints it, written into the undo below as `<tip>` (a shell variable does not outlive its
  call), then merge the story `--no-ff <commit>` per
  `commitConventions.epicMergeFormat` (fallback
  `merge: <itemNumber> [<N>] <short scope> into <epic-slug> integration`). On the train the subject
  is `merge: <itemNumber> <short scope> into <train>`: the item number always leads, whatever
  `epicMergeFormat` says, because `release` reads it later. The BODY carries the review's
  `mergeBody` (each dismissed finding from the risk check and the review, with its rationale, and
  the landing gate's lines) and the commands and counts of the verification receipt for this tree.
- `git push origin <workingBase>`. **Only once that push SUCCEEDS** delete the story branch locally
  AND remotely. A refused push → undo exactly this merge, never reset to the remote: when `git
  rev-parse HEAD^1 HEAD^2` prints `<tip>` and `commit` (HEAD is the merge just made), `git reset
  --hard <tip>`; then `git checkout <branch>`; then `MERGE: BLOCKED push refused: <first line>`,
  nothing deleted. Never leave HEAD on the local merge commit: the runner would read it as a new
  commit.

## Pull-request merge (review path `pull-request`)

- **The rebase already happened** in `review` step 7; rebase again only if the base moved, via
  `/devstride:push` (conflict → `BLOCKED`, a fork for a person). A rebase makes a new head: answer
  `MERGE: REFRESHED`. Compare patches: the runner does, on the review's proof — a changed patch
  sends the story back through the review with its ledger; an identical patch keeps the review, and
  the local checks rerun on the new tree.
- **The durable proof follows the head.** `commit` is not the reviewed head (a rebase whose
  patch held) → compare their trees (`git rev-parse <commit>^{tree} <reviewProof.head>^{tree}`):
  - **the same tree** → carry the proof: `python3
    ${CLAUDE_PLUGIN_ROOT}/skills/review/scripts/reviewed-status.py post <commit> --from
    <reviewProof.head> --pr <n> --base <workingBase>` (the bare branch: the script refuses a ref);
  - **another tree** (the base moved under an unchanged patch) → `--from` refuses unequal trees, so
    nothing is carried: invoke `review` driven in PRE-SHIP RESUME mode on the pull request. It
    starts at its step 7.1, finds the head current, skips the flip of a pull request already ready
    and settles CI at this head, posting the proof on READY (`review-ledger.md`). The patch is
    unchanged, so it raises nothing new. A settle that changed the head → `REFRESHED`.
  `NOT POSTED` on either is the degradation `review-ledger.md` names (said; the merge goes on).
  Then RECOMPUTE `verify.skipDuringStoryBuilds` applicability from the new SHA.
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

## Landed means landed

Once the fast merge's push or the pull request's merge has SUCCEEDED, the answer is `MERGE: LANDED
<target>`, whatever fails after it: a refused remote branch delete, a local clean-up, a link that
could not be read. Name what was left undone in the verdict's evidence (`left: the remote story
branch`), for a person to finish; never `BLOCKED`. A `BLOCKED` after the change landed would stop a
run whose merge cannot be asked again: the checks and the review would be issued for a checkout
that has moved on. Only a merge that did not land answers `BLOCKED`.

## Cited by

- `skills/merge-story/SKILL.md` — the pointer before the first git command ("Read … in full before
  the first git command").
