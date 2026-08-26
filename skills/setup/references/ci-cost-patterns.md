# CI cost patterns — the workflow mechanics behind "run CI once, at the end"

The delivery loop's design is that CI runs **once per pull request, on the final reviewed diff**,
and once per merge to the base branch. Four workflow mechanics enforce that mechanically, so it
does not depend on anyone's discipline. `/devstride:setup ci` detects which are present, proposes
the missing ones as exact diffs, and applies them only on acceptance; `/devstride:doctor` reports
them; `/devstride:ci-audit` measures the result.

Measured on one repository over six days before any of B–D: the draft gate (A) already held —
107 of 177 test runs skipped every expensive job for a total of six minutes — while **51% of the
real minutes were post-merge push runs**, half of them on the production branch re-testing a tree
the base branch had just tested, and **18% were a release pull request re-run every time another
pull request merged beneath it**. Story pull requests were already at one run each.

## A. The draft gate (already required by the loop)

Every job in a pull-request workflow is gated on the draft condition, directly or through a
`needs` chain from one cheap gated job, and `on.pull_request.types` names all four events:

```yaml
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
jobs:
  changes:
    if: >-
      github.event_name == 'push' ||
      github.event.pull_request.draft == false
```

State the `push` case explicitly rather than relying on GitHub coercing a null `draft` to false.

## B. Concurrency — a superseded run is cancelled, not finished

One group per pull request (or per branch for push events); a new push cancels the run it
supersedes. This is the cheapest change and it costs nothing when the loop behaves — it only
bites when a push lands while a run is in flight.

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true
```

Put it at the top level of every pull-request workflow. Do **not** put it on a workflow whose
runs must all complete (a publish, a deploy, a data job); those get `cancel-in-progress: false`
with a group of their own.

## C. Tree-identical skip on the production branch

A promotion merge (base → production) produces a commit whose **tree** is byte-identical to the
base tip that CI just tested. Re-testing it proves nothing. In the gate job, before the path
filter, compare trees and skip when they match:

```yaml
      - name: Skip when this push's tree was already tested on the base branch
        id: tree
        if: github.event_name == 'push' && github.ref == 'refs/heads/<production>'
        run: |
          git fetch --no-tags --depth=1 origin <base>
          if [ "$(git rev-parse 'HEAD^{tree}')" = "$(git rev-parse 'origin/<base>^{tree}')" ]; then
            echo "identical=true" >> "$GITHUB_OUTPUT"
            echo "Tree identical to <base> tip — already tested there; skipping."
          else
            echo "identical=false" >> "$GITHUB_OUTPUT"
          fi
```

and fold it into the gate's outputs: `backend: ${{ steps.tree.outputs.identical == 'true' && 'false' || steps.filter.outputs.backend }}`
(or into each step's `if:` where a workflow gates per step). A hotfix landing directly on the
production branch has a different tree and still runs — that is the case the push trigger exists
for.

## D. The convention check for humans

The loop opens every pull request as a draft. People forget. A cheap job that fails a
**non-draft pull request opened by a person** — with the convention in its message — makes the
rule self-explaining without making it a required check:

```yaml
name: CI policy
on:
  pull_request:
    types: [opened]
jobs:
  draft-convention:
    if: >-
      github.event.pull_request.draft == false &&
      !endsWith(github.actor, '[bot]')
    runs-on: ubuntu-latest
    steps:
      - run: |
          echo "::error::This repository runs CI once, on the final reviewed diff. Open pull requests as DRAFTS (gh pr create --draft), settle review, then mark ready — that flip is what starts CI."
          exit 1
```

Under a delivery profile whose release pull requests open non-draft (`prototype`), scope the
condition to `!endsWith(github.actor, '[bot]')` only, as above, so the loop's own pull requests
are never failed by it.

## The loop rules these mechanics pair with

- **Freeze the release source while a release pull request is ready**
  (`ci.freezeBaseWhileReleasePrReady`, default `true`): `release` refuses to flip while another
  pull request into the release source is mergeable, and `build-item` does not merge to the base
  branch while a ready release pull request exists. Every merge beneath a ready release pull
  request re-runs its merge preview.
- **Expected executed runs per pull request** (`ci.expectedRunsPerPullRequest`, default `1`):
  `review` step 8 counts executed runs on the pull request it just settled and reports any
  excess with its cause; a repeat becomes a lesson.
