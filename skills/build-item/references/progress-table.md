# The progress table — worked examples and why it exists

The rules live in the body's Progress reporting section; this file holds the two worked tables
and the reasoning, for the first render in a session or a resume after a compaction.

## Why the table exists

The loop's position is otherwise recoverable only from prose, so a compacted or resumed session
has to re-derive where it is — and skill text remembered across a compaction is EXPIRED, which
makes the table the one durable, cheap statement of position. Observed live: a compacted session
kept re-requesting a review through a connector that had been disabled months earlier, waiting
out timeout after timeout, because the stale in-context copy won. A table row saying which
engine actually registered would have surfaced that in one glance.

## The PR-path shape (4b — develop-base stories and one-offs)

```
| Step | Status |
|---|---|
| 0 · Select | I20110 — one-off → base develop, no epic branch |
| Profile | standard — from `.claude/ds-config.json` (one-off: no root marker) |
| 1 · In Progress | ✅ |
| 2 · Branch | ✅ jane/03-14-26/I20110-… |
| 3 · Build + Claude pass | ✅ 1 finding fixed |
| 4b · PR + review + CI | #42 — draft, CI held (release is `review` step 7) |
| — Codex (local, xhigh) | ✅ 3 findings → fixed |
| — Copilot (cloud) | ⏳ request registered in timeline |
| 5b · Merge | — |
| 6 · Completion ritual | — |
| 6.5 · Findings filed | I20111, I20112 |
| 7 · Sync + close-out | — |
| 8 · Epic release | n/a — one-off |
```

## The fast-path shape (4a/5a) — deferred cloud rows stay visible

```
| Profile | standard — from the plan root I20100 (marker read with view: 'full') |
| 4a · Fast review (no PR) | epic branch — cloud gate deferred to step 8 |
| — Claude (build, max) | ✅ step 3, 2 findings fixed |
| — Codex (local, xhigh) | ✅ 4 findings → 3 fixed, 1 captured |
| — Local suites | ✅ green (storyVerify: standard) — file/test pass counts recorded in the commit body |
| — Copilot + CI | ⏸ deferred to the epic release PR (step 8) |
| 5a · Fast merge | ✅ merged --no-ff → jane/03-14-26/I20104-attachment-storage |
```

Without the deferred rows, "no Copilot row" is indistinguishable from "Copilot was forgotten".

## Why each rendering rule is shaped that way

- **Evidence, not intent** — the `requestReviews` mutation returns success while silently
  creating nothing, so a row saying "requested" launders the exact failure the row exists to
  surface; "request registered in timeline" states the observed event. Same for gates:
  "non-applicable (no path match, base develop, no label)" beats a bare "skipped".
- **Every configured engine gets its own row, an unconfigured one an explicit "not configured"
  row** — the engines run concurrently and are the part most easily assumed rather than
  verified; a missing row is indistinguishable from a forgotten engine.
- **A missing CI check is not a passing one** — `skipping` and "never ran" render identically in
  `gh pr checks`, so the row says which, and why.
- **One row per numbered step, in this skill's own names** — a row labelled for something the
  step does not do resumes at the wrong operation; CI release/settling belong to `review` step
  7, not to a row of their own. Step 8 stays `n/a` on a one-off so "absent" never has to be
  told apart from "not reached". The `Profile` row exists because a resumed session re-derives
  the review path and verify width from it.
- It is a status render, not a gate — it must never delay the step it describes.

## Cited by

- `skills/build-item/SKILL.md` — the Progress reporting pointer ("Read … when you render the
  table for the first time in a session, or when resuming after a compaction").
