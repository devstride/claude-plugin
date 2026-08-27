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
    # converted_to_draft is optional: with pattern B on, the (all-skipped) run it
    # creates cancels the run a mistaken non-draft open started.
    types: [opened, synchronize, reopened, ready_for_review, converted_to_draft]
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
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.run_id }}
  cancel-in-progress: true
```

Put it at the top level of every pull-request workflow. **Group pull-request runs only; give
every push run a unique group** (`github.run_id`). GitHub keeps at most one PENDING run per
group even with cancellation off, so a shared per-branch group would let a burst of pushes
replace a pending run whose path filter covered a change the later pushes do not — a backend push
followed by two frontend-only pushes would lose the only backend validation of the final tree.
Do **not** put it on a workflow whose runs must all complete (a publish, a deploy, a data job);
those get `cancel-in-progress: false` with a group of their own.

## C. Tree-identical skip on the production branch

A promotion merge (base → production) produces a commit whose **tree** is byte-identical to the
base tip that CI just tested. Re-testing it proves nothing. In the gate job, before the path
filter, compare trees and skip when they match:

```yaml
      - name: Skip when this push's tree was already tested on the base branch
        id: tree
        if: github.event_name == 'push' && github.ref == 'refs/heads/<production>'
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          git fetch --no-tags --deepen=1 origin <production>
          git fetch --no-tags --depth=1 origin '+refs/heads/<base>:refs/remotes/origin/<base>'
          T="$(git rev-parse 'HEAD^{tree}')"
          identical=false
          if P2="$(git rev-parse -q --verify 'HEAD^2')" && [ "$T" = "$(git rev-parse "${P2}^{tree}")" ]; then
            REL="$(gh api "repos/${GITHUB_REPOSITORY}/compare/<base>...${P2}" --jq .status 2>/dev/null || echo unknown)"
            case "$REL" in identical|behind) identical=true ;; esac   # the parent IS a <base> commit
          fi
          if [ "$identical" != true ] && [ "$T" = "$(git rev-parse 'origin/<base>^{tree}')" ]; then
            identical=true   # a fast-forward promotion
          fi
          echo "identical=${identical}" >> "$GITHUB_OUTPUT"
```

Two conditions, both required. Compare against the **promoted commit** — the merge's second
parent — and prove that parent is reachable from the base branch (the compare API's `identical`
or `behind`): a hotfix merged straight to production is ALSO a two-parent merge whose tree equals
its second parent, and that one must run. Compare against the base tip only as the fallback for a
fast-forward promotion, and fetch the base into an explicit remote-tracking ref — a bare
`git fetch origin <base>` writes only `FETCH_HEAD`, and `origin/<base>` would not exist.

The step needs a checkout before it, and that checkout MUST use `fetch-depth: 2` AND the step
must still `--deepen=1` the production ref — both, not either: a depth-1 checkout leaves `HEAD` a
shallow boundary, and a later `--depth=2` fetch of the same ref may not deepen it, so `HEAD^2`
never resolves, the comparison silently lacks the second parent, and the skip never fires. A gate
job that filters paths through the API alone has no repository on disk at all, and
`git rev-parse` would fail on every production push. Then fold it into the gate's
outputs: `backend: ${{ steps.tree.outputs.identical == 'true' && 'false' || steps.filter.outputs.backend }}`
(or into each step's `if:` where a workflow gates per step). A hotfix landing directly on the
production branch has a different tree and still runs — that is the case the push trigger exists
for.

## D. The convention check for humans

The loop opens every pull request as a draft. People forget. A cheap job that fails a
**non-draft pull request opened by a person** — with the convention in its message — makes the
rule self-explaining without making it a required check:

```yaml
name: CI policy

# The delivery loop opens every pull request as a DRAFT, settles review, then
# marks it ready — that flip is what starts CI, so the suite runs once, on the
# final reviewed diff. People forget. This fails a non-draft pull request opened
# by a person, with the convention in the message. Not a required check: a
# courtesy that makes the rule self-explaining. Exempt: bots (dependabot), and
# the loop's own pull requests — `gh` opens those as the OPERATOR, so the actor
# cannot tell them from a human's; every body the loop authors ends with the
# marker `<!-- devstride:loop -->`, and that marker is the exemption.
# converted_to_draft / ready_for_review re-run the SAME check name and pass:
# a failure attached to the head SHA at open would otherwise stay red after the
# person converts to draft (no new SHA), and block the later ready flip.
on:
  pull_request:
    types: [opened, converted_to_draft, ready_for_review]

jobs:
  draft-convention:
    # No runner for a correctly-opened draft (the common case): the job runs only
    # for a non-draft human open (to fail it) and for the conversion / ready events
    # (to supersede that failure on the same SHA with a pass).
    if: >-
      (github.event.action == 'opened' &&
       github.event.pull_request.draft == false &&
       !endsWith(github.actor, '[bot]') &&
       !contains(github.event.pull_request.body, '<!-- devstride:loop -->')) ||
      github.event.action == 'converted_to_draft' ||
      github.event.action == 'ready_for_review'
    runs-on: ubuntu-latest
    steps:
      - if: >-
          github.event.action == 'opened' &&
          github.event.pull_request.draft == false &&
          !endsWith(github.actor, '[bot]') &&
          !contains(github.event.pull_request.body, '<!-- devstride:loop -->')
        run: |
          echo "::error::This repository runs CI once, on the final reviewed diff. Open pull requests as DRAFTS (gh pr create --draft), settle review, then mark ready — the ready flip is what starts CI. Convert this one with: gh pr ready --undo ${{ github.event.pull_request.number }}"
          exit 1
      - run: |
          echo "Draft convention satisfied (event ${{ github.event.action }})."
```

Under a delivery profile whose release pull requests open non-draft (`prototype`, or
`review.openPullRequestsAsDraft: false`), the loop's pull requests are opened by `gh` as the
operator, not a bot — the body marker is what exempts them, and `pr` and `release` write it into
every body they author. The check is informational by design: never make it a required status.

**The convention-only shape — the one definition `setup`, `doctor` and the validation checklist
point at.** A pull-request workflow is convention-only when ALL of these hold: `on.pull_request.types`
contains `opened`, optionally `converted_to_draft` and/or `ready_for_review`, and nothing else —
never `synchronize`, and `reopened`, `edited`, `labeled` and the rest also disqualify; exactly one
job, with no `needs`, no `actions/checkout` or other `uses:` step, `run:` steps only; and that job
fails with a message on a non-draft `opened` (a job- or step-level `if` naming the draft condition
together with `github.event.action == 'opened'`) and passes on the other subscribed events. Such
a workflow is a policy notice, not a CI gate: it is removed from the population before the
four-events, concurrency and draft-gate checks, and reported as the draft-convention check being
present. The older shape — `opened` alone, one job that fails — is a subset and stays exempt;
`setup ci` counts either shape as carrying the check and offers no upgrade diff. The three-event
shape above is worth re-copying: a failure attached to the head SHA at a non-draft open is
superseded by a pass on the same SHA when the person converts to draft (no new SHA), instead of
staying red until the later ready flip inherits it. Concurrency (pattern B) still cancels the
runs the mistaken open started in the other workflows.

## The loop rules these mechanics pair with

- **Freeze the release source while a release pull request is ready**
  (`ci.freezeBaseWhileReleasePrReady`, default `true`): `release` refuses to flip while another
  pull request into the release source is mergeable, and `build-item` does not merge to the base
  branch while a ready release pull request exists. Every merge beneath a ready release pull
  request re-runs its merge preview.
- **Expected executed runs per workflow per pull request** (`ci.expectedRunsPerPullRequest`,
  default `1`): `review` step 8 counts executed runs PER WORKFLOW under `ci.workflowGlobs` on the
  pull request it just settled — a full-stack pull request runs several workflows once each — and
  names a SECOND run of the same workflow with its cause; a repeat becomes a lesson.
