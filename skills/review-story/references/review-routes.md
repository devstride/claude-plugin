---
load: contract
---
# Review routes — the fast local review or the full pull-request review

`review-story`'s procedure: which path a story's review takes, what each path does, the release
train's landing review, and the proof the step leaves.

## Which path

The working base picks the path, never the diff. The loop resolved it as the review moment
(`skills/build-item/SKILL.md`, Working base) and passes it: `release-deferred` → the fast path,
`pr-boundary` → the pull-request path. Never mix: a fast review toward develop reaches production
never cloud-reviewed, so a story whose working base is `baseBranch` is never reviewed on the fast
path, whatever it is passed.

**Nothing configured locally** (the payload's `localChecksProof` kind `none-configured`) → the
pull-request path, on the release train too: CI on the pull request is then the only gate, and the
runner refuses a merge of it after any other review (`none-configured-needs-pull-request-route`).

**THE FLOOR:** no completed risk check (the payload's `riskCheck` with no `ledger`, its
immediate-risk verifiers and matched lenses included) or no valid verification receipt (the
payload's `localChecks` with a null `receipt`, or one
`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/verification-receipts.md` says no longer holds
for this tree) → the pull-request path, saying why. On the release train a missing risk check or
receipt (local checks configured) is made good by the LOCAL-FULL review below, never by a pull
request, which would spend a CI run.

## Fast path

- **`review` in LOCAL-ONLY mode** with the base (`origin/<workingBase>`), profile and caller ledger
  (the risk check's ledger and findings, the verification receipt, the dismissed and untracked
  lists): no second engine, but it owns triage, fixes and lessons. On the release train see "The
  train's landing review": a small fix may skip it, any other runs LOCAL-FULL instead.
- **Fix every fix-in-story finding it returns** (its `fixFloor` triage; a reasoned deferral is not
  re-imposed) per `commitConventions.reviewFixFormat` (fallback
  `fix(<scope>): <summary> [<itemNumber> review]`); an unfixed finding worth filing (`review` step
  4) → its owning item, else the untracked-deferral list; any other → dismissed, with its rationale
  in `mergeBody` (with the risk check's dismissed findings), which the fast merge puts in its
  merge-commit body.
- **No PR, no draft, no cloud request, no CI poll** — an absent check is neither pending nor
  skipped. Never open a PR "for the record".
- A fix changes the tree: report it, and leave the rest to the runner, which issues the local
  checks again on the new tree before the merge.

## Pull-request path

Invoke **`pr`** in autonomous (driven) mode with the working base pre-answered and the profile by
name — `review` owns the cycle target, P1/serious-P2 continuation and fix floor; the completion
step (`story-lifecycle`) owns linking the pull request to the item. It opens a draft wherever the
repo holds CI on drafts (`prototype` too), requests every in-scope cloud reviewer in the same call
and settles through `review`. Deferrals, deviations and dismissals (with rationale) go in the PR
body (the build's and the risk check's, from the payload). The push/ready-flip race is `review` step 7's; the merge step never reads `skipping` as green.

**Asked again** (the runner found the patch changed: a fix, or a refreshed base): a pull request
already open for the branch is never opened twice. Re-enter through `pr` driven, naming that pull
request (its re-entry: no second open, no new reviewer requests), never `review` directly: `pr`
selects the pre-ship checks again on the new diff and declares the hold, invokes `review` on it
with its cumulative ledger, target and safety state, never a fresh budget, then runs the checks and
discharges the hold (`pr` 2b and 2c, `review` in PRE-SHIP RESUME mode). Why: a direct `review`
would flip the pull request ready, releasing CI, before the pre-ship checks ran on the diff it
settled. A merged or closed pull request for the branch → `BLOCKED`, naming it.

## The train's landing review

On the release train's fast path only (`releaseTrain.fastMerges` true;
`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/release-train.md` is the route), the full
review, the configured engines and CI move to the train's pull request into `baseBranch`, which
`release` opens before every cut. Before it lands, each one-off still gets the review its size
calls for:

- **A small, clean fix skips its own review pass.** With `releaseTrain.smallFixes` set, after the
  build run `git diff --numstat -z --no-renames origin/<train>...HEAD |
  python3 -c 'import json,sys; print(json.dumps({"config": json.load(open(".claude/ds-config.json")),
  "numstat": sys.stdin.read()}))' | python3 ${CLAUDE_PLUGIN_ROOT}/skills/build-item/scripts/routing.py
  small` — never through a shell variable, which drops the NULs (exit 2 → `BLOCKED`, naming the
  error). `small: true`, AND the risk check raised no finding, launched no immediate-risk verifier
  and matched no mandatory lens → the LOCAL-ONLY `review` call does not run: with no finding there
  is nothing to triage or distill into lessons. Answer `REVIEW: COVERED small fix: N files, M lines`
  (the progress row reads "covered by the train's release review"). Everything else holds: the
  floor, the local gate, the merge-commit body. `small: true` with a finding → the fast path runs
  as usual (the finding still reaches the lessons store through it), the reason said once.
- **A larger or riskier fix gets its full review before it lands, on this machine.** `small: false`
  (over either limit, a binary file, or a high-risk path; computed only with `smallFixes` set) →
  `review` runs in **LOCAL-FULL** mode instead of LOCAL-ONLY: Claude and the configured CLI engine at
  merge-boundary depth, the full cycle target and P1 continuation; no pull request, no cloud
  reviewer, no CI. It records its review for the landing gate
  (`${CLAUDE_PLUGIN_ROOT}/skills/review/references/local-full.md`, step 3). Why local: cloud runners
  are paid per run, so the train's pull request into `baseBranch` stays the batch's one CI run,
  while a late find on a large fix is caught here before it can hold up a release.
- **Every one-off reviewed before it lands** (`releaseTrain.reviewEveryLanding` true). The
  small-fix skip never applies: every train one-off runs LOCAL-FULL, sized to the change
  (`local-full.md`: a small fix gets one cycle, anything else the full target), and the landing
  gate answers `reviewed` only with a receipt at exactly that head, or carried to it under
  an unchanged patch, whatever the size; its refusal
  names the size. Its receipt's first line rides in the landing's merge-commit body, and, with the repository admin's landing proof
  `local-full.md` step 3 posts on the reviewed head, it is the train pull request's review
  evidence: that pull request then reviews only what no receipt covers
  (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-branch.md` §1 step 4r). Why: each
  landing session reviews its own one-off, so many reviews run at once, and the train's pull
  request waits only for its one CI run instead of a batch review.
- **The landing gate, once settled**: `python3
  ${CLAUDE_PLUGIN_ROOT}/skills/build-item/scripts/review-gate.py check` with `{"base":
  "origin/<train>", "head": "<HEAD>"}` must answer `small`, `reviewed` or `not-applicable`; its
  `mergeBody` joins this step's `mergeBody`. Exit 2 → LOCAL-FULL (or its follow-up), which records
  the review, then check again. Asked again, check FIRST: `reviewed` settles it, no engine run.
  `merge-story` checks again at the exact head it merges.

## The proof

Once the review is settled and every fix is committed (a clean tree), the proof names `path`
(`fast-local` for LOCAL-ONLY, LOCAL-FULL and a covered small fix; `pull-request`), `head` = `git
rev-parse HEAD`, `base` = `origin/<workingBase>` (the ref name, so a base that moves under an
unchanged patch keeps the proof), `pullRequest`, and `patchId`, the first field of exactly the
command the runner checks it with
(`${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/references/workflow-contracts.md`, Proofs):

```bash
git diff --no-color --no-ext-diff --no-textconv --no-relative --src-prefix=a/ --dst-prefix=b/ \
  --ignore-submodules=none --unified=3 --no-renames --diff-algorithm=myers --inter-hunk-context=0 \
  origin/<workingBase>...HEAD -- | git patch-id --verbatim
```

A pull request's local head must equal the head the pull request shows: `git fetch` and compare
before computing it.

## Cited by

- `skills/review-story/SKILL.md` — the pointer before choosing the path ("Read … in full before
  choosing the path").
- `skills/build-item/references/release-train.md` — the train's delivery path.
