---
load: contract
---
# CI settling — the flip race, gate-job semantics, and red-CI classification

The rules live in `review` step 7; this file holds the mechanics and the observed evidence, for
when the flip produces no run, a check reads `skipping`, or CI is red.

## The flip race

Workflows gate on the draft condition (`ci.draftGateCondition`), evaluated PER EVENT. A push
while the PR is still a draft fires `synchronize`, which correctly skips — and if the flip lands
before that event registers, there is no later event to re-evaluate, so the flip triggers
nothing and CI never runs at all. The failure is silent and reads as success: every job reports
`skipping`, which is indistinguishable from a suite being legitimately non-applicable, so the
whole board looks "correctly excluded". Observed on a live PR: a merge push and `gh pr ready`
one second apart left every check `skipping`, and it read as correctly-excluded until the run's
*event* and the gate job's own conclusion were inspected. That is why the body's rule is: let
the `synchronize` run register before flipping, then assert the flip took.

## Gate-job semantics

The cheap gate job (`ci.gateJobName`) carries no path filter, so on a released run it always
executes — its `skipping` means the draft gate is still closed, never that the job was filtered
out. That asymmetry is what makes it the flip assertion: any other job's `skipping` is
ambiguous (path filter? draft gate?), the gate job's is not. With `ci.gateJobName` null, the
presence of a NEW workflow run for the head SHA is the substitute evidence.

## The escalation ladder — exact steps and evidence

Bounded, in order, when the flip produced no run within ~60 s:

1. Read `gh api repos/{owner}/{repo}/pulls/<n> --jq '[.mergeable_state,.merge_commit_sha]'`.
2. **Close+reopen.** `reopened` is in the loop's trigger list, so it re-evaluates the draft
   condition — the cheapest re-trigger, and the fix for the flip race.
3. **~60 s later still `unknown`/null → ONE empty commit on the PR's OWN head.** Three
   preconditions, each with a failure behind it: the index is CLEAN (`git diff --cached --quiet` —
   a dirty index silently commits staged work); local `HEAD` IS that PR's head
   (`gh pr view <n> --json headRefName,headRefOid` — a wrong HEAD pushes one branch onto another);
   and after `git commit --allow-empty -m "ci: re-trigger — GitHub did not build this pull request's merge ref"`
   the new `HEAD^{tree}` EQUALS `HEAD~1^{tree}` (else the "empty" commit was not empty — reset and
   STOP). Push with `git push origin HEAD:<headRefName>` — a fast-forward, which the protected-head
   rule permits (it forbids rewriting); branch protection may still refuse → STOP and surface.
4. **At most one empty commit per settle.** Still nothing is a GitHub-side incident: STOP and
   surface, never loop.

The empty commit exists for the repo-wide mergeability stall (`github-review-api.md`, "The
mergeability stall"): a new head forces a per-PR mergeability recompute where existing heads stay
stalled. It is keyed on "no run + `mergeable_state: unknown`". The production cost of the no-op
commit is why it is bounded and named in the step-8 report.

## Counting runs — the run-once number

Count executed workflow runs attributed to THIS pull request — by `pull_requests[].number` on the
runs API, falling back to head repository + branch bounded to the PR's lifetime (never branch name
alone) — across the workflows matching `ci.workflowGlobs`, resolved to `workflow_id` (the same
method as `ci-audit`). A run counts when any job beyond the gate/detect job finished other than
`skipped`; an all-skipped run is 0. Count per workflow, one line each; the expected figure is
`ci.expectedRunsPerPullRequest` per workflow.

## Classifying red CI

A pending check gets at most two bounded poll instances. The first timeout may be ordinary queue
latency; the second stops with each required check's current status. Never turn a healthy but slow
run into an unbounded chain of background polls.

*Flaky/infra* means the failure class is known-intermittent and code-independent: full-shard
timeout classes, a `paths-filter` token glitch, concurrent-worker database resets — rerun
(`gh run rerun <id> --failed`), bounded to ~2, because a third identical failure is evidence,
not noise. A run that failed to TRIGGER is not red — it never existed; it is kicked by the flip
escalation. Everything else is *real*: reproduce, fix, push, re-poll — and a fix that draws new
review comments loops back through step 6, because the PR is now ready and every push re-runs
CI. That cost is the price of a defect local review missed, not a reason to loosen the
review-before-CI ordering.

## Cited by

- `skills/review/SKILL.md` — the pointer at the top of step 7 ("Read … when the flip produces no
  run, a check reads `skipping`, or CI is red"), step 7.3's escalation ladder, and step 8's run
  count.
