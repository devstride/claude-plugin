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

- Nearest-rank p95: `sorted[ceil(0.95 · n) − 1]`, ascending. On 12 samples that is index 11 —
  the largest; on 20 it is index 18 — the second-largest, so one outlier no longer sets the bound.
  Simple, no interpolation, no surprise on small rings.
- Slack 120 s: one maximum tick (90 s) plus a margin, so a reviewer that lands right at its p95
  is still caught by the next tick rather than declared a non-responder one tick early.
- The window is a FLOOR on the bound, never a drop trigger: dropping a reviewer for a missing
  registration is step 1's job, done before this script runs.
- A reviewer is frozen as a non-responder only on a tick that actually LOOKED (a fetch that
  succeeded) and found nothing at or past its bound — a failed fetch on that tick is one missed
  tick, and the next real look decides. A review that arrives after the freeze is still recorded
  as a sample (it is real latency) and reported under the non-responder as `respondedLate`, but
  it does not turn the result into `all-posted`.
- A review whose `submitted_at` predates the reviewer's `registeredAt` cannot be this request's
  answer: it neither settles the wait nor becomes a sample.
- **A learned bound that keeps being missed re-learns itself.** A shortened wait can never
  observe a reviewer that has slowed down — the loop exits before the late review arrives. So the
  cache counts consecutive misses at a learned bound (`consecutiveMisses`, reset on any response);
  at two, the next wait uses the full `pollTimeoutMinutes` (`boundSource: relearning`), sees the
  real latency, records it, and the p95 moves. Two shortened waits are the price of not being
  stuck; one would over-react to a single slow day.
- `timeout` vs `proceed-p95`: `timeout` whenever any non-responder ran to the full
  `pollTimeoutMinutes` (or the fixed bound); `proceed-p95` only when every non-responder was cut
  short by a learned bound — the result names what actually ended the wait.

## Why the samples come from server timestamps only

A sample is `submitted_at − registeredAt`, both ISO-8601 strings GitHub returned. It is never
the time at which a *tick* noticed the review. With a backoff the tick-observed latency is the
real latency plus up to one interval — and if THAT were learned, the p95 would inflate itself
through the very cadence it drives, lengthening every future wait. Server timestamps are the
only measurement the wait cannot contaminate. A sample below 0 or above 24 h is rejected and
the rejection printed (clock skew on the server side would be news worth seeing).

## Why the key is the GraphQL bot id

One reviewer, three spellings of its login depending on the endpoint — the timeline and
`/comments` say `Copilot`, `/reviews` says `copilot-pull-request-reviewer[bot]`, GraphQL review
threads say `copilot-pull-request-reviewer`. The `node_id` is the same everywhere — verified
live, `BOT_kgDOCnlnWA` on the timeline event and on the review object alike — so the ring is
keyed on it and a review is matched to its reviewer on `user.node_id`; `reviewsLogin` is a
fallback match only. The login table is in `github-review-api.md`.

## The cache

`${XDG_CACHE_HOME:-~/.cache}/devstride-plugin/reviewer-latency.json`, beside the version
check's `newest.json`:

```json
{ "version": 1,
  "reviewers": {
    "BOT_kgDOCnlnWA": {
      "samples": [ { "at": "2026-08-27T10:03:00Z", "latencySeconds": 156, "repo": "o/r", "pr": 12, "reviewId": 50 } ],
      "updatedAt": "2026-08-27T10:03:00Z" } } }
```

- A ring of **20** per reviewer, oldest dropped. Machine-wide on purpose: a reviewer's latency
  is a property of the reviewer, not of the repository; only the bound's *clamp* is per run,
  from that run's `pollTimeoutMinutes`, so one repository's ceiling never leaks into another's.
- **Advisory, never an error.** A missing file is cold. An unparsable file is `corrupt` and
  behaves cold. A directory that cannot be written leaves the state `unwritable` and the wait
  still exits normally. A write that cannot take the lock within five seconds is skipped
  (`locked`) rather than made unlocked. Every read and write is wrapped; the `RESULT` line's
  `cacheState` says which happened. The cache can only ever *shorten* a wait.
- `--fixed-bound` (the config key off) still records samples, so switching the key on later
  starts warm.
- A sample carries its `reviewId`; the same review seen twice (a re-invoked step 2) is recorded
  once. Writes take a short lock (`reviewer-latency.json.lock`) and re-read the file first, so two
  runs overlapping on one machine do not lose each other's samples.
- **Reset:** delete the file. Nothing else references it.

## The `RESULT` line

One JSON object, the last line of output, authoritative whatever the exit code:

```
RESULT {"result":"all-posted|proceed-p95|timeout|gh-unavailable|nothing-registered","elapsedSeconds":300,"pollCalls":6,
        "sinceReviewId":5036760738,
        "responded":[{"graphqlBotId":"…","reviewId":…,"submittedAt":"…","latencySeconds":156}],
        "nonResponders":[{"graphqlBotId":"…","name":"Copilot","waitedSeconds":300,"boundSeconds":300,"boundSource":"learned-p95|pollTimeoutMinutes|fixed|gh-unavailable"}],
        "notRegistered":[…],"rejectedSamples":[…],"cacheState":"warm|cold|corrupt|unwritable|locked"}
```

Exit 0 on `all-posted`, 3 when any reviewer did not respond (`proceed-p95`, `timeout`,
`gh-unavailable`, or `nothing-registered` — every reviewer passed lacked a `review_requested`
event, so there was nothing to wait for; step 1 should have dropped them), 2 on a usage error
(a non-numeric option, a bad timestamp, a malformed reviewers list — always a `RESULT` line,
never a traceback). `proceed-p95` and `timeout` are both this-run degradation
and are reported the same way: every non-responder by name in the step-8 report. A review that
lands after the proceed is caught by the paginated zero-unresolved checks in steps 7 and 8 —
the same exposure a timeout always had, reached sooner. Three consecutive `gh` failures end the
wait as `gh-unavailable`; a single failure is one missed tick.

## The `doctor` line

`doctor` §2 reads the cache and prints, per reviewer id: sample count, p50, p95, and the bound
`review` would derive under this repository's `pollTimeoutMinutes` — or
`cold — the wait uses pollTimeoutMinutes` below the sample minimum (5, the script's
`--min-samples` default). Informational.

## Extending the tests — the `--dry-run` fixture

`--dry-run FIXTURE.json` replaces the clock and `gh` with canned data; no sleep, no network:

```json
{ "now": "2026-01-01T10:00:00Z",
  "timeline": [ { "event": "review_requested", "created_at": "…", "requested_reviewer": { "node_id": "BOT_…", "login": "…" } } ],
  "reviews":  [ { "id": 50, "user": { "node_id": "BOT_…", "login": "…[bot]" }, "submitted_at": "…" } ],
  "failTicks": [0, 1, 2],
  "timelineFails": 3 }
```

The clock starts at `now` and advances by each sleep. A review becomes visible once the clock
reaches its `submitted_at`. `timeline` is used only to resolve a `registeredAt` the caller
passed as `null`. `failTicks` lists the zero-based fetch indexes that return nothing, for the
`gh-unavailable` path; `timelineFails` makes that many timeline reads fail first, for the
unreadable-timeline path. `scripts/tests/wait-for-reviewers.sh` has one case per rule above.
