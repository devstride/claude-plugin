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

## Cited by

- `build-item` SKILL.md step 0 (canonical owner — selection)
- `insert-story` SKILL.md steps 1, 3, 5
- `insert-defect` SKILL.md steps 1, 3, 5
- `comprehend-plan` SKILL.md step 3
- `plan` SKILL.md step 6.5 (the execution-order walk)
