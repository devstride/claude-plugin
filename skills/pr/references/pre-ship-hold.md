# The pre-ship hold — why the order matters

Order is the whole point: the pre-ship suites must test the same diff the reviewers settled and
CI is about to run. Let the flip happen first and a red pre-ship check forces a fix onto an
already-reviewed, already-CI'd PR — the fix reaches CI having passed no reviewer.

Holding when nothing will run buys a pointless round trip: a repo can have several
`preShipChecks` entries while this PR matches none — a frontend-only diff against path-scoped
suites, or entries that are all `releaseOnly` — and 2b is then a documented no-op.

A declared hold that is never discharged is a stranded PR — permanently draft, CI never
released — and the caller above (`build-item`) then refuses to merge it with no explanation:
from its side the PR simply never became ready.

## Cited by

- `skills/pr/SKILL.md` step 2.
