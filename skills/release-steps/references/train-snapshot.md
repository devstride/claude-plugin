---
load: contract
---
# Snapshot the train — the release reviews a copy only this run writes to

`release-steps`' `train-snapshot@1` step. The live train keeps receiving one-offs while this
runs, so the release never reviews or merges the live branch. The procedure is
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-branch.md` §1 steps 2 and 3, with its
"The exclusion check" and "Release holds"; all cited, not copied.

1. **The train gate**
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/train-finish.md` "The train phase").
   Not applicable → `NOT APPLICABLE`.
2. **An open release-train pull request is adopted before anything is cut** (§1 step 2; found by
   §1 "Finding release-train pull requests"). Whose it is:
   - With a `claims` block the won train claim decides: its holder marker is this session's, or
     names the holder whose lapsed claim this run took over
     (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/auto-start.md` "The holder marker stays").
     Without one, under scope `cut-to-deploy` or `merge-and-deploy`: the marker is this session's
     or absent (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/clearance.md`); under scope
     `release`, or with no `release.clearance`, the open one is this run's.
   - Any other marker, or an absent one with a `claims` block → `OTHER HOLDER`, naming the pull
     request and its marker. It is adopted only on the owner's yes AND their word that its
     session has stopped, both read from the payload's `answer`; never silently.
   - Adopting: read `<sourceBefore>` and `<trainSnapshot>` from its range marker (none → no
     verdict line: name it and stop; never guess a range), `gh pr checkout <n>` and confirm `HEAD`
     equals its `headRefOid`, then steps 5 and 7 on that head → `ADOPTED`. Nothing new is cut.
3. **With a `claims` block, heartbeat the train claim first.** One that is lost or degrades is a
   stop with no verdict line (`auto-start.md`): nothing is cut without the claim.
4. **`git fetch origin <releaseSource> <train>`.** What is on the train now is the release. No
   one-off beyond the source (`git log --no-merges --oneline origin/<releaseSource>..origin/<train>`
   is empty; merges of the source alone are not work) → `NOTHING TO SHIP`, said as "release train:
   nothing to ship". Nothing is then in flight for the rest of the phase.
5. **Release holds** over every item the range carries (each one-off's merge subject and landed
   record), with its ancestors, by the helper of
   `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/release-holds.md`. Held → `HELD`, naming each
   item and reason: "<item> is held (<reason>) but already on the train: wait for the hold to
   lift, or remove its `Release hold:` line; taking it off the train is the owner's call."
6. **Cut the snapshot.** Record `<sourceBefore>` (the `origin/<releaseSource>` SHA) and
   `<trainSnapshot>` (the `origin/<train>` SHA). Create a branch named per `branchNaming` (slug
   `release-train-<date>`, then `-2` and so on when taken) at `<trainSnapshot>`, `git merge
   --no-ff origin/<releaseSource>` into it so review and the pre-ship checks see the combined
   tree, and push. A conflict → `CONFLICT`, naming the files; it is never resolved automatically.
   One-offs that land on the live train from now on ship in the next release. On a re-run, a
   snapshot branch this session already pushed that has no pull request yet is reused, never cut
   a second time.
7. **The exclusion check**: `python3
   ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/train_exclusions.py --config .claude/ds-config.json
   --source-before <sourceBefore> --head <snapshot head>` (its header has the rules). Exit 1 →
   `REFUSED`, naming each file in `refused` with §1's sentence, and each `unprovenUnits` entry
   (number, reason) apart: its files go to the owner, not to the source. Never post a proof to
   clear a refusal. Exit 2 → no verdict line: stop on the error.
8. **Answer** `CUT`, naming the snapshot branch, with `<sourceBefore>` and `<trainSnapshot>` on
   evidence lines of their own: the next step writes them into the pull request's range marker.

## Verdict

`TRAIN SNAPSHOT: CUT <branch> | ADOPTED <pr> | NOTHING TO SHIP | HELD <reason> | REFUSED <files> | OTHER HOLDER <pr> | CONFLICT <files> | NOT APPLICABLE`

## Result

`state`: `cut`, `adopted`, `nothing-to-ship`, `held`, `refused`, `other-holder`, `conflict` or
`not-applicable`. On `CUT` and `ADOPTED` also `head`, the snapshot head's full SHA (as pushed,
or the adopted pull request's `headRefOid`), where the train's pre-ship checks run, and
`sourceBefore`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
