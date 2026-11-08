---
load: contract
---
# Release branches and the release train — the procedures `release` runs

**Goal:** a production release cut as its own protected branch from `release.releaseSource`, so
the source keeps receiving merges while the release is reviewed, and — when configured — the
release train's one-offs merged into the source first so they ship with it.

A reviewed release unit (an epic's pull request merged onto the train through its own review) may
carry migrations and infrastructure on the train; the exclusion check below covers only work no
pull request reviewed, and `release.devDeployVerification` makes the release wait for the
development deploy (SKILL step 4), given `RELEASE_COMMIT` = the head the release pull request merges from the source (`<sourceHead>`, the cut, with a release branch; `<reviewedHead>` without one).

`releaseTrain` below means `releaseTrain`, or `supportTrain` when only that is present; both present
is a config error — STOP and name it.

Every key here is optional. `release.releaseBranchPattern` absent → no release branch: the release
pull request's head is `release.releaseSource`, as before, and sections 2–4 and 5.1–5.2 do not run.
§5.3 runs whenever `releaseTrain.branch` is set. `release.mergeTrainBeforeCut` absent or `false`, or
`releaseTrain.branch` absent → section 1 does not run. Names are tested with the anchored rule in
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/branch-patterns.md`, never a substring.

## 1. Merge the release train (step 0b)

Runs only when `release.mergeTrainBeforeCut` is `true`, `releaseTrain.branch` exists on origin (absent
while another `train/*` branch is there → STOP and name the cutover, `routing.py`'s rule: one-offs
ride that branch until it is renamed; never release around it), and
step 0 adopted no open release pull request headed by a release BRANCH (one cut earlier, so the
train would not ship with it). Otherwise a no-op, reported in one line ("release train: not
configured", or "skipped — adopted release").

The live train keeps receiving one-offs from other sessions while this runs, so the release never
reviews or merges the live branch: it reviews a SNAPSHOT that only this run writes to. Every
release-train pull request records its range in a body marker,
`<!-- devstride:release-train source <sourceBefore> snapshot <trainSnapshot> -->`; that marker,
never the live train, is what closes items later. A pull request from before the rename carries
`<!-- devstride:support-train source … snapshot … -->` with the same fields and is read the same way.

**The exclusion check (`train_exclusions.py`).** Migrations and deploy configuration
(`release.releaseBranchFixExclusions`) may ride the train only inside a REVIEWED release unit. The
check is `python3 ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/train_exclusions.py --config
.claude/ds-config.json --source-before <from> --head <to>` (its header documents the rules): over
each first-parent commit in the range it leaves out merges of `releaseSource` and merges of a pull
request that `gh` confirms was merged onto the train as a release unit, and checks every other commit
(a fast-merged one-off, a direct commit, a snapshot fix). A plan's release pull request (plan scope)
is not exempt whole: its plan branch's epic pull requests are the reviewed units, the rest is checked. Exit 1 → STOP, naming each file in
`refused` and saying: "this touches deploy configuration or database migrations without a reviewed
pull request; merge it to <releaseSource> through a normal pull request, then re-run." Exit 2 → STOP
on the error. `allowedRenumbers` (only with `release.migrationRenumber` set) lists each migration
renumber the source merge forced; the snapshot pull request's body reports each as "migration
renumbered NNNN → MMMM (the source took NNNN)".

**Release holds.** Before the snapshot, and again on its final head before it merges (late
arrivals, an adopted snapshot), every item the range carries (each one-off's merge subject
and landed record) is checked with its ancestors by
`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/release-holds.md`'s helper. Held → STOP, naming
each: "<item> is held (<reason>) but already on the train: wait for the hold to lift, or remove its
`Release hold:` line; taking it off the train is the owner's call."

**Finding release-train pull requests — both spellings, permanently.** Run two queries, one per
title, because `gh pr list --search` has no reliable OR across quoted phrases: `gh pr list --base
<releaseSource> --state <state> --search 'in:title "Release train:" sort:created-desc' --json
number,title,body,mergedAt --limit 50` and the same with `"Support train:"`. Merge the results and
keep only titles starting `Release train:` OR `Support train:` whose body carries the complete
range marker, `devstride:release-train` OR `devstride:support-train` (the marker written before
the rename) followed by `source <sha> snapshot <sha>` — never a substring, which the holder marker
`devstride:release-train-holder` would also match — so an
interrupted run, or an open train pull request from before the update, is still finished or adopted;
for merged ones take the latest `mergedAt`. Never trust best-match ranking or a body match alone.

1. **Finish an interrupted earlier run first**, every time: for the latest merged release-train
   pull request, apply step 6 to its marker's range. Step 6 skips any item already Done or already
   carrying that pull request's "reached …" comment, so a finished run is a no-op and a re-opened
   item is never closed again.
2. **An open release-train pull request is ADOPTED** before anything is cut (scope `cut-to-deploy`:
   only when its holder marker is this session's or absent; another holder's → STOP and ask,
   `clearance.md`; with a `claims` block the won train claim decides which marker, `auto-start.md`): read `<sourceBefore>`
   and `<trainSnapshot>` from its marker (no marker → STOP and name it; never guess a range), skip
   steps 3–4, check out its head (`gh pr checkout <n>`, then confirm `HEAD` equals the pull
   request's `headRefOid`, so the local engine and pre-ship suites see that tree), and run `pr`
   steps 2–2c on it, driven — pre-ship selection, hold, `review` with the step-4 declarations,
   discharge — then run step 4b (unless this session holds `PRE-SHIP TRAIN: PASS` for that exact
   head), then continue at step 5.
3. `git fetch origin <releaseSource> <train>`. No one-off on the train beyond the source
   (`git log --no-merges --oneline origin/<releaseSource>..origin/<train>` is empty — merges of the
   source alone are not work) → report "release train: nothing to ship" and stop here. Otherwise
   record `<sourceBefore>` (the `origin/<releaseSource>` SHA) and `<trainSnapshot>` (the
   `origin/<train>` SHA), and **cut the snapshot**: a branch named per `branchNaming` (slug
   `release-train-<date>`, `-2` … when taken) at `<trainSnapshot>`, then
   `git merge --no-ff origin/<releaseSource>` into it so review and the pre-ship checks see the
   combined tree (a conflict STOPS with the files — never auto-resolved), then push. One-offs that
   land on the live train from now on ship in the next release.
4. **Open it through `pr` in driven mode** — base `<releaseSource>`, title `Release train: <n>
   one-off(s) for release <date>`, the body listing each one-off and carrying the range marker
   (scope `cut-to-deploy` or a `claims` block: and the holder marker) —
   flagged as a release-unit pull request exactly as `build-item` step 8 flags an epic release, so
   `review` takes the FULL diff (a one-off merged fast onto the train had no full review yet — this
   is its first and only full review before production; with `release.productionReview` set, a
   release unit that joined through its own reviewed pull request is excluded, `review-once.md`),
   and declaring `merge-only: true`,
   `fix-exclusions: true` and, when `releaseTrain.lateArrivals` is `"restart"`, `late-arrivals`. `pr` owns the draft hold, the pre-ship checks its step 2 selects and the
   ready-flip that releases CI once; the untracked-deferral list it returns (an adopted run's too)
   goes to `release` step 2, never spliced. Fixes are committed on the snapshot, each passing §3's
   staged-file check first (a migration or deploy-configuration fix leaves the train: merge it to
   the source by its own pull request); once cut (and again on an adopted pull request) run the
   exclusion check with `--source-before <sourceBefore> --head <snapshot head>` and put each
   `allowedRenumbers` entry in the body.
4a. **Late landings.** Each progress report runs `git fetch origin <releaseSource> <train>` and
   names any late one-offs in `git log --no-merges --oneline <trainSnapshot>..origin/<train>`. To
   ABSORB them: resolve `<absorbAt>` to a SHA (the commit named, else the fetched train tip, said
   back); `<trainSnapshot>` must be its ancestor (else STOP); run the exclusion check over the NEW
   train work only, `--start-on train --source-before <trainSnapshot> --head <absorbAt>` (source
   merges are not train work; exit 1 STOPS); `git merge --no-ff <absorbAt>` into the snapshot (a
   conflict STOPS) and push; rewrite the marker to `snapshot <absorbAt>`, the title's count and the
   body's list, and from then on read `<trainSnapshot>` as `<absorbAt>` for detection and step 6.
   When to absorb follows `releaseTrain.lateArrivals`:
   - **`"restart"`** — automatically, up to `review` step 7's ready-flip: a late arrival is meant to
     supersede what is there. `late-arrivals` is declared to `pr`, which passes it to `review` with
     `<train>` and `<trainSnapshot>`: before each cycle and before the flip, review fetches the
     train and on a late one-off STOPS, returning `LATE-ARRIVAL` with the pull request still a
     draft, any running engine stopped and its partial result dropped, the cumulative ledger and
     the lessons tally (no step 6.5 for the cancelled cycle); `pr` returns it to this step at once,
     running no pre-ship check. Absorb, then run `pr` steps 2–2c on it again (the pull request
     exists), driven, with step 4's declarations and scope and the carried ledger as caller evidence: a fresh cycle 1 over the
     full snapshot diff, the cycle target counted afresh (the one exception to never resetting it),
     the pre-ship hold re-decided for the new tree. At most THREE restarts per release: the third restart's
     run, and the first ready-flip, end the window — `late-arrivals` is no longer declared and later
     landings ship next time, said so — so CI runs once and a busy train cannot hold the release
     open.
   - **`"offer"`** (absent) — only on the owner's instruction, and only before `review` step 7's
     ready-flip; the absorbed range then gets one FULL-scope cycle of every configured engine
     with the ledger, outside the cycle budget (a required engine that cannot run STOPS). Later
     landings ship next time, said so; after the flip the offer closes (a push would restart CI).
4b. **Train-run pre-ship checks** (a new and an adopted train pull request both run this before
   step 5). Once `pr` has settled the pull request's review and its CI is running, run
   **`pre-ship train run`** at the snapshot head: every `preShipChecks` entry with `when:
   "releaseOnly"` and `runAt: "train"`, in the background, printing `pre-ship`'s evidence lines
   plus, on all passing, `PRE-SHIP TRAIN: PASS <names> at <sha>` (`NOTHING TO RUN` is an explicit
   no-op, said so). Step 2b gets `--ran-at-train <names>@<sha>` from that line; it is the only
   automatic 2b skip for such an entry. **A red result STOPS the train merge.** The fix path: the
   owner may instead waive it in words; otherwise commit the fix on the snapshot, convert the pull
   request to draft, re-enter `pr` steps 2–2c at the new head, in their order (`pre-ship pr select` declares
   the hold, `review`'s step 5 follow-up with the cumulative ledger settles to 7.1b, every
   selected check runs on that final head, then PRE-SHIP RESUME flips it ready and settles CI),
   and rerun this step at that head; step 5's `<reviewedHead>` pin is that new head. Under scope `release` the clearance is
   already held (step 0a); under `cut-to-deploy` it is not claimed until the cut. With no train
   pull request, no passing line or a different tree, step 2b runs these entries itself.
5. **Merge** — first `git fetch origin <releaseSource>` and run the exclusion check with
   `--source-before <sourceBefore> --head <reviewedHead>` (source merges are not train work, and a
   reviewed release unit is allowed; exit 1 STOPS); then run the `MERGE` line of
   `python3 ${CLAUDE_PLUGIN_ROOT}/skills/pr/scripts/merge-gate.py <n> <reviewedHead> --delete-branch`
   (the snapshot is disposable); `REFUSE` or `ERROR` STOPS. **Never a direct push to `releaseSource`**: its
   own required checks run on the pull request. A verified P1 or serious P2 that is not fixed STOPS
   the release.
6. **Close every one-off it carried.** Candidates come from the subjects of `git log --first-parent
   --merges --format=%s <sourceBefore>..<trainSnapshot>` — the marker's range, never the live train
   — and ONLY the number that identifies each merge: the item number leading a fast merge's subject
   (`^merge: (I[0-9]+)\b`), or the one starting the branch name in a pull-request merge subject
   (`from [^ ]+/(I[0-9]+)-`). Any other number a subject cites is reported, never closed; merges of
   `releaseSource` itself are skipped. **Each is LOOKED UP with `get_item` before any write**; keep
   only a `hierarchyRoles.leaf` type that is not Done and has no "reached …" comment for this pull
   request, and report every skipped candidate, and every merge subject with no item number, as "not
   marked Done: <subject>" — never guess. For each kept item: `update_item` → Done with `dueDate`
   today, then `add_comment` "reached <releaseSource> with release <name> (release train pull
   request #<n>)". Nothing was recorded on the items beforehand; the git history is the record.
7. **Bring the live train up to date now**, not at close-out: `git fetch origin <releaseSource>
   <train>` first (the merge happened on GitHub, so local refs are stale), then
   `git merge-base --is-ancestor origin/<train> origin/<releaseSource>` → fast-forward it
   (`git push origin origin/<releaseSource>:refs/heads/<train>`, never `--force`); otherwise
   one-offs landed meanwhile — merge `origin/<releaseSource>` into the train (`git merge --no-ff`, a
   conflict STOPS) and push, so the train never falls behind the source.

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
  (`git diff --name-only --no-renames --cached`, so a rename reports both paths). Any match for an
  entry of `release.releaseBranchFixExclusions` (absent → nothing is refused) → **REFUSE**: commit
  nothing, name the matching files, and tell the operator in plain words: "this fix touches deploy
  configuration or database migrations; merge it to <releaseSource> through a normal pull request
  then abandon this release branch and re-cut."
- **The same check at adoption**, over every file changed by `git log --first-parent --no-merges
  --no-renames --name-only --format= <sourceHead>..origin/<name>`, plus, for each merge commit on
  that first-parent line that is not a merge of `productionBranch` (§4), the files it changed
  against its first parent (`git diff --name-only --no-renames <merge>^1 <merge>`) — a commit pushed
  or merged in by hand is caught on a resumed run.
- **Abandon and re-cut**: `gh pr close <n> --comment "<reason>; abandoned for a re-cut"`; leave the
  branch for the owner to delete (never delete it unasked); re-run `/devstride:release`, which cuts
  the next `-n`.

## 4. A hotfix lands while the release is open

`git fetch origin <productionBranch>` (with `release.clearance` set, the provider's `status`
names each hotfix landed since the claim as `Hotfix landed: #<n>`); when `origin/<productionBranch>`
is not an ancestor of `origin/<name>`: `git switch <name> && git merge --no-ff origin/<productionBranch>` (a conflict
STOPS with the files), push — on a non-draft pull request run `gh pr ready --undo` BEFORE the push,
so CI never runs on an unreviewed head — then re-enter `review` driven as a contextual follow-up
over the merge's range (its step 5 rule), carrying the ledger, counters and the same pre-ship hold
declaration; never a fresh cycle 1. A merge that leaves the tree unchanged (history only, e.g.
production's own earlier release merge) needs no re-review: say so, set `<reviewedHead>` to the new
same-tree head, and invoke `review` in PRE-SHIP RESUME mode so it flips the pull request ready and
settles CI there without a review cycle. Any return to step 2 voids an owner yes already given; step
4 asks again. Never rebase. `review` hands back here when its step 7.1 finds the production branch
advanced under a release-branch head.

## 5. Close out inside the clearance (step 5b)

Default scope: runs right after 5a's post-deploy check passes, BEFORE documentation (5c), the post-deploy
check's own close-out (5d) and release notes (5e): these steps are what the next release depends
on, so they finish while this release still holds clearance, and nothing else does. Under scope
`cut-to-deploy` it runs as soon as 5a confirms the deploy, and the post-deploy check follows the
hand-back as the first owed item, `post-deploy-check` (`clearance.md`).

1. **Sync production into the source.** Without it the release branch's fix commits never reach
   `releaseSource`. Already `git merge-base --is-ancestor origin/<productionBranch>
   origin/<releaseSource>` → nothing to do. With `release.syncWorkflow` set, a workflow syncs it:
   open nothing, re-fetch every minute until the source contains production (90 minutes at most);
   that workflow's pull request left open (a conflict, a failed check) or the time running out →
   STOP with its link for the owner. Otherwise branch per `branchNaming` (slug
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
3. **Bring the release train up to date** when `releaseTrain.branch` is set and exists on origin (a
   train not yet created is skipped, said so; leave it out of the fetch above), by §1 step 7's rule
   (fast-forward when it is an ancestor of the source, else merge the source into it), so the
   release's own fixes reach it too; report how many unreleased one-offs it carries. With a
   `claims` block and the train claim already handed on, it pushes the train only under that claim
   again: one claim, no wait, decided in mode `select` however the release started (the one
   exception to `auto-start.md`'s train-then-tower order, safe because it never waits); won →
   level, then release it `handed-on`; `takeover` (its holder lapsed) → ONE immediate takeover
   claim with that digest, decided the same way, never a third; held by a live session → SKIP the
   leveling, said so (that holder re-levels once it holds the tower, `clearance.md`); a final
   claim, `stop` or `degrade` → STOP. Never a push beside a live holder.
4. **Hand clearance back** (`release.clearance` set): the provider's `release --owed <item>` for
   each later step still to run (`post-deploy-check` under scope `cut-to-deploy`, then `docs`,
   `close-out`, `release-notes` — only those that will run),
   only now — after 1–3, never before — so a session that waits on `claim --wait` starts from a
   synced source and a level train (the next release's step 0 checks only that the source is
   ahead of production, and its train merge writes the same train branch). A 5b that stops before
   this point keeps clearance for the retry (`clearance.md`).

## Cited by

- `skills/release/SKILL.md` — steps 0b, 0c, the protected-branch floor, the hotfix rule and step 5b.
- `skills/review/SKILL.md` — step 7.1's hand-back on a release-branch head.
