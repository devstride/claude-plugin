# Roster and modes — the reasoning and the reference tables

The rules live in the `review` body; this file holds the fully-configured roster table, the
mode rationale, and the evidence behind the poll shape — for a run whose roster resolved to
fewer engines than the config declares, or for whoever changes a mode definition.

## The fully-configured roster

| engine | where | route |
| --- | --- | --- |
| Claude adversarial | a risk screen on a release-deferred story; otherwise step 1 at the PR boundary | task/risk model alias and effort from `delivery-profiles.md` |
| Local CLI | local, read-only in this worktree | `<effort>` from the same route; operator/managed config chooses its model |
| Copilot | cloud, on the PR | — |

Standalone `/devstride:review`, human-driven `/devstride:pr`, hotfixes and production releases
do not arrive with a PR-boundary Claude pass. Fast story work arrives only with its local risk
screen; the epic release is its first full adversarial pass. Step 1 therefore resolves the review
moment and reviewed-head ledger instead of assuming that any earlier Claude work covered this
scope.

## Why `localCommand` names the engine but does not schedule it

A present `localCommand` puts the engine on the roster for every PR-boundary review under every
profile — release PR, one-off and hotfix. Fast-mode stories defer that full pass to the epic
release; an optional `localAssistCommand` may still provide one targeted, read-only second opinion
for ambiguous or critical work. `maxLocalReviewRounds` is subordinate to the normal
`targetAdversarialCycles`; verified P1/serious-P2 safety cycles override both. Neither schedules a routine extra story review. The contract file
(`delivery-profiles.md`) states this; the body cites it rather than restating it, because a
restated rule drifts.

## Why every profile keeps CI last

The three CI-ordering booleans record what the repository's workflows SUPPORT — `setup` writes
them as detected facts under every profile. No delivery profile bypasses a supported hold: a
prototype release that starts CI beside review often pays for a second run after the first fix,
which is slower as well as more expensive. Where pull-request workflows exist but are not
draft-gated, setup/doctor report the loop as not optimized and point to `/devstride:setup ci`;
the review cannot manufacture a hold that the workflows do not support.

## Why the poll is one background script call

The wait is a single self-terminating background `Bash` call running `wait-for-reviewers.sh` —
not a Monitor, not re-armed wakeups, not `gh pr checks --watch`, not a foreground sleep. The
harness suggests Monitor for waiting on a condition; here it is the wrong shape: the wait needs
server-timestamp bookkeeping, a learned per-reviewer bound, and one authoritative RESULT line
the resumed turn can parse — state a Monitor cannot carry. Re-armed wakeups poll at the
harness's cadence, not the backoff's, and a foreground sleep blocks the local triage work that
should overlap the wait.

## Why LOCAL-ONLY must write lessons, and PRE-SHIP RESUME must not restart

Under fast develop mode most story findings only ever exist locally — no PR, no thread, no
cloud pass. A lessons writer that ran only on the PR path would therefore starve the store of
exactly the findings the loop sees most, which is why LOCAL-ONLY's step 6.5 write is a MUST
even on a Claude-only roster, and why callers invoke the mode even when no CLI engine is
configured.

PRE-SHIP RESUME re-enters at 7.1 rather than step 0 because a fresh invocation would relaunch
every review stream outside the shared ledger/target and re-run step 6.5 — whose
at-most-once-per-cycle rule exists precisely to stop a re-matched finding inflating
`recurrences` and corrupting the store's eviction order. The lessons tally from the held
invocation carries into the resumed one's report rather than being recomputed, for the same
reason.

## Cited by

- `skills/review/SKILL.md` — the pointer after the roster announcement ("Read … when a roster
  resolves to fewer engines than the config declares, or before changing a mode definition").
