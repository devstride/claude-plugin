---
name: ci-audit
description: "Measure what the delivery loop actually spends on CI — executed workflow runs per pull request (target: one), post-merge push minutes, release pull requests re-run by a moving base — and name the offenders. Read-only; GitHub Actions via gh."
---

Audit the repository's GitHub Actions usage against the loop's run-once design, and say
precisely where the minutes go. The draft hold makes CI run once per pull request in theory; this
skill measures whether it does in practice, and where the rest of the bill comes from.

**Read-only.** It runs `gh` queries and prints a report. It never cancels a run, edits a workflow,
or changes a setting — every fix is text to print.

Optional argument — a window in days (default `7`), and/or a workflow name to focus on:
$ARGUMENTS

**Config.** `.claude/ds-config.json`: `ci.workflowGlobs` (which workflows belong to the loop),
`ci.expectedRunsPerPullRequest` (default `1`), `release.releaseSource` / `release.productionBranch`
/ `baseBranch` (to recognise release pull requests and post-merge pushes).

## Why runs are the wrong number, and minutes are the right one

The Actions usage page counts a **run** every time a workflow is triggered — a push to a draft
pull request creates a run whose jobs all skip, and that run costs seconds. So a repository with a
working draft hold still shows hundreds of runs per workflow. **Count executed jobs and their
minutes**, never runs: a run whose expensive jobs were skipped is the gate working, not a cost.

## 1. Collect

```bash
gh run list --limit 1000 --created ">=$(date -u -v-${DAYS}d +%Y-%m-%d 2>/dev/null || date -u -d "-${DAYS} days" +%Y-%m-%d)" \
  --json databaseId,event,headBranch,workflowName,createdAt,conclusion
```

`--limit 1000` is the API ceiling; if the earliest run returned is later than the window start,
say so — the window is shorter than asked and the totals are a floor, not the month.

For each run in the loop's workflows (match `workflowName` against the workflows under
`ci.workflowGlobs`), fetch its jobs:

```bash
gh api "repos/{owner}/{repo}/actions/runs/<id>/jobs?per_page=100" \
  --jq '[.jobs[]|{name,conclusion,minutes:(((.completed_at|fromdateiso8601)-(.started_at|fromdateiso8601))/60)}]'
```

A run **executed** when any job other than the gate/detect job finished with a conclusion other
than `skipped`. Sum minutes over non-skipped jobs. Runs on `hosted-larger` runners cost more per
minute; report minutes and, where the usage page gives it, the runner type.

## 2. Classify every executed run

| Class | How to recognise it | What "good" looks like |
|---|---|---|
| **First run on a pull request** | `event == pull_request`, first executed run for that head branch | One per pull request — this is the run the loop intends |
| **Re-run on a pull request** | Any further executed `pull_request` run on the same head | Zero. Each one has a cause: a push after the ready-flip, a base that moved (GitHub re-runs the merge preview), or a pull request opened non-draft |
| **Release pull request re-run** | Head is `release.releaseSource` (or the release-unit branch) | Zero. These come from merging OTHER pull requests into the release source while the release pull request sat ready — every merge re-runs its preview |
| **Post-merge health check** | `event == push` on `baseBranch` / `productionBranch` | At most one per merge to the base branch; **zero on the production branch when its tree is identical to the base tip that was just tested** (a promotion merge has the same tree) |
| **Other** | schedule, `workflow_dispatch`, bots | Named and counted, not judged |

## 3. Report

Print, for the window:

1. **Totals** — runs, executed runs, executed minutes; the share of minutes per class above.
2. **Executed runs per pull request** — a table of head branches with more than
   `ci.expectedRunsPerPullRequest` executed runs, each with its count and the most likely cause
   (a push after ready: commits on the head dated after the `ready_for_review` timeline event; a
   moved base: no head commit but a new run; opened non-draft: no draft phase in the timeline).
   Then the ratio `executed PR runs / pull requests` — the loop's single most telling number;
   `1.0` is the design.
3. **Post-merge push minutes**, split by branch, and how many production-branch runs had a tree
   identical to the base tip (`git rev-parse <sha>^{tree}` on both) — those are pure waste.
4. **Release pull request re-runs** and the merges that caused each (merges into the release
   source between the release pull request's ready-flip and its merge).
5. **Verdict and fixes**, in priority order by minutes saved, each naming the mechanism:
   - Production-branch push re-tests an identical tree → the tree-identical skip
     (`${CLAUDE_PLUGIN_ROOT}/skills/setup/references/ci-cost-patterns.md`, pattern C).
   - Pull requests with several executed runs → per-pull-request `concurrency` with
     cancel-in-progress (pattern B) plus the loop's post-flip discipline (`review` step 8 reports
     the count; `release` freezes the base).
   - Release pull request re-runs → the freeze rule (`ci.freezeBaseWhileReleasePrReady`).
   - A human-opened non-draft pull request → the policy check (pattern D).
   `/devstride:setup ci` applies the workflow patterns; the loop rules are on by default.

Keep the report honest about what it cannot see: job minutes come from timestamps, not billing;
runner multipliers and included minutes are the usage page's business.
