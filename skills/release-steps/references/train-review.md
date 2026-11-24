---
load: contract
---
# Review the train — the one-offs' full review, or only what no receipt covers

`release-steps`' `train-review@1` step. The procedure is
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-branch.md` §1 steps 4, 4r and 4a, cited,
not copied; `releaseTrain.lateArrivals` and `train_receipts.py` keep their rules there and in the
script's header. `pr` and `review` own the draft hold, the engines and the one ready flip.

1. **The train gate**
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/train-finish.md` "The train phase").
   Not applicable, or nothing in flight → `NOT APPLICABLE`.
2. **Stand on the reviewed tree.** `gh pr checkout <n>` for this run's train pull request and
   confirm `HEAD` equals its `headRefOid`, so the local engine and the pre-ship suites see that
   tree. On a re-run after this session's own review marked it ready, no new cycle starts and
   nothing is pushed (CI last, once): `review` in PRE-SHIP RESUME mode settles CI when it is
   still running → `SETTLED` with its head. An adopted pull request is reviewed as below.
3. **Declare, every time**: driven; a release-unit pull request; `merge-only: true`;
   `fix-exclusions: true`; and, while `releaseTrain.lateArrivals` is `"restart"` and fewer than
   three absorbs are on the snapshot, `late-arrivals` with `<train>` and `<trainSnapshot>`.
4. **Which review runs.**
   - `releaseTrain.reviewEveryLanding` not true → `pr` steps 2 to 2c on the open pull request,
     driven: `review` takes the FULL diff, because a one-off merged fast onto the train has had
     no full review yet and this is its first and only one before production. With
     `release.productionReview` set, a release unit that joined through its own reviewed pull
     request is left out (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/review-once.md`).
   - `releaseTrain.reviewEveryLanding` true → `train_receipts.py` over `<sourceBefore>` to the
     snapshot head (§1 step 4r). Exit 0, `receipted`: no review round; `pr`'s pre-ship checks run
     at the snapshot head as if `review` had reached its hold, then `review` in PRE-SHIP RESUME
     mode, named as that mode, marks it ready and settles CI, once (no hold → straight away) →
     `RECEIPTED`. Exit 1, `needs-review`: a short review of only the `unreviewed` entries, the
     scope manifest naming each one's diff and listing the receipted items and reviewed units as
     already reviewed, never re-read. Exit 2 → `BLOCKED`, with the error.
5. **Fixes** are committed on the snapshot, each passing the staged-file check of
   `release-branch.md` §3 first: a migration or deploy-configuration fix leaves the train and
   goes to the source by its own pull request. With step 4's receipts, every fix is itself a
   direct commit: run the script again on the final head before the ready flip, and anything new
   it lists joins the review.
6. **A late landing** (§1 step 4a; each progress report fetches the train and names any).
   - `"restart"`: `review` stops with `LATE-ARRIVAL`, the pull request still a draft. Absorb as
     4a says (the exclusion check over the new train work only, the merge with 4a's exact
     subject, the marker, title and list rewritten), then answer `LATE ARRIVAL` with how many
     were absorbed. The step is issued again: a fresh cycle 1 over the full snapshot diff with the
     carried ledger. The third absorb's run, and the first ready flip, end the window: later
     landings ship next time, said so.
   - `"offer"`, or absent: absorb only on the owner's instruction in this session, and only
     before the ready flip; the absorbed range gets 4a's one full-scope cycle inside this step.
7. **Heartbeat the train claim** through the review and the CI wait
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md` "Heartbeats").
8. **Answer.** Reviewed, ready and CI settled → `SETTLED`, with the settled head: the merge step
   pins it. A verified P1 or serious P2 that is not fixed, a required engine that cannot run, a
   refused absorb or red CI that cannot be settled → `BLOCKED`, saying which. The untracked
   deferrals `pr` returns are listed in the evidence for the release's own review; never spliced.

## Verdict

`TRAIN REVIEW: RECEIPTED | SETTLED <head> | LATE ARRIVAL <count> | BLOCKED <reason> | NOT APPLICABLE`

## Result

`state`: `receipted`, `settled`, `late-arrival`, `blocked` or `not-applicable`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
