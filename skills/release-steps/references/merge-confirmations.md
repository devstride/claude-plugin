---
load: contract
---
# Confirm before the merge — six checks on the yes, in order

`release-steps`' `merge-confirmations@1` step, run on the yes and before the merge. The list is
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/merge-and-deploy.md` "Step 4 — on the yes"
("Then confirm"), cited, not copied. This step merges nothing.

1. **Config wins.** Load `.claude/ds-config.json`: `release.clearance`, `preShipChecks`.
2. **Shape** (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`): `MERGED`
   → `HEAD <head>`, the head that merged; nothing is confirmed again.
3. **The yes.** The payload's `ownerGoAhead` is a yes (`yes-owner` or `yes-standing`). Anything
   else → `NOT CONFIRMED`, naming the go-ahead.
4. **Confirm, in this order**, stopping at the first that fails with `NOT CONFIRMED <which>`:
   1. **The head.** The pull request's head equals the `reviewedHead` of the payload's
      `releaseReview`. The only tolerated advances leave the tree the same:
      `review` 7.3's empty re-trigger commit, and a history-only merge of production the hotfix
      catch-up answered `SAME TREE` for. Anything else: back through the review, never merged
      over, and any yes is void (why: `release-gates.md`).
   2. **Ready and green.** The pull request is non-draft (a draft never ran CI) and every
      required check is green at that head. The merge gate proves both; its `MERGE` line is NOT
      run here.
   3. **Pre-ship.** Every pre-ship result passed or was waived on the owner's own words (the
      payload's `preShipRelease`, and under `merge-and-deploy` the entries run again at the merge).
   4. **Threads.** The paginated count of unresolved review threads is zero. A late comment is
      replied to and resolved through `review` first, never merged over.
   5. **The tower's order.** With `release.clearance` set, this pull request is the one
      `On final` in the provider's `status`.
   6. **The tower is held.** With `release.clearance` set, this session's local clearance record
      (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/clearance.md` "The local record") shows
      it holds the tower. No record → `NOT CONFIRMED tower not held`: `On final` alone proves
      nothing, since the oldest open release pull
      request is always on final, and the `release-tower` check does not cover this under
      `merge-and-deploy` (`clearance.md` "The floor"). A run resumed after a step-aside lands
      here, because its tower claim is not issued again: it stops, never merges uncleared.
5. **All six hold** → with `release.clearance` set, send the tower `heartbeat merging`. It is
   required, never skipped: exit 4, or any other failure → `NOT CONFIRMED tower not held`
   (another session owns this release now, or nothing is held). Then `HEAD <head>`, the head
   confirmed.

## Verdict

`MERGE CONFIRMED: HEAD <head> | NOT CONFIRMED <which>`

## Result

`state`: `confirmed`, `already-merged` or `not-confirmed`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
