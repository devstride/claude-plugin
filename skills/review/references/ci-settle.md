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

## The escalation ladder's evidence

`reopened` is in the loop's trigger list, so close+reopen re-evaluates the draft condition —
the cheapest re-trigger. The empty commit exists for the repo-wide mergeability stall
(`github-review-api.md`, "The mergeability stall"): a new head forces a per-PR mergeability
recompute where existing heads stay stalled. Its three preconditions each have a failure behind
them — a dirty index silently commits staged work; a wrong HEAD pushes one branch onto another;
a changed tree means the "empty" commit was not empty. The production cost of the no-op commit
is why it is bounded to one per settle and named in the step-8 report, and "still nothing" is a
GitHub-side incident to surface, never to loop on.

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
  run, a check reads `skipping`, or CI is red").
