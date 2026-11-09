---
load: contract
---
# Honest estimates — no clock time before landing, a measured range after it, every quote scored

**Goal:** when someone asks when work will be live, the answer is usually right. Early estimates
that add up the release's own steps leave out the waits that make up most of the time (the wait
for the next release to start, test failures and reruns, the owner's go-ahead), so they run hours
optimistic. The fix is to quote only once work has landed, from the repository's own measured
history, as a range with a confidence, and to score every quote against what happened.

## The rule (every message, every skill)

- **Before work lands, never give a clock time or a duration for when it will be live.** Say which
  steps remain instead ("after review and its landing, then the next release"). Work has landed
  when it is on the release train (when one ships) or the release source; an epic's work lands
  when its release pull request merges, never at a story's merge onto the epic branch.
- **After it lands, quote only what `estimate.py quote` gives**: its range and its confidence,
  word for word, never a single time and never a narrower range. `NONE` means there is no honest
  range: say so and name the steps that remain. `LIVE` means it is already on the production branch.
- A quote is never improved by hand: an agent that knows of a release in progress says so beside
  the range, and the range stands.

## Quoting at landing

`python3 ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/estimate.py quote --sha <landing sha>` from
the repository's checkout, right after the landing is pushed: a one-off's merge onto the train or
the source (`build-item` step 6, `item-status.md`), or a release unit's release pull request merged
onto its release target (its merge commit; the quote goes on the release-unit item).

| Verdict | Exit | Then |
|---|---|---|
| `QUOTE` | 0 | `add_comment` on the item: "Estimate: <line>" and, on its own line, the token (second output line), verbatim; the recap's next-step line carries the range |
| `NONE` | 10 | no comment; the recap says no clock time yet and why |
| `LIVE` | 11 | no comment; say it is on production and waits only for its deploy |
| `ERROR` | 1 | say it once; no comment, no estimate |

Quote once per landing: the comment is the record, and a later question about the same work
re-runs `quote` (a new token, a new comment) only when the person asks for a fresh estimate.

## Scoring at the deploy

When `release` confirms the production deploy (`merge-and-deploy.md`, step 5a), for each item the
release shipped whose comments carry an `[estimate v1 …]` token and no `[estimate-score v1 …]` token
for the same `sha`: `estimate.py score --sha <sha> --quoted <quoted> --low <low> --high <high>
--live <the time the deploy was confirmed, UTC>`, then `add_comment` "Estimate scored: <line>" and
its token. `PENDING` or `ERROR` → no comment, said once. Scoring never blocks or delays a release.

## How the range is made

Every landing of the last 14 days, each with when it reached the production branch (or still
waiting, counted as at least that long), read from git alone, so every machine computes the same
range. The range is the 10th to the 90th percentile of the rest of the wait for work that has
already waited as long as this one, plus `release.estimates.deployMinutes` (default 0; the time
from the production merge to live). It measures every part of the path together: when the next
release starts (after the one in progress, or the backstop's limit), the train's tests and their
failures, the release steps, the golden route and the owner's go-ahead are all in the history.
Fewer than 8 comparable landings → `NONE`. Times show in `release.holdTimeZone`; tokens are UTC.

`estimate.py backtest [--days N]` replays the method over recent history (each landing quoted 5
minutes after it landed, from the history as it stood then) and says how many went live inside
their range. The target is 8 in 10: check it before relying on the quotes, and again when the
release rhythm changes.

## The record

The tokens are a contract for any tool that reports accuracy (a repository's own throughput
report, for one): `[estimate v1 sha=<12> quoted=<UTC> low=<UTC> high=<UTC> p=80 n=<landings>]`
and `[estimate-score v1 sha=<12> quoted=… low=… high=… live=<UTC> result=inside|early|late
minutes=<outside the range>]`, each on its own line in an item comment.

## Cited by

- `skills/build-item/references/plain-language-output.md` — Time estimates.
- `skills/build-item/references/item-status.md` — the landed event's quote.
- `skills/build-item/references/epic-release-steps.md` — the release unit's quote.
- `skills/release/references/merge-and-deploy.md` — step 5a's score.
