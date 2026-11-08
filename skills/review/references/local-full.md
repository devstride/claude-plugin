---
load: contract
---
# LOCAL-FULL — the merge-boundary review on the landing machine

**Goal:** a one-off over the small-fix limit gets the same review a pull request would, before it
lands on the release train, with no pull request, no cloud reviewer and no CI run. The train's pull
request into the base stays the batch's one CI run (why: `release-train.md`).

**Entry:** `build-item` 4a, when `review-gate.py check` refuses, or a person or another tool running
`/devstride:review local-full <base>` in the story's checkout, where `<base>` is the ref it lands on
(`origin/<train>`). With no caller ledger, seed one from the story's commits and the item.

1. **Streams:** step 1's Claude adversarial route and the Local CLI engine, over
   `<base>...HEAD`, generated files excluded, with the matched mandatory lenses. No cloud request.
   With `review.localCommand` set, that engine failed or missing → STOP for a human, as step 1's
   Claude-only rule: `record` refuses a Claude-only LOCAL-FULL then, and `check` a receipt like it.
   Every cycle runs step 3's round first (`review-gate.py engine`, then `round`); a cycle in which
   no engine returned a result is FAILED: STOP, nothing is recorded.
2. **Settle:** steps 3–5: verify, triage, fix, with step 5's cycle target (two) and P1/serious-P2
   continuation without a cap. Then step 6.5, the lessons write. Steps 0, 2 and 6–8 never run: no
   thread, no flip, no CI.
3. **Record:** once every finding is terminal and the tree is clean, pipe
   `{base, cycles, engines: [{engine, result, reason?}], findings: [{id, severity, disposition,
   note?}]}` into
   `python3 ${CLAUDE_PLUGIN_ROOT}/skills/build-item/scripts/review-gate.py record`. Use `fixed`,
   `dismissed`, `refuted`, `deferred` or `captured`; each note is one line in your own words, never
   an engine's text. Each engine's `result` is its latest across the review (the last cycle it ran; a Claude-only
   follow-up keeps the CLI engine's earlier result): `findings`, `no-findings` or
   `failed` with a one-line `reason` (an `engine` answer of `returned` is read first, then mapped); `claude` and, with `review.localCommand` set, another engine
   must have returned one. Exit 2 → fix what it names. It writes a receipt for exactly this head, tree
   and merge base, kept under the repository's git directory on this machine.
4. **Return:** the triaged findings, the untracked-deferral list, the lessons tally, the cycle
   count, the reviewed head, and the gate's `mergeBody`.

**A later change to the patch** (a fix, or merging a moved train into the story) is a new head. Run
step 5's contextual follow-up on the delta with the ledger carried. A clean merge whose scope is
`none` spends nothing. Then **record again**: the gate admits only the head it recorded.
