---
load: contract
---
# Open the train pull request — the snapshot, into the release source

`release-steps`' `train-pr@1` step. The procedure is
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-branch.md` §1 steps 4 and 4r, cited, not
copied. This step opens the pull request and writes its durable markers; the review is the next
step's.

1. **The train gate**
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/train-finish.md` "The train phase").
   Not applicable, or nothing in flight (nothing to ship) → `NOT APPLICABLE`.
2. **This run's train pull request is already open** (the snapshot step adopted it, or a re-run)
   → never a second one. While it is still a draft, run step 5's exclusion check on its head and
   put each `allowedRenumbers` entry in its body. → `ADOPTED`.
3. **The range.** `<sourceBefore>` and `<trainSnapshot>` are the snapshot step's two evidence
   lines. When this session no longer has them, recompute them before any fix is committed:
   `git merge-base <snapshot head> origin/<releaseSource>` and `git merge-base <snapshot head>
   origin/<train>`.
4. **The body**, authored as `pr` says and listing each one-off the range carries, with these
   lines, each exactly as its owner spells it:
   - the range marker `<!-- devstride:release-train source <sourceBefore> snapshot
     <trainSnapshot> -->`: that marker, never the live train, is what closes items later;
   - with a `claims` block, or under scope `cut-to-deploy` or `merge-and-deploy`, the holder
     marker `<!-- devstride:release-train-holder <digest> on <machine> -->`
     (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/clearance.md`: `<digest>` is the first 12 hex
     characters of the SHA-256 of the provider's `identity` answer; the holder itself is never
     written);
   - when the ship plan gathered, its marker on a line of its own: read the finished plan back
     from the `release-train` claim and pipe it to `ship-plan.py marker`
     (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/ship-plan.md` "The durable record"); no
     finished plan → no line;
   - with `releaseTrain.reviewEveryLanding` true, under `## Review evidence`, the `body` of
     `python3 ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/train_receipts.py --config
     .claude/ds-config.json --source-before <sourceBefore> --head <snapshot head>` (exit 2 → no
     verdict line: stop on the error), and what it does not cover: no reviewer reads how the
     one-offs interact with each other; the one CI run over the combined train checks that.
5. **The exclusion check** on the snapshot head (`train_exclusions.py`, as the snapshot step ran
   it): each `allowedRenumbers` entry goes in the body as "migration renumbered NNNN → MMMM (the
   source took NNNN)".
6. **Open it through `pr`, driven, its steps 0 and 1 only**: base `<releaseSource>`, title
   `Release train: <n> one-off(s) for release <date>`, a draft whenever pull-request CI exists,
   flagged as a release-unit pull request exactly as `build-item` flags an epic release. `pr`
   proves the draft hold before it creates anything; a hold it cannot prove is a stop with no
   verdict line. The review step makes the declarations (`merge-only`, `fix-exclusions`, and
   `late-arrivals` as `releaseTrain.lateArrivals` says). → `OPENED`, with the number and link.

## Verdict

`TRAIN PR: OPENED <pr> | ADOPTED <pr> | NOT APPLICABLE`

## Result

`state`: `opened`, `adopted` or `not-applicable`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
