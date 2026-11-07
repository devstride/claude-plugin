---
load: contract
---
# Release holds — work that must not ship yet

**A hold is data on the item, never memory or a message.** One line of the item's DevStride
description (usually the epic's), starting `Release hold:`:

- `Release hold: not before 2026-11-09` — lifts at 00:00 that day in `release.holdTimeZone` (an IANA
  name; absent: UTC), so every machine reads it alike.
- `Release hold: not before 2026-11-11T08:00-06:00` — an instant, with its offset.
- `Release hold: after I20101 is live` — until I20101 is deployed and checked: a commit naming it on
  `origin/<release.productionBranch>` whose production merge, or a later one, carries
  `release/post-deploy` success (`release.clearance.scope: cut-to-deploy`; other scopes count the
  merge, and say so).

A line that does not parse holds, naming the item and the line. Remove the line to lift a hold
early; that edit is the owner's record.

**The decision is code:** `python3 ${CLAUDE_PLUGIN_ROOT}/skills/build-item/scripts/release-holds.py
decide` with `{"items": [{"number", "description"}...]}`: the item and every ancestor up to the
root, each read with `get_item(view: 'full')`. Fetch the production branch first. It answers
`{held, holds, reason}`; exit 2 → treat as held and report its line. Fixtures beside it are the
cases any other tool must pass.

**Where it is checked:**
- `build-item`, before a one-off merges onto the release train or `baseBranch` (5a, or 4b's merge):
  held → no merge; the story branch waits, the item stays in progress, and the run reports
  "held: <reason>" and moves on.
- `build-item` step 8, before an epic's release is cut or merged: held → the epic waits on its
  integration branch, reported "release-ready, held until …".
- `release`, before the train snapshot (`release-branch.md` §1) and over the delta before the cut:
  the backstop. Held → STOP, naming the item, why, and how to take it out.

Time spent held is reported apart from build and review time.
