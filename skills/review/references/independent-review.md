---
load: contract
---

# The independent pass (review step 7.1a)

With `review.independentReview` set, on the final head and before anything else in step 7, run once,
in the background:

    python3 ${CLAUDE_PLUGIN_ROOT}/skills/review/scripts/independent-review.py <pr> <head>

It starts the review workflow only when this commit has no result, and can never produce a pass
itself: the workflow runs from the production branch under an identity the builder cannot use.

- `PASS`: continue.
- `WITHHELD`: its findings are verified findings of this cycle. Take them through steps 3 to 6.5 and
  come back here on the new head; a verified P1 or serious P2 falls under step 5's safety rule.
- `ERROR`: STOP for the owner and name the run. The reviewer did not answer, which is never a pass.
- `OFF`: continue.

It replaces no local round and adds none of its own, since a result already on this commit is reused.
