---
load: contract
---
# The story risk check — a bounded check of one built story before it is reviewed

`risk-check`'s whole procedure, run on the build engine's finished branch, before the local checks
and the review. Invoked by the Build workflow, or by hand after `ultracode-build` standalone.

## Floors — no profile, override or caller removes these

- **The immediate-risk verifier and mandatory lenses fire from the DIFF**, not the plan's theme,
  under every profile — `extended` included — and no override removes them.
- **Verified P1 and serious-P2 findings are always fixed** — no numeric cap; a stall STOPS for
  human help (`RISK CHECK: BLOCKED`).
- **Config wins**: `review.localAssistCommand`, `review.mandatoryLenses`, `commitConventions`,
  `generated.*`, `profile` and `profileOverrides` come from `.claude/ds-config.json`; the profile's
  `fixFloor` from `${CLAUDE_PLUGIN_ROOT}/skills/plan/references/delivery-profiles.md`, as passed.

## The check

Inspect the hand-written diff against the working base once, generated files excluded. This is a
bounded story check; the full merge-boundary pass uses
`${CLAUDE_PLUGIN_ROOT}/skills/ultracode-build/references/review-fanout.md`.
`review-moment: release-deferred` means a fast story whose complete finder/verifier and
configured-engine pass waits for the release PR's full diff; `review-moment: pr-boundary` means
`review` runs it on the direct story PR next; no marker (standalone) → this check plus a report of
the missing caller context — never guess that a full review happened.

- **Every story** gets a main-agent self-check: acceptance-criteria match, correctness at changed
  boundaries, meaningful negative tests, repo conventions, needless custom machinery or duplication.
  Lessons apply as hypotheses. A routine diff: fix what it finds, launch no generic fan-out.
- **Immediate risk floor.** When the DIFF touches authentication/authorization, a migration or
  irreversible state transition, or a deployed-runtime contract (including migration and durable-
  event safety under a rolling deploy), name the files and risk and launch one
  focused `opus`/`xhigh` verifier per independent boundary, maximum two — grouping related ones, dropping
  none. It tries to reproduce a concrete failure, checks the matching security/deploy invariant and
  returns anchored findings as CONFIRMED / PLAUSIBLE / REFUTED; REFUTED is the default and "could
  not rule it out" is not evidence. The profile cannot remove this floor. Each boundary is one
  entry of the proof's `triggers`, and the proof's `verifiers` counts the verifiers launched.
- **Mandatory lenses.** A `review.mandatoryLenses` entry whose `paths` match a hand-written file
  is an immediate-risk boundary of its own: one focused verifier carrying its `name` and
  `question`, even on a routine diff, reported as `mandatory lens <name>: ran (N findings)`; an
  unmatched entry is not mentioned; a malformed one is named once and ignored. Read
  `${CLAUDE_PLUGIN_ROOT}/skills/ultracode-build/references/mandatory-lenses.md` when one matches.
  It is a `lens:<name>` trigger, and its name joins the proof's `lenses`.
- A configured `review.localAssistCommand` may take one read-only call, concurrently, on a distinct
  risk question — advisory, never a second mandatory pass.
- **Ids** `F1…Fn` follow `review-fanout`'s fingerprint/occurrence rule, keeping every source and
  anchor; a security duplicate keeps its classification. A verdict from a browser, service or
  manual run names the path exercised and those not exercised — never a bare "verified".
- **Universal fix floor.** A verified P1 or serious P2 (defined in `review-fanout`) is fixed, its
  affected checks rerun, and a focused verifier re-run with the cumulative story ledger until a
  pass finds none — no numeric cap. No patch change, no progress or an unavailable verifier while
  one remains STOPS for human help. Then the profile's `fixFloor`: **`p1-security`**
  (`prototype`) — P1 correctness and any security finding, the rest routed by the next
  bullet; **`likely-important`** (`standard`, `extended`) — findings both likely and material (a
  security finding is material by definition), the rest dismissed with a one-line rationale;
  **`all-confirmed`** (override) — **fix every CONFIRMED and PLAUSIBLE.**
- **Nothing is silently dropped**: an unfixed finding worth filing (a P1, a security finding, or
  one both likely and material) is DEFERRED — with a home (a tracked downstream item or this
  story's intentional seam: rationale + owning item) or, with no home, on the **untracked-deferral
  list** for `capture-findings`; any other is DISMISSED with its reason, never filed. Drop
  REFUTED. Commit fixes per `commitConventions.reviewFixFormat` (fallback
  `fix(<scope>): <summary> [<itemNumber> review]`), regenerating artifacts if routes changed. A genuinely ambiguous risky finding is asked about,
  with a recommendation (`RISK CHECK: NEEDS DECISION <question>`; an unattended loop applies
  `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/needs-you.md`). Asked again with the person's
  `answer`, apply it and finish the check.
- **Story review ledger**: item-number namespace, base/head SHA, risk and files, each finding's
  id/fingerprint/anchors/claim/verdict/disposition, checks rerun, any local-assist conclusion. The
  later review receives it and may challenge it, but never rediscovers or reverses a settled finding
  without new evidence.
- **Risk-check report**, one line: profile, review moment, routine vs immediate-risk, agents used
  (normally zero; focused verifier count when required), matched lenses, raised/fixed/deferred/
  dismissed totals.

The local checks run after this step, once, on the final tree: a fix made here reruns only its
affected checks.

## Cited by

- `skills/risk-check/SKILL.md` — the pointer before inspecting the diff ("Read … in full before
  inspecting the diff").
