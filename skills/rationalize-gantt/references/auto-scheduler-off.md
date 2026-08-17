# Organization-wide dependency auto-scheduler (Enable Link Mode) — CANONICAL RULE

The single authoritative rule for the auto-scheduler check that must precede any date or
dependency-edge write. Every skill that writes dates or `blocked_by`/`blocks` edges applies
THIS rule by citation — none restates it.

## The setting

DevStride has one global **Enable Link Mode** setting under **Settings → Organization**. It
applies across the organization; it is NOT scoped to a parent, roadmap, or individual Gantt
view. The organization projection exposes it as `enableStaticMode`: `false` means dependency
propagation is off; `true` means it is on. When on, the backend can **forward-reschedule items
that have `blocked_by` dependencies and OVERWRITE the start/due you set**, pushing dependents
far forward (observed all the way into 2027). It mutates the STORED data, not just a view.
Dependency-free roots keep their manual dates; dependent items can be moved.

## The check

READ the active organization first with `get_organization_metadata({include:"all"})` and
inspect `enableStaticMode`. If it is `false`, proceed without asking the user. If it is `true`,
ask the user to turn **Enable Link Mode** OFF in Settings → Organization. Never change this
global organization setting automatically just to run a planning skill.

## Probe-date verification

VERIFY propagation is off before mass-writing when the operation will touch existing dependent
dates: call `update_item` on one dependent item with a known date **without passing
`staticMode`**, then `get_item` it back. If the date held, restore its original date (again
omitting `staticMode`) and proceed. If it was overwritten, stop and have the user disable
Enable Link Mode in Settings → Organization.

## Omit `staticMode` from every write

A caller-provided `staticMode:true` overrides the disabled organization setting and RE-ENABLES
dependency propagation. Omit `staticMode` from every probe, date, and relationship write —
`update_item`, `add_relationship`, `remove_relationship`, and `bulk_update_items` alike — so
the disabled organization setting remains authoritative.

## Cited by

- `rationalize-gantt` SKILL.md steps 1 (canonical owner) and 6
- `plan` SKILL.md steps 2 (sign-off) and 5
- `insert-story` SKILL.md steps 4 and 5
- `insert-defect` SKILL.md steps 4 and 5
