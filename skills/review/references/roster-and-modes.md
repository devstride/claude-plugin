# Roster and modes — the reasoning and the reference tables

The rules live in the `review` body; this file holds the fully-configured roster table, the
mode rationale, and the evidence behind the poll shape — for a run whose roster resolved to
fewer engines than the config declares, or for whoever changes a mode definition.

## The fully-configured roster

| engine | where | effort |
| --- | --- | --- |
| Claude adversarial | pre-PR (`ultracode-build` phase 3) on the `build-item` story path; otherwise step 1 runs it in `review` | `effort: 'max'` |
| Codex CLI | local, this worktree | `xhigh` (in `review.localCommand`) |
| Copilot | cloud, on the PR | — |

Standalone `/devstride:review`, human-driven `/devstride:pr`, hotfixes and `/devstride:release`
never invoke `ultracode-build`, so on those paths no Claude pass has run when `review` starts —
which is why step 1 establishes which case it is in rather than assuming the pass "already ran".

## Why `localCommand` names the engine but does not schedule it

A present `localCommand` puts the engine on the roster for every PR-path review under every
profile — the release PR, a one-off, a hotfix — because those paths have no later gate behind
them. The profile's `localCliEngine` and `maxLocalReviewRounds` schedule it only on fast-mode
STORY reviews, where the epic release PR still puts the cloud roster and CI over the same code.
Zero story rounds under `prototype` is therefore a profile choice, not a degradation: the engine
never left the roster, it simply does not run on that story. The contract file
(`delivery-profiles.md`) states this; the body cites it rather than restating it, because a
restated rule drifts.

## Why `prototype` ignores the draft hold on a release PR

The three CI-ordering booleans record what the repository's workflows SUPPORT — `setup` writes
them as detected facts under every profile. `prototype`'s `releaseCiOrdering` chooses not to USE
the hold on a release PR: CI runs concurrently with review there, whatever the booleans say,
because that profile trades the run-once guarantee for wall-clock. The knob is scoped to the
release PR by the contract; per-story, one-off and hotfix PRs keep the configured hold, since
their own PR is their only cloud gate. A PR still a draft on entry in that regime has CI held
for no reason — hence step 0's immediate flip.

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
every review stream, re-request every cloud reviewer, and re-run step 6.5 — whose
at-most-once-per-cycle rule exists precisely to stop a re-matched finding inflating
`recurrences` and corrupting the store's eviction order. The lessons tally from the held
invocation carries into the resumed one's report rather than being recomputed, for the same
reason.

## Cited by

- `skills/review/SKILL.md` — the pointer after the roster announcement ("Read … when a roster
  resolves to fewer engines than the config declares, or before changing a mode definition").
