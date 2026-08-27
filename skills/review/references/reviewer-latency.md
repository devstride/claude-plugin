# The adaptive reviewer wait — how the bound is learned, and why

`review` step 2 waits for the cloud reviewers it registered. Before this, the wait was one
fixed bound — `review.pollTimeoutMinutes`, 20 minutes under `enterprise` — polled every ~30 s.
A reviewer that answers in three minutes was fine; a reviewer that never answers cost the whole
bound, about 17 minutes of idle and ≈ 40 API calls. `skills/review/scripts/wait-for-reviewers.sh`
replaces that with a bound learned **per reviewer, on this machine**, a backoff, and an exit on
the tick the review lands — inside the floors the profile contract already sets.

## The rule in one paragraph

For each registered reviewer: take its ring of past latencies from the cache. With fewer than
**5 samples** (or a cold, corrupt or unreadable cache, or `review.adaptiveReviewerWait: false`),
the bound is the full `pollTimeoutMinutes`. Otherwise the bound is the **nearest-rank p95** of
the ring plus **120 s of slack**, clamped to
`[reviewerRegistrationWindowMinutes, pollTimeoutMinutes]`. The clock runs from the server's
`created_at` of the reviewer's `review_requested` event, so time spent before `review` was
invoked is already spent. The poll ticks at 20, 30, 45, 68, 90, 90 … seconds (×1.5, capped at
90), with the last sleep clamped to the nearest bound, so a wait never overshoots by a tick.

- Nearest-rank p95: `sorted[ceil(0.95 · n) − 1]`. On 12 samples that is the 12th-largest —
  i.e. the max; on 20 it is the 19th. Simple, no interpolation, no surprise on small rings.
- Slack 120 s: one maximum tick (90 s) plus a margin, so a reviewer that lands right at its p95
  is still caught by the next tick rather than declared a non-responder one tick early.
- The window is a FLOOR on the bound, never a drop trigger: dropping a reviewer for a missing
  registration is step 1's job, done before this script runs.

## Why the samples come from server timestamps only

A sample is `submitted_at − registeredAt`, both ISO-8601 strings GitHub returned. It is never
the time at which a *tick* noticed the review. With a backoff the tick-observed latency is the
real latency plus up to one interval — and if THAT were learned, the p95 would inflate itself
through the very cadence it drives, lengthening every future wait. Server timestamps are the
only measurement the wait cannot contaminate. A sample below 0 or above 24 h is rejected and
the rejection printed (clock skew on the server side would be news worth seeing).

## Why the key is the GraphQL bot id

One reviewer, three logins: the timeline's `requested_reviewer.login` (`Copilot`), the
`/reviews` login (`copilot-pull-request-reviewer[bot]`), and the `/comments` login. The
`node_id` is the same across all of them — verified live, it is `BOT_kgDOCnlnWA` on both the
timeline event and the review object — so the ring is keyed on it and a review is matched to
its reviewer on `user.node_id`. `reviewsLogin` is accepted as a fallback match only. Never
match on a login from a different endpoint's table (`github-review-api.md`, "One reviewer,
three logins").

## The cache

`${XDG_CACHE_HOME:-~/.cache}/devstride-plugin/reviewer-latency.json`, beside the version
check's `newest.json`:

```json
{ "version": 1,
  "reviewers": {
    "BOT_kgDOCnlnWA": {
      "samples": [ { "at": "2026-08-27T10:03:00Z", "latencySeconds": 156, "repo": "o/r", "pr": 12 } ],
      "updatedAt": "2026-08-27T10:03:00Z" } } }
```

- A ring of **20** per reviewer, oldest dropped. Machine-wide on purpose: a reviewer's latency
  is a property of the reviewer, not of the repository; only the bound's *clamp* is per run,
  from that run's `pollTimeoutMinutes`, so one repository's ceiling never leaks into another's.
- **Advisory, never an error.** A missing file is cold. An unparsable file is `corrupt` and
  behaves cold. A directory that cannot be written leaves the state `unwritable` and the wait
  still exits normally. Every read and write is wrapped; the `RESULT` line's `cacheState`
  says which happened. The cache can only ever *shorten* a wait.
- `--fixed-bound` (the config key off) still records samples, so switching the key on later
  starts warm.
- **Reset:** delete the file. Nothing else references it.

## The `RESULT` line

One JSON object, the last line of output, authoritative whatever the exit code:

```
RESULT {"result":"all-posted|proceed-p95|timeout|gh-unavailable","elapsedSeconds":300,"pollCalls":6,
        "sinceReviewId":5036760738,
        "responded":[{"graphqlBotId":"…","reviewId":…,"submittedAt":"…","latencySeconds":156}],
        "nonResponders":[{"graphqlBotId":"…","name":"Copilot","waitedSeconds":300,"boundSeconds":300,"boundSource":"learned-p95|pollTimeoutMinutes|fixed|gh-unavailable"}],
        "notRegistered":[…],"rejectedSamples":[…],"cacheState":"warm|cold|corrupt|unwritable"}
```

Exit 0 on `all-posted`, 3 when any reviewer did not respond (`proceed-p95`, `timeout`,
`gh-unavailable`), 2 on a usage error. `proceed-p95` and `timeout` are both this-run degradation
and are reported the same way: every non-responder by name in the step-8 report. A review that
lands after the proceed is caught by the paginated zero-unresolved checks in steps 7 and 8 —
the same exposure a timeout always had, reached sooner. Three consecutive `gh` failures end the
wait as `gh-unavailable`; a single failure is one missed tick.

## The `doctor` line

`doctor` §2 reads the cache and prints, per reviewer id: sample count, p50, p95, and the bound
`review` would derive under this repository's `pollTimeoutMinutes` — or
`cold — the wait uses pollTimeoutMinutes` when there are fewer than 5 samples. Informational.

## Extending the tests — the `--dry-run` fixture

`--dry-run FIXTURE.json` replaces the clock and `gh` with canned data; no sleep, no network:

```json
{ "now": "2026-01-01T10:00:00Z",
  "timeline": [ { "event": "review_requested", "created_at": "…", "requested_reviewer": { "node_id": "BOT_…", "login": "…" } } ],
  "reviews":  [ { "id": 50, "user": { "node_id": "BOT_…", "login": "…[bot]" }, "submitted_at": "…" } ],
  "failTicks": [0, 1, 2] }
```

The clock starts at `now` and advances by each sleep. A review becomes visible once the clock
reaches its `submitted_at`. `timeline` is used only to resolve a `registeredAt` the caller
passed as `null`. `failTicks` lists the zero-based fetch indexes that return nothing, for the
`gh-unavailable` path. `scripts/tests/wait-for-reviewers.sh` has one case per rule above.
