# Merge-boundary adversarial review — CANONICAL PROCEDURE

Run the full adversarial pass once where a diff can merge into a protected or release branch:
the direct story PR, or the release-unit/production PR that batches fast stories. Do not repeat it
inside every fast story. CI follows only after the final review-settled SHA.

The consuming `review` skill resolves `reviewBreadthCeiling`, `verificationDefault`,
`verificationGrouping`, `fixFloor`, and `targetAdversarialCycles` from the delivery-profile contract.
Run the initial cycle on the full hand-written merge diff, excluding generated files. A permitted
follow-up uses the one effective full/delta scope from
`${CLAUDE_PLUGIN_ROOT}/skills/review/references/delta-re-review.md` and receives the ledger.

Use the model/effort and parallelism rules in
`${CLAUDE_PLUGIN_ROOT}/skills/ultracode-build/references/engineering-economy.md`.

## Task-sized breadth and routing

Clamp the diff's actual risk to the profile ceiling:

- **NARROW** — one subsystem with no deployed/auth/migration contract: one `sonnet`/`high`
  correctness-and-contract finder.
- **CONTAINED** — a cross-file subsystem change: `sonnet`/`high` correctness, contract, and tests
  finders; add one independent `opus`/`high` critic when a second view can change the result.
- **HIGH-RISK** — authentication/authorization, migration or irreversible state, deployed-runtime
  contracts, cross-module events, or production merge gates: focused finders plus an
  `opus`/`xhigh` verifier for each named high-risk boundary. The final release/production gate is
  always `opus`/`xhigh` even when the rest of the diff is narrower.

The ceiling clamps generic finder breadth only; it never removes a focused immediate-risk or final
merge-gate verifier.

Never default agents to `max`. The engineering-economy contract reserves it for an explicit,
evaluated override tied to a named unresolved risk. Prefer distinct questions and bounded
parallelism over overlapping generic lenses.

## Findings and verification

Each finder returns an anchor, mechanism, affected symbol/contract, expected effect, and lens.
The orchestrator assigns the ledger fingerprint from mechanism + affected symbol/contract + effect.
Matching fingerprints share one id only for the same fixable occurrence, retaining every source;
a separate occurrence adds its stable enclosing symbol/path discriminator. A security duplicate
keeps the security lens.

Use the five lenses only when the risk warrants them:

- **Correctness** — logic, edge cases, state transitions, error handling, races.
- **Security** — authentication, authorization, tenant scope, injection, secrets, ACL breadth.
- **Contract-match** — acceptance criteria and downstream/runtime contracts.
- **Tests / false-green** — assertions that cannot fail, mocked-away behavior, missing negative or
  alternate paths.
- **Cleanup / conventions** — binding repo rules, dead paths, unnecessary custom machinery, DRY
  and YAGNI.

Hand each finder only relevant lessons as additional hypotheses; lessons never replace the base
question or count as findings without an anchor in this diff.

Verify findings from REFUTED by default. A CONFIRMED verdict reproduces the failure; PLAUSIBLE
names the concrete mechanism and reachable path; "could not rule it out" stays REFUTED. Include
likelihood and impact. A security hole, data loss/corruption, broken acceptance criterion, or
deploy-blocking contract is P1. A **serious P2** is below P1 with both boolean facts true:
likelihood = likely **and** impact = material — exactly `likely-important`. Verified P1 and serious-P2 findings
are release blockers under every profile, before its additional `fixFloor` is applied.

At HIGH-RISK, group ordinary findings by anchor file with
`${CLAUDE_PLUGIN_ROOT}/skills/ultracode-build/scripts/group-findings.py` (at most five findings and
three files per verifier); at CONTAINED group by finder; at NARROW batch once. A security,
migration, irreversible-state, or deployed-contract finding always gets its own `opus`/`xhigh`
verifier: separate those ids before sending the ordinary remainder to the grouping script.
`verificationGrouping: per-finding` expands HIGH-RISK grouping only. Every verifier must return one
verdict per id. Retry one malformed group response once inside the current cycle, then record that
reviewer as degraded; never recurse on malformed output.

Act by `fixFloor`. Record every non-fixed actionable finding as deferred (with its owning item or
untracked tag) or dismissed with rationale; drop REFUTED findings. A behavioral verdict names the
path exercised and meaningful untried paths, never merely "verified".

## Cumulative ledger, target and safety continuation

Maintain the one cumulative ledger defined in
`${CLAUDE_PLUGIN_ROOT}/skills/review/references/review-ledger.md`; do not invent a parallel format.
Seed it with story-ledger evidence inherited from fast stories as well as this merge diff's scope,
SHAs, findings, dispositions, fix commits, checks, and reviewer-family results.

Every Claude, local CLI, cloud, rebase/pre-ship, and real-CI follow-up receives this ledger. A new
cycle inspects only the effective range plus unresolved entries; it does not reopen a settled item
without new evidence. For asynchronous cloud reviewers, publish the compact ledger to the PR before
requesting the follow-up review.

`targetAdversarialCycles` is two useful cycles across the whole merge gate, including rebase,
pre-ship and review-triggered real-CI repair rechecks. Beyond it, any newly verified P1 or
serious P2 requires fix + affected checks + another contextual cycle; repeat without a numeric cap
until the next cycle finds none. These safety cycles also override `maxLocalReviewRounds`, while
lower-severity findings cannot extend the target. No patch change, no progress, or an unavailable
required reviewer while one remains is a human gate — never re-review unchanged code or merge
unresolved risk. A clean cycle may finish before the target.

## Cited by

- `skills/ultracode-build/SKILL.md` — bounded story risk screen and deferred merge review.
- `skills/review/SKILL.md` — merge-boundary cycle routing, findings and follow-up.
