# Phase 3 fan-out — sizing examples, lesson routing, verification mechanics

`ultracode-build` phase 3 keeps only its rules in the body. This file holds the reasoning and
the worked examples behind three of them: what each breadth looks like, why lessons are routed
the way they are, and how a "verified" claim is kept honest. Nothing here changes a rule; if
the body and this file disagree, the body wins.

## What each breadth looks like

- **NARROW** — a one-liner, a copy tweak, a rename, a config flip. One or two finder lenses
  (correctness, plus conventions when the diff touches styled or typed frontend code), batched
  verification. It is cheap; skipping it is what costs. The security lens joins when the diff
  touches the auth boundary — an addition to NARROW, not a step up in size.
- **CONTAINED** — one subsystem, no deployed-runtime contract change, no new permission surface:
  a CLI verb, a test harness, a self-contained few-hundred-line refactor. Two or three lenses
  chosen for the diff's real risk; verification batched one verifier per finder's list. Half a
  dozen agents, not twenty-five.
- **HIGH-RISK** — cross-module contracts, deployed handlers or routes, migrations, a permission
  or security surface, event reshapes, anything the deploy-safety contract flags. All five
  lenses; verification grouped by file (below).

Unsure → one size up, never past the profile's ceiling. Where the contract lets a ceiling rise
for one story (a diff that itself touches an auth boundary or a migration) that is the contract's
exception, read there — not a judgment call made here.

## Why verification is grouped by file at HIGH-RISK

Per-finding verification at HIGH-RISK was the loop's largest single fan-out: five finders produce
twenty-odd findings on a real diff, and each got its own `effort: 'max'` verifier — the
"twenty-five" the CONTAINED bullet contrasts itself against, paid on every story that warranted
HIGH-RISK. Most of those verifiers were reading the same file. One verifier holding the findings
anchored in one file (or a small, related set) reads that file once and returns a verdict per
finding; the verdicts are no weaker, because the standard is per finding — REFUTED unless
reproducible, one entry per id — and the orchestrator rejects a return that collapses a group
into one verdict or misses an id, re-running that group per finding.

The grouping is computed, never judged: `scripts/group-findings.py` buckets by anchor file,
splits buckets above `maxFindings` (5) in id order, and packs buckets greedily — smallest first,
preferring files from one directory — into groups of at most `maxFindings` findings and
`maxFiles` (3) files. Sorted output, so the same findings in any order yield the same groups and
the same count in the report. `profileOverrides.verificationGrouping: "per-finding"` restores
one verifier per finding; there is no separate config key.

**An auth-boundary finding is never grouped** — one that the security lens raised, or whose
anchor file is one the diff's auth-boundary decision named. It gets its own verifier at every
breadth and under every grouping, including CONTAINED's per-finder batching and NARROW's
batched verification: that is Floor 2 of the profile contract, a floor rather than a default.

Grouping decides WHO verifies, never what may be read: a finding whose cause lives in another
file is grouped by its anchor, and its verifier reads whatever it needs. Lesson-derived findings
are ordinary findings with ids and go through the same grouping. Duplicate claims from two
finders on one line are deduplicated on the claim before ids are assigned; grouping never
merges distinct claims. A group of one is per-finding by construction.

Without `python3` (a broken machine — the version hook already needs it), group by hand by the
same rule and say so in the report; the rule is in the body, the script is mechanics.

## Why lessons are routed the way they are

Each finder gets the lessons that match its angle as additional named checks. Routing is a
judgment read from each lesson's Pattern text — the schema records a curation class
(`repeat` / `general` / `common`), never an angle, so there is nothing to look up. A lesson whose
Pattern matches no lens provisioned for this story is dropped for this build, by design: at
NARROW or CONTAINED most angles have no finder at all, and the lesson has already done its main
job as a phase-1 constraint.

Two guardrails, both load-bearing. Lessons EXTEND a finder's checklist and never narrow it: a
finder that tunnels onto lesson patterns and misses a novel defect has done the opposite of its
job. And a lesson-derived finding goes through Stage B verification like any other, with a
concrete `file:line` claim about THIS diff — a lesson is a hypothesis about where defects
cluster, never a verdict. No lessons file → the finders' base checklists are the whole story.

## Keeping "verified" honest

A verdict that rests on having looked — a browser, a running service, a manual run — names the
path it exercised: "verified X via path Y", never a bare "verified". Behavioural states are
usually reachable by more than one route (a second navigation route, a fresh tab, a keyboard
shortcut, a retry), and a fix confirmed on one has proven nothing about the others; a reviewer
later finding an untried path is the process working, not a surprise.

Assert what you are measuring. Scope DOM or API queries to the live container and check its
count: a stale mounted panel or a cached response answers with equal confidence and makes a
broken state read as a pass, or as a different bug. Use one clean load per case — in-place
navigation lets cases bleed into each other. And a stale session, an expired login or a service
that is not up looks identical to a broken feature: rule those out before reading code.
