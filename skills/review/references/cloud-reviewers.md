---
load: contract
---
# Cloud reviewers — requesting and waiting

A branch reference (CONTRIBUTING.md, "Branch references"): `review` reads it in full before acting
on a cloud reviewer in scope (an entry of `review.automatedReviewers` whose `baseBranches` admit the
pull request). With none in scope, nothing here runs. Every bullet is an instruction.

## Requesting (step 1)

- A caller that requested at PR-open (`pr` does; never a `final-head` entry) hands over
  per-reviewer baseline, request time and outcome; request any `every-round` entry without one.
  **Request EACH in-scope `every-round` entry per its `how`** — a bot via GraphQL with its
  `graphqlBotId` (REST rejects bots) — **then confirm a NEW `review_requested` event for THAT
  reviewer**; the mutation reports success even when it creates nothing. A draft does not block an
  explicit request; never flip to "unblock" one. Hard error → drop. **Unproven within
  `reviewerRegistrationWindowMinutes` (2 minutes, every profile; re-count on a short interval) →
  DROPPED for the run**, never waited out. Track the REGISTERED set with each event's `created_at`.

## Waiting (step 2)

Nothing registered → skip. While local triage continues, ONE self-terminating background call to
`${CLAUDE_PLUGIN_ROOT}/skills/review/scripts/wait-for-reviewers.sh` — never Monitor, re-armed
wakeups, `gh pr checks --watch` or a foreground sleep — with repo/PR, registered ids + server
`created_at`, the review-id high-water mark and both bounds (`adaptiveReviewerWait` false →
`--fixed-bound`). Its `RESULT` is authoritative; `proceed-p95`/`timeout` degrade the named reviewer,
kept for step 8. Standalone may ask to keep waiting. Details:
`${CLAUDE_PLUGIN_ROOT}/skills/review/references/reviewer-latency.md`.

## Cited by

- `skills/review/SKILL.md` — step 1's Cloud bullet (also before any re-request, steps 5 and 7)
  and step 2.
- `skills/review/references/final-head-request.md` — point 2, for a `final-head` entry.
