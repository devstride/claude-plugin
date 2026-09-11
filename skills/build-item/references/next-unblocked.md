---
load: contract
---
# Next-unblocked selection — CANONICAL DEFINITION

The single authoritative rule for which item `/devstride:build-item` picks up next. Every skill that
selects, splices around, or reports "what runs next" applies THIS rule by citation — none
restates it.

## The rule

The next-unblocked item is: the highest-priority, not-Done leaf item (a `hierarchyRoles.leaf`
type — this org's Story/Defect) NOT `blocked_by` any still-open item, in the earliest-dated open
container (this org: Capability/Epic) on the critical path. Priority breaks ties; earlier
`startDate` breaks remaining ties. Exclude anything the gating check catches (`build-item`
step 0's GATING CHECK — items that depend on a human/infra decision that is the user's).

An item is unblocked when every `blocked_by` target is Done.

**Exclude everything under the deferred-defect container** — the container titled
`defects.deferredContainerTitle` that sits directly under the plan root and holds below-floor
review findings. Those items are tracked, not queued: they are never auto-selected, they never
count toward a remaining-leaf total, and the container is never a release unit. An item there
that the USER names explicitly by number is still built, as a one-off.

## Projection warning — fetch relationships EXPLICITLY

**Fetch each candidate's relationships EXPLICITLY** — `search_items` and the default `get_item`
summary both OMIT `relationships`, so a selection computed from them sees no edges at all and
will happily run blocked work out of dependency order. The edge graph + priority + dates then
suffice — reach for `/devstride:comprehend-plan` only when the plan's state is genuinely unclear.

## Worked consequence — priority alone cannot beat an earlier-dated open container

The rule sorts by earliest-dated open container FIRST; priority only breaks ties within that
tier. If a splice creates a brand-new container dated today while some OTHER open container
elsewhere in the plan started earlier and still has its own unblocked story, that story remains
ahead of the insert no matter how high the insert's priority is set. After any splice, re-derive
the pick with this rule against the current plan state rather than assuming the splice worked.

## Why the ready-set is shape, not a fan-out instruction

The ready-set this rule produces says which items COULD run next; it never says they may run at
the same time. Test execution is serial against shared test infrastructure — runners sharing
containers or databases corrupt each other's state — and a per-checkout instance
(`localEnvironment.instanceBoundTo: directory`) isolates dev servers and app data, NOT that
shared infrastructure. Add the dirty-tree abort in `branch-feature` and an MCP that writes to
production, and a concurrent loop has three ways to damage state for one saved hour. Surfacing
the ready-set lets a HUMAN fan the waves out deliberately; the loop itself stays serial.

## Cited by

- `build-item` SKILL.md step 0 (canonical owner — selection) and the "Serial by design" rule
  (the ready-set-is-shape reasoning)
- `insert-story` SKILL.md steps 1, 3, 5
- `insert-defect` SKILL.md steps 1, 3, 5
- `comprehend-plan` SKILL.md step 3
- `plan` SKILL.md step 6.5 (the execution-order walk)
