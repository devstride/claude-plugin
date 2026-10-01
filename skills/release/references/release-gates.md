---
load: rationale
---
# Release gates — why they are local, and what the head SHAs protect

The rules live in the `release` body; this file holds the reasoning, read when a pre-ship check
is red, when the head advanced by anything other than this run's fix commits or a hotfix merge, or
before waiving a check.

## Why pre-ship suites are local and never in CI

`preShipChecks` entries are suites the repository deliberately keeps out of the pipeline (cost,
wall-clock — the config's `_preShipChecks_readme` records each repo's reason). Nothing in CI
covers them, so an absent CI check for one is EXPECTED and CORRECT, never pending. Local gating
did not lower the bar; it MOVED it: a regression in one of these suites reaches production
unnoticed unless the release runs them — which is why step 2b is mandatory rather than
advisory, why entries run unconditionally at the release boundary (path arguments are exactly
what the rule overrides), and why "covered by CI" is the one false assurance never to give an
owner. If a cloud job is ever restored for such a suite, its `verify.skipDuringStoryBuilds`
entry and workflow job are added together and the `preShipChecks` entry dropped — otherwise it
runs twice.

## Why `<sourceHead>` and `<reviewedHead>` are immutable SHAs

The release PR's head IS a branch — the release source, or a release branch cut from it — so the
tip and "the PR head" move together; comparing them to each other proves nothing. Every integrity
check therefore compares against a value captured once: `<sourceHead>` (the SHA the delta was
computed from, a release branch's cut point) and `<reviewedHead>` (the SHA the review settled on).
Nothing holds the head still, so a human merge or direct push can advance it mid-review — and a
review that settled on a head that no longer exists describes a diff nobody is about to merge. On a
release branch two advances are expected and each is re-reviewed before it counts: this run's own
fix commits and a hotfix merge of the production branch. The one tolerated advance is `review` 7.3's single empty
re-trigger commit: its tree equals the settled tree, so the review still describes the merged
code. Anything else means the reviewed diff is stale and CI re-ran on a diff nobody reviewed —
back through step 2, never merged over.

## Why there is no freeze

Earlier versions froze the release source from the ready-flip to the merge, because with the
source itself as the head every merge beneath a ready release PR re-ran its CI and staled its
reviewed diff. The freeze stopped all other work for the length of a release, and it still let a
merge slip in before the flip. A release branch removes the cause instead: merges into the source
no longer touch the release PR at all, and they ship in the next release. A repository that keeps
releasing from the source itself gets no freeze either — a merge beneath its release PR advances
the head, and the head check sends the review round again, which costs one more pass rather than
blocking everyone.

## Why the review scopes to the release surface

Every constituent epic and story was already fully reviewed at its own PR into the development
branch, so re-reviewing unchanged approved code buys nothing. What per-PR review could not see
— cross-epic interactions, and anything in the release range that was not its own reviewed PR
— is the release review's actual surface. The pre-ship checks stay non-negotiable whatever the
review scope turns out to be.

## Cited by

- `skills/release/SKILL.md` — step 2's pointer ("Read … when a pre-ship check is red, when the
  head advanced by anything other than this run's fix commits or a hotfix merge, or before waiving
  a check").
