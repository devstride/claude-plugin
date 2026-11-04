---
load: contract
---
# Review once, test once — the opt-in release economies

**Goal:** a repository that already reviews and tests every change fully on its way into
`releaseSource` can stop paying for the same review and the same test again on the way to
`productionBranch`. Every key here is OPTIONAL and opt-in; with none set, `release` behaves exactly
as its SKILL.md says (every engine on the production PR, every `releaseOnly` check unconditionally).

## `release.productionReview` — review once

```json
"productionReview": {
  "reviewIdenticalTree": false,
  "highRiskPaths": ["src/auth/**", "migrations/**"],
  "highRiskEngine": "codex"
}
```

With `reviewIdenticalTree: false`, step 2 compares the release head's tree with the tree a full
review last settled at a pull request into `releaseSource` (the release-train pull request, an
epic release pull request): `git rev-parse <sha>^{tree}`.

- **Identical** → no merge-gate review on the production pull request. Instead, run ONE pass of
  `highRiskEngine` (the configured local CLI when it names that engine) scoped to the files the
  release changes under `highRiskPaths`; none changed → no pass, said so. Its findings take the
  usual route (verify, fix on the release branch under the fix-exclusion check, reply). Then
  invoke `review` in PRE-SHIP RESUME mode (no review cycle): it marks the pull request ready and
  settles CI, so the release never stays a draft.
- **Different** — a fix landed on the release branch, or a hotfix merge (`release-branch.md` §4)
  changed the tree → `review` runs as a follow-up over that difference, carrying the settled ledger,
  with its own scope rules (`skills/review/references/delta-re-review.md`), which widen the scope
  when they say so. Once that follow-up settles, its head counts as the reviewed tree.
- Absent, or `reviewIdenticalTree` not `false` → step 2 runs as written.

Say which path the release took in the step-4 recap, with the two tree hashes.

## `onlyWhenTouched` on a `releaseOnly` pre-ship check

A `releaseOnly` `preShipChecks` entry runs at every release, `pathGlobs` ignored — unless it ALSO
sets `"onlyWhenTouched": true`. Then it runs only when the release diff touches one of its
`pathGlobs`, and step 2b reports the skip with its reason. The diff is
`origin/<productionBranch>...<head>` for the release head as it stands at 2b, and the
selection is recomputed whenever the head moves (a fix commit, a hotfix merge). A diff that cannot
be computed runs the check.

A `releaseOnly` entry may also set `"runAt": "train"`: it then runs at the release train
(`release-branch.md` §1 step 4) on the snapshot head; 2b skips it only when the train step passed it on the snapshot the release was cut from, else 2b runs it. `runAt` on
any other `when` is a config error.

## A train that carries reviewed release units

Only when `release.productionReview` is set and `epicIntegrationBranches.releaseTarget` is the release train's branch: a finished epic reaches the
train through its own release pull request — its full review — and the train pull request
(`release-branch.md` §1 step 4) then reviews only what no pull request has reviewed: the commits
the fast one-offs brought, NOT the commits a merged, reviewed release pull request brought (list
those in the scope manifest as already reviewed, with their pull request numbers). CI still runs
once over the whole train.

## Cited by

- `skills/release/SKILL.md` — step 2; `skills/pre-ship/SKILL.md` — 2b's selection.
- `skills/release/references/release-branch.md` — §1 step 4.
