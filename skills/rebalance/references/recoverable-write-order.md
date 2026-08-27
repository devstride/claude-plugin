# The recoverable write order — why 3a→3f is ordered as it is

The rules live in the body's step 3; this file holds the reasoning, read before the first write
and when a run was interrupted mid-step 3.

## Duplicated work, never lost work

Create successors (3a) → wire their edges and detach the originals' (3b) → number (3c) →
archive (3d) → marker (3e) → re-date (3f). A run interrupted at ANY point in that order leaves
a plan with DUPLICATED work — an original and its successor both live — which the next run or a
human reconciles by inspection. Reordered (archive before wire, number before create), an
interruption loses an edge, a spec or an item with nothing pointing at where it went. That is
why the order is load-bearing and never compressed to save calls.

## The edge-translation worked case

An external endpoint can itself be an original absorbed by a DIFFERENT successor: A blocks B; A
merges into successor S1, B into S2. Written against the original B, S1's `blocks` edge is
deleted again by the detach pass and the cross-group dependency silently vanishes — so BOTH
endpoints translate through the global absorbed → successor map before writing, and only edges
whose endpoints resolve to two live items are written. For a split, an endpoint on the
`blocked_by` (downstream) side resolves to the FIRST part and a target endpoint to the LAST —
inbound work gates the first part, outbound waits for the whole chain.

## Why a merge set must be convex

If an outside item X sits on a path between two members (A blocks X, X blocks B, and A and B
merge), the successor is both upstream and downstream of X — a dependency cycle. Nothing errors
at write time; `rationalize-gantt` refuses to date the plan at 3f, after everything else has
been written. Fold X in or split the set at proposal time, where the fix costs nothing.

## Why the orphan gate excludes the absorbed originals

The detach pass makes every absorbed original edgeless ON PURPOSE, and 3d archives them —
counting them would fail the gate on every run that does anything. The live set (successors +
untouched leaves) is the bar: an untouched leaf whose only edge pointed at an absorbed item
must now have one pointing at the successor, and if it does not, the union was computed wrong.

## Why add-before-remove, and why archive-after-comment

Edges are added first and removed second so no live item is ever edgeless between the two
calls. Archiving does not detach edges — a live leaf left `blocked_by` an archived, never-Done
original can never unblock, and the loop reports the plan stuck without saying why. Each
original is archived immediately after its own pointer comment, one at a time, so an
interruption cannot leave an item archived without the comment that says where its spec went.

## Cited by

- `skills/rebalance/SKILL.md` — step 3's pointer ("Read … before the first write, and when a
  run was interrupted mid-step 3").
