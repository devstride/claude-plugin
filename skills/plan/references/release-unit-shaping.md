# Release-unit shaping — why the boundary rules are what they are

The rules live in the body's step 2; this file holds the reasoning, read when proposing the
release-unit breakdown or when a user asks why a boundary is wrong.

## Why vertical value slices

The release-unit item is a MECHANICAL release boundary, not just a conceptual one: the delivery
loop gives each release unit its own integration branch, batches its story merges onto it, and
when the last story lands cuts the branch → develop release PR through the full review loop. So
when a release unit's leaves are all Done it SHIPS as one reviewed increment — which is why it
must deliver real, end-user-visible value ON ITS OWN (a develop merge of "nothing usable yet"
is a pointless release). Every release unit costs a full review: too many micro release units
create release overhead, a mega one becomes a long-lived branch drifting from develop.
Horizontal technical layers each ship nothing usable alone; a foundation that genuinely must
precede value belongs INSIDE the first value-delivering release unit that needs it, as its
early stories — and one that truly fans out to several release units is marked an explicit
internal enabler, a deliberate exception rather than the norm. Hence the shaping question: "if
we shipped only this release unit and stopped, what can the end consumer now do?" — "nothing
yet" means the boundary is wrong.

## Why production-safety questions belong in planning

Where promotion of the release source to production is frequent (daily or on demand), there is
no soak period and no later tidy-up window: the moment a release unit merges to the development
branch it reaches real customers within hours. A leaf is free to be half-built on the
integration branch; the release unit is not when it leaves. That is why the three questions —
blast radius (who is exposed day one, and what gates it), billable/account-global/externally
visible infrastructure (an owner decision, not a footnote in a bill), and intra-release-unit
deploy ordering (a stack naming a handler a later leaf creates fails the deploy for everyone) —
are asked while SHAPING, and their answers land in the release-unit spec's Release-safety
section, where the delivery loop meets them at the release gate instead of rediscovering them.

## Why deferred work never parks under a value release unit

Deferred enhancements, tech debt, compat-shim removals and "harden later" items under a value
release unit stop it ever reaching zero remaining leaves, so its release can never cut — and
under frequent promotion that means the release unit never ships or someone hand-waves a
partial release. A dedicated deferred/cleanup release unit holds them, `blocked_by` edges
pointing back at the release unit that produced them (a later unit depending on an earlier one
is the normal direction). A leaf whose theme does not match its release unit is a rehoming
signal, not a naming problem.

## Cited by

- `skills/plan/SKILL.md` — step 2's pointer ("Read … when proposing the release-unit breakdown,
  or when a user asks why a boundary is wrong").
