---
load: contract
---
# Release branches and the support train — the procedures `release` runs

**Goal:** a production release cut as its own protected branch from `release.releaseSource`, so
the source keeps receiving merges while the release is reviewed, and — when configured — the
support train's one-offs merged into the source first so they ship with it.

Every key here is optional. `release.releaseBranchPattern` absent → no release branch: the release
pull request's head is `release.releaseSource`, as before, and sections 2–6 do not run.
`release.mergeTrainBeforeCut` absent or `false`, or `supportTrain.branch` absent → section 1 does
not run. Names are tested with the anchored rule in
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/branch-patterns.md`, never a substring.

## 1. Merge the support train (step 0b)

Runs only when ALL hold: `release.mergeTrainBeforeCut` is `true`; `supportTrain.branch` exists on
origin; `git rev-list --count origin/<releaseSource>..origin/<train>` is above zero. Otherwise a
no-op, reported in one line ("support train: nothing to ship", or "not configured").

1. Record `<sourceBefore>` — the `origin/<releaseSource>` SHA now.
2. An open pull request `<train> → <releaseSource>` is ADOPTED. Otherwise open one through the same
   draft hold `pr` uses: `gh pr create --draft --base <releaseSource> --head <train>`, title
   `Support train: <n> one-off(s) for release <date>`, body per `prBodyTemplate` listing each
   one-off, ending `<!-- devstride:loop -->`. No pull-request CI → non-draft, said.
3. Invoke **`review` DRIVEN** on it exactly as `build-item` step 8 hands over an epic release pull
   request: the FULL diff (a one-off merged fast onto the train had no full review yet — this is its
   first and only full review before production), every configured local engine, each in-scope
   cloud reviewer under its own scope and `requestPolicy`, fixes committed on the train, the
   ready-flip releasing CI once.
4. **A conflict with `releaseSource` STOPS** with the conflicting files — never auto-resolved. A
   verified P1 or serious P2 that is not fixed STOPS the release.
5. Merge with `gh pr merge <n> --merge` — never `--delete-branch` (the train is long-lived) and
   **never a direct push to `releaseSource`**: its own required checks run on that pull request.
6. **Close every one-off it carried.** Candidates are the item numbers in the subjects of
   `git log --first-parent --merges --format=%s <sourceBefore>..origin/<train>`, matched with the
   word-bounded expression `\bI[0-9]+\b` (the branch name in a pull-request merge subject, or the
   item number that leads a fast merge's subject). **Each is LOOKED UP with `get_item` before any
   write**; keep only a `hierarchyRoles.leaf` type that is not Done, and report every skipped
   candidate ("not marked Done: <subject>") — never guess. For each kept item: `update_item` →
   Done with `dueDate` today, then `add_comment` "reached <releaseSource> with release <name>
   (support train pull request #<n>)". Nothing was recorded on the items beforehand; the git
   history is the record.

## 2. Cut the release branch (step 0c)

- **Name** — the pattern with its date token set to today (`<YY-MM-DD>` → `26-10-02`). If that
  name exists on origin (`git ls-remote --exit-code --heads origin <name>`), add `-2`, then `-3`,
  until free.
- **One release at a time.** An open pull request into `productionBranch` whose head matches the
  pattern is ADOPTED by step 0 instead of cutting; a second one open at once is a STOP that names
  both.
- `git switch -c <name> origin/<releaseSource> && git push -u origin <name>`. `<sourceHead>` is that
  SHA; on an adopted branch derive it as `git merge-base origin/<name> origin/<releaseSource>`.

## 3. The branch is protected — fix commits only

- **Only new commits.** Never rebase, amend or force-push it, and never `--delete-branch` the pull
  request it heads. Develop-side merges never reach it: they ship in the NEXT release.
- **Fix-exclusion check before EVERY commit** made on it (review fixes, pre-ship fixes): list the
  staged files (`git diff --name-only --cached`). Any match for an entry of
  `release.releaseBranchFixExclusions` (absent → nothing is refused) → **REFUSE**: commit nothing,
  name the matching files, and tell the operator in plain words: "this fix touches deploy
  configuration or database migrations; merge it to <releaseSource> through a normal pull request
  (or the support train), then abandon this release branch and re-cut."
- **The same check at adoption**, over every file changed by
  `git log --first-parent --no-merges --name-only --format= <sourceHead>..origin/<name>` — a commit
  pushed by hand is caught on a resumed run.
- **Abandon and re-cut**: `gh pr close <n> --comment "<reason>; abandoned for a re-cut"`; leave the
  branch for the owner to delete (never delete it unasked); re-run `/devstride:release`, which cuts
  the next `-n`.

## 4. A hotfix lands while the release is open

`git fetch origin <productionBranch>`; when `origin/<productionBranch>` is not an ancestor of
`origin/<name>`: `git switch <name> && git merge --no-ff origin/<productionBranch>` (a conflict
STOPS with the files), push, then re-enter `review` on the new head — a head advance is a full gated
pass over what the merge brought in and how it was resolved. Never rebase. `review` hands back here
when its step 7.1 finds the production branch advanced under a release-branch head.

## 5. Close out (step 6)

1. **Sync production into the source.** Without it the release branch's fix commits never reach
   `releaseSource`. Already `git merge-base --is-ancestor origin/<productionBranch>
   origin/<releaseSource>` → nothing to do. Otherwise branch per `branchNaming` (slug
   `sync-<productionBranch>-into-<releaseSource>`) from `origin/<releaseSource>`, `git merge --no-ff
   origin/<productionBranch>` (a conflict STOPS with the files), push, and invoke **`pr` driven**
   with a scope manifest naming only the merge's conflict resolutions — none when the merge was
   clean, since every other line was reviewed on the release pull request. It settles CI; merge it
   `--merge --delete-branch` (the sync branch is disposable).
2. **Delete the release branch — the one place the loop deletes a protected branch, and it says
   so.** Only when the name matches the pattern AND it is an ancestor of both
   `origin/<productionBranch>` and `origin/<releaseSource>` (`git merge-base --is-ancestor`):
   `git push origin --delete <name>`, then `git branch -D <name>`. Either check failing → keep it
   and report why. Never delete `releaseSource` or `productionBranch`.
3. **Fast-forward the support train** when `supportTrain.branch` is set and
   `git merge-base --is-ancestor origin/<train> origin/<releaseSource>`:
   `git push origin origin/<releaseSource>:refs/heads/<train>` — a fast-forward, never `--force`.
   A train still carrying unreleased one-offs is left alone; report how many commits it carries.

## Cited by

- `skills/release/SKILL.md` — steps 0b, 0c, the protected-branch floor, the hotfix rule and step 6.
- `skills/review/SKILL.md` — step 7.1's hand-back on a release-branch head.
