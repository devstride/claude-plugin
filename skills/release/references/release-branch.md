---
load: contract
---
# Release branches and the support train — the procedures `release` runs

**Goal:** a production release cut as its own protected branch from `release.releaseSource`, so
the source keeps receiving merges while the release is reviewed, and — when configured — the
support train's one-offs merged into the source first so they ship with it.

Every key here is optional. `release.releaseBranchPattern` absent → no release branch: the release
pull request's head is `release.releaseSource`, as before, and sections 2–4 and 5.1–5.2 do not run.
§5.3 runs whenever `supportTrain.branch` is set. `release.mergeTrainBeforeCut` absent or `false`, or
`supportTrain.branch` absent → section 1 does not run. Names are tested with the anchored rule in
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/branch-patterns.md`, never a substring.

## 1. Merge the support train (step 0b)

Runs only when ALL hold: `release.mergeTrainBeforeCut` is `true`; step 0 adopted no open release
pull request headed by a release BRANCH (one cut earlier, so the train would not ship with it);
`supportTrain.branch` exists on origin; and, after `git fetch origin <releaseSource> <train>`, `git
rev-list --count origin/<releaseSource>..origin/<train>` is above zero. Otherwise a no-op, reported
in one line ("support train: nothing to ship", "not configured", or "skipped — adopted release"). On
"nothing to ship", still finish an interrupted run: for the most recently merged pull request from
the train (`gh pr list --head <train> --base <releaseSource> --state merged --limit 1`), apply step
5 below to that pull request's OWN range only — `<merge>^1..<merge>^2` in place of
`<sourceBefore>..origin/<train>`, since the train has since been fast-forwarded to the source and a
wider range would close unrelated items (it skips items already Done).

1. Record `<sourceBefore>` — the `origin/<releaseSource>` SHA now.
2. Open it through **`pr` in driven mode** — head `<train>`, base `<releaseSource>`, title `Support
   train: <n> one-off(s) for release <date>`, the body listing each one-off — flagged as a
   release-unit pull request exactly as `build-item` step 8 flags an epic release, so `review` takes
   the FULL diff (a one-off merged fast onto the train had no full review yet — this is its first
   and only full review before production). `pr` owns the draft hold, the pre-ship checks its step 2
   selects (the one-offs' `perPr` suites run here or nowhere) and the ready-flip that releases CI
   once; fixes are committed on the train, each passing §3's fix-exclusion check first (a migration
   or deploy-configuration fix leaves the train: merge it to the source by its own pull request). An
   open pull request `<train> → <releaseSource>` is ADOPTED: hand it to `review` with the same
   pre-ship selection and hold.
3. **A conflict with `releaseSource` STOPS** with the conflicting files — never auto-resolved. A
   verified P1 or serious P2 that is not fixed STOPS the release.
4. Merge with `gh pr merge <n> --merge --match-head-commit <reviewedHead>` (the head `review`
   settled; a one-off merged onto the train meanwhile advances it → back to `review`, never merged
   unreviewed) — never `--delete-branch` (the train is long-lived) and **never a direct push to
   `releaseSource`**: its own required checks run on that pull request.
5. **Close every one-off it carried.** Candidates are the item numbers in the subjects of `git log
   --first-parent --merges --format=%s <sourceBefore>..origin/<train>`, matched with the
   word-bounded expression `\bI[0-9]+\b` (the branch name in a pull-request merge subject, or the
   item number that leads a fast merge's subject). **Each is LOOKED UP with `get_item` before any
   write**; keep only a `hierarchyRoles.leaf` type that is not Done, and report every skipped
   candidate, and every merge subject with no item number, as "not marked Done: <subject>" — never
   guess. For each kept item: `update_item` → Done with `dueDate` today, then `add_comment` "reached
   <releaseSource> with release <name> (support train pull request #<n>)". Nothing was recorded on
   the items beforehand; the git history is the record.

## 2. Cut the release branch (step 0c)

- **Name** — the pattern with its date token set to today (`<YY-MM-DD>` → `26-10-02`). If that
  name exists on origin (`git ls-remote --exit-code --heads origin <name>`) and the pattern ends in
  `[-n]`, add `-2`, then `-3`, until free; without `[-n]` a taken name STOPS (a suffixed name would
  not match the pattern, so it would be neither adopted nor protected). Check every generated name
  against the pattern before pushing it.
- **One release at a time.** An open pull request into `productionBranch` whose head matches the
  pattern is ADOPTED by step 0 instead of cutting; a second one open at once — or one still headed
  by `releaseSource` from before the pattern was set — is a STOP that names both.
- `git switch -c <name> <sourceHead> && git push -u origin <name>` — the SHA the delta was computed
  from, never a re-read `origin/<releaseSource>` that another session's fetch may have moved. It is
  recorded in the release pull request's marker `<!-- devstride:release-branch <name> cut <sha>
  -->`; on an adopted branch read it back from that marker (only with no marker, fall back to `git
  merge-base origin/<name> origin/<releaseSource>` and say so).

## 3. The branch is protected — fix commits only

- **Only new commits.** Never rebase, amend or force-push it, and never `--delete-branch` the pull
  request it heads. Develop-side merges never reach it: they ship in the NEXT release.
- **Fix-exclusion check before EVERY commit** made on it (review fixes, pre-ship fixes; §4's merge
  of the production branch is exempt — a hotfix is already in production): list the staged files
  (`git diff --name-only --cached`). Any match for an entry of `release.releaseBranchFixExclusions`
  (absent → nothing is refused) → **REFUSE**: commit nothing, name the matching files, and tell the
  operator in plain words: "this fix touches deploy configuration or database migrations; merge it
  to <releaseSource> through a normal pull request then abandon this release branch and re-cut."
- **The same check at adoption**, over every file changed by
  `git log --first-parent --no-merges --name-only --format= <sourceHead>..origin/<name>`, plus, for
  each merge commit on that first-parent line that is not a merge of `productionBranch` (§4), the
  files it changed against its first parent (`git diff --name-only <merge>^1 <merge>`) — a commit
  pushed or merged in by hand is caught on a resumed run.
- **Abandon and re-cut**: `gh pr close <n> --comment "<reason>; abandoned for a re-cut"`; leave the
  branch for the owner to delete (never delete it unasked); re-run `/devstride:release`, which cuts
  the next `-n`.

## 4. A hotfix lands while the release is open

`git fetch origin <productionBranch>`; when `origin/<productionBranch>` is not an ancestor of
`origin/<name>`: `git switch <name> && git merge --no-ff origin/<productionBranch>` (a conflict
STOPS with the files), push — on a non-draft pull request run `gh pr ready --undo` BEFORE the push,
so CI never runs on an unreviewed head — then re-enter `review` driven as a contextual follow-up
over the merge's range (its step 5 rule), carrying the ledger, counters and the same pre-ship hold
declaration; never a fresh cycle 1. A merge that leaves the tree unchanged (history only, e.g.
production's own earlier release merge) needs no re-review: say so and set `<reviewedHead>` to the
new same-tree head. Any return to step 2 voids an owner yes already given; step 4 asks again. Never
rebase. `review` hands back here when its step 7.1 finds the production branch advanced under a
release-branch head.

## 5. Close out (step 6)

1. **Sync production into the source.** Without it the release branch's fix commits never reach
   `releaseSource`. Already `git merge-base --is-ancestor origin/<productionBranch>
   origin/<releaseSource>` → nothing to do. Otherwise branch per `branchNaming` (slug
   `sync-<productionBranch>-into-<releaseSource>`) from `origin/<releaseSource>`, `git merge --no-ff
   origin/<productionBranch>` (a conflict STOPS with the files), push, and invoke **`pr` driven**
   with base `<releaseSource>` passed explicitly, declaring `merge-only: true` (its merge commit is
   the point — never rebased), with a scope manifest naming only the merge's conflict resolutions —
   none when the merge was clean, since every other line was reviewed on the release pull request.
   It settles CI; merge it `--merge --delete-branch` (the sync branch is disposable). Then `git
   fetch origin <productionBranch> <releaseSource> <train>` so 2 and 3 read the merged state.
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
