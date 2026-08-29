---
name: ci-audit
description: "Measure executed CI minutes, premature runs before the final reviewed head, per-workflow PR reruns, post-merge pushes, and release-PR churn. Read-only; GitHub Actions via gh."
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

Audit GitHub Actions against the loop's floor: every profile spends expensive pull-request CI
once, after review and matched pre-ship checks settle on the final HEAD. Count minutes, expose
early work as well as reruns, and name the repair.

**Read-only.** Query with `gh` and print a report; never cancel a run, edit a workflow, or change
a setting. Optional argument — window in days (default `7`) and/or workflow name: $ARGUMENTS

**Config.** `.claude/ds-config.json`: `ci.workflowGlobs`,
`ci.expectedRunsPerPullRequest` (default `1`), `release.releaseSource`,
`release.productionBranch`, and `baseBranch`.

## Why the Actions run count lies

A push to a correctly held draft still creates an all-skipped run costing seconds. Count a run as
**executed** only when a job beyond the configured gate/detect job finishes other than `skipped`;
sum non-skipped job minutes. A run can meet the one-per-workflow count and still be waste: if it
was triggered before the final ready flip, the suite was released before review/pre-ship settlement.

## 1. Collect

```bash
gh api "repos/{owner}/{repo}/actions/runs?per_page=100&created=>=$(date -u -v-${DAYS}d +%Y-%m-%d 2>/dev/null || date -u -d "-${DAYS} days" +%Y-%m-%d)&status=completed" --paginate \
  --jq '.workflow_runs[]|{id,event,head_sha,head_branch,head_repository:.head_repository.full_name,workflow_id,name,created_at,run_started_at,conclusion,pull_requests:(.pull_requests // [])}'
```

Use REST, not `gh run list`: pull-request associations and head repository prevent a reused branch
or same-named fork from joining two PRs. Paginate to the window start; if the API stops short,
report a floor. Resolve workflow FILES first, then filter by id — names are not unique:

```bash
gh api "repos/{owner}/{repo}/actions/workflows?per_page=100" --paginate \
  --jq '.workflows[]|{id,name,path}'
```

Keep ids whose `path` matches `ci.workflowGlobs`. Fetch every run's jobs with all attempts:

```bash
gh api "repos/{owner}/{repo}/actions/runs/<id>/jobs?filter=all&per_page=100" --paginate \
  --jq '[.jobs[]|select(.completed_at!=null and .started_at!=null)|{name,conclusion,attempt:.run_attempt,minutes:(((.completed_at|fromdateiso8601)-(.started_at|fromdateiso8601))/60)}]'
```

`filter=all` includes billed retry attempts; timestamp guards avoid null arithmetic; pagination
covers large matrices. Report runner type where available because hosted-larger minutes cost more.

For each associated PR, fetch its recorded final source head and state:

```bash
gh pr view <pr> --json headRefOid,createdAt,mergedAt,state,isDraft,url
gh api "repos/{owner}/{repo}/issues/<pr>/timeline?per_page=100" --paginate --slurp
```

From the timeline's ordered `ready_for_review` / `convert_to_draft` events, the **final-ready
event** is the latest ready event only when no later conversion returned the PR to draft. An
initially non-draft PR has no such event; that absence is evidence that ordering was not gated.
The ready flip is the observable proxy for “review and pre-ship checks settled.”

Resolve the run's **source-head SHA**, not blindly `head_sha`: a pull-request run may name
GitHub's synthetic merge commit and `pull_request_target` may name the base. Prefer the run's
embedded `pull_requests[].head.sha`, then `head_commit.id`; when only a synthetic merge SHA is
available, inspect its parents and use the PR-head parent. If it cannot be resolved, report
`unknown` rather than inventing a premature run.

## 2. Classify executed runs

| Class | Recognition | Target |
|---|---|---|
| **PR first** | First executed run of this workflow for this PR number (`pull_request` or `pull_request_target`) | One per touched workflow |
| **PR rerun** | Later executed run or `run_attempt` of the same workflow and PR | Zero |
| **Release-PR rerun** | Head is `release.releaseSource` or a release-unit branch | Zero |
| **Post-merge push** | `push` on `baseBranch` / `productionBranch` | ≤1 per base merge; zero for a tree-identical production promotion |
| **Other** | Schedule, dispatch, bot, unmatched event | Name; do not judge |

Apply a separate **PREMATURE** flag to every executed PR run when ANY is true:

- no final-ready event exists (non-draft/ungated open; this includes historical `prototype` PRs);
- the run was triggered (`created_at`) before the final-ready event; or
- its resolved source-head SHA differs from the PR's final `headRefOid`.

Never exempt a delivery profile, release PR, or loop body marker. A later distinct head before the
ready event is a **pre-ready repair rerun** — review and pre-ship fixes are indistinguishable in
Actions metadata, so label it `review/pre-ship repair` unless commit evidence proves which. This
is still waste even when only one run of that workflow exists at each SHA.

For ordinary reruns, infer causes from evidence: head commit after ready → post-flip fix; same head
and new run → moved base; no ready/draft phase → non-draft open; zero-file “re-trigger” commit →
review's fallback (excess only if that workflow had executed already). Attribute by PR number
first, head repo + branch only as fallback.

## 3. Report

Lead with one to three plain bullets: total CI cost, avoidable waste, and the single highest-value
fix. Then print the supporting evidence for the window:

1. **Totals** — triggered runs, executed runs/minutes, and minute share by class.
2. **Premature expensive CI** — one row per flagged run: PR, workflow, run id/time, source head,
   final head, final-ready time or `MISSING`, minutes, and evidenced cause. Separately total
   initial ungated runs and review/pre-ship-repair reruns; include `prototype`, never hide it in
   “expected by profile.” Unknown SHA/time evidence is `unverifiable`, not green.
3. **Executed runs per workflow per PR** — rows above
   `ci.expectedRunsPerPullRequest`, with cause. Then print
   `Σ executed PR runs ÷ Σ distinct workflows executed per PR`; `1.0` is the count target, while
   the premature table proves ordering.
4. **Post-merge push minutes**, by branch, plus production runs whose tree equals the just-tested
   base tree — pure waste.
5. **Release-PR reruns** and merges into the release source between final-ready and merge that
   caused each preview rerun.
6. **Verdict and fixes**, ordered by measured minutes:
   - premature / non-draft / pre-ready repair run → `/devstride:setup ci` applies the complete
     draft gate; the PR/release loop must keep every profile draft through pre-ship settlement;
   - second PR workflow run → pattern B concurrency plus post-flip discipline;
   - release-preview rerun → `ci.freezeBaseWhileReleasePrReady`;
   - identical production push → pattern C tree skip;
   - human non-draft open → pattern D policy check.
   Patterns are in `${CLAUDE_PLUGIN_ROOT}/skills/setup/references/ci-cost-patterns.md`.

Be explicit about limits: timestamps approximate billed minutes; runner multipliers and included
minutes come from the usage page; GitHub cannot distinguish a review fix from a pre-ship fix
without repository evidence.
