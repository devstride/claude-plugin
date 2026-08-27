# Phase 3 fan-out — the reasoning behind the body's rules

`ultracode-build` phase 3 keeps its rules in the body. This file holds the reasoning and worked
examples behind four of them: why the pass front-loads the loop's quality budget, what each
breadth looks like, why verification is grouped by file at HIGH-RISK, and why lessons are routed
the way they are. Nothing here is a rule; if the body and this file disagree, the body wins.

## Why the pass is mandatory and front-loaded

The loop holds CI until review settles so the suite runs once, on an already-clean diff. That
only pays if the defects are found BEFORE the diff reaches CI — which is what this pass is for.
A skipped pass does not save the work; it moves the defect to the expensive, serialized part of
the pipeline (a CI loop-back, a cloud re-review, a fix pushed onto an already-reviewed PR), and
reviewing generated code spends the same budget on noise that no finder can act on.

## What each breadth looks like

The body's classification is the rule; these are the shapes it is describing:

- **NARROW** — a one-liner, a copy tweak, a rename, a config flip. Cheap to review; skipping it
  is what costs.
- **CONTAINED** — a CLI verb, a test harness, a self-contained few-hundred-line refactor: one
  subsystem, nothing a deployed runtime or a permission check depends on. Half a dozen agents,
  not twenty-five.
- **HIGH-RISK** — a cross-module contract, a deployed handler or route, a migration, a
  permission or security surface, an event reshape: anything the deploy-safety contract flags.

## Why verification is grouped by file at HIGH-RISK

Per-finding verification at HIGH-RISK was the loop's largest single fan-out: five finders produce
twenty-odd findings on a real diff, and each got its own `effort: 'max'` verifier — the
"twenty-five" the CONTAINED bullet contrasts itself against, paid on every story that warranted
HIGH-RISK. Most of those verifiers were reading the same file. One verifier holding the findings
anchored in one file (or a small, related set) reads that file once and returns a verdict per
finding; the verdicts are no weaker, because the standard is per finding — REFUTED unless
reproducible, one entry per id — and a return that collapses a group into one verdict, or
misses an id, is rejected and that group re-run per finding.

The grouping is computed, never judged, so the count in the report is reproducible:
`scripts/group-findings.py` buckets by anchor file, splits buckets above `maxFindings` (5) in
id order, and packs the pieces largest-first — first-fit, preferring a group that already holds
a file from the same directory — into groups of at most `maxFindings` findings and `maxFiles`
(3) files. Largest-first matters: packing small pieces first opens groups the large pieces can
no longer enter, which cost an extra verifier on roughly a quarter of random inputs. Every path
is normalised on both sides and every lens is validated, because a floor that fails open on a
capital letter or a `./` prefix is no floor. Sorted output, so the same findings in any order
yield the same groups.

Why an auth-boundary finding is never grouped: a security finding is P1 whatever its likelihood
(the fix floor says so), so it is the one class where a verifier's undivided attention is worth
its cost at every breadth — including CONTAINED's per-finder batching and NARROW's batched
verification. That is Floor 2 of the profile contract, a floor rather than a default. The
finding-level test has two halves because the security lens does not run at every breadth: a
correctness finding anchored in a file the diff's auth-boundary decision named is an
auth-boundary finding too, which is why the body has that decision NAME its files.

Grouping decides WHO verifies, never what may be read: a finding whose cause lives in another
file is grouped by its anchor, and its verifier reads whatever it needs. Lesson-derived findings
are ordinary findings with ids and go through the same grouping. A group of one is per-finding
by construction. The `per-finding` override exists for a repository that would rather pay the
old fan-out than trust the grouping; it is scoped to HIGH-RISK because that is the only breadth
the grouping changed.

## Why lessons are routed the way they are

The lessons schema records a curation class (`repeat` / `general` / `common`), never an angle,
so routing a lesson to a finder is a judgment read from its Pattern text — there is nothing to
look up. A lesson whose Pattern matches no lens provisioned for this story is dropped for this
build on purpose: at NARROW or CONTAINED most angles have no finder at all, and the lesson has
already done its main job as a phase-1 constraint. The two body imperatives guard the two ways
a lesson can do harm: a finder that tunnels onto lesson patterns misses the novel defect, and a
lesson treated as a verdict rather than a hypothesis "confirms" a defect nobody reproduced.

## Keeping "verified" honest — the mechanics

Behavioural states are usually reachable by more than one route — a second navigation route, a
fresh tab, a keyboard shortcut, a retry — which is why the body has you enumerate the routes and
name the untried ones; a reviewer later finding one is the process working, not a surprise. A
stale mounted panel or a cached response answers a broad DOM or API query with the same
confidence as the live one, which is why the query is scoped to the live container and its
count checked. In-place navigation lets one case's state bleed into the next, which is why each
case gets a clean load. And a stale session, an expired login or a service that is not up looks
identical to a broken feature, which is why those are ruled out before any code is read.
