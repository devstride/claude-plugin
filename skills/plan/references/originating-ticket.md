---
load: contract
---
# Originating ticket — linking a Service Desk ticket to planned work — CANONICAL

The single authoritative procedure for recording which Service Desk ticket a piece of planned work
came from. The planning skills apply it by citation at the step that names it and restate nothing.
The link is an `originating_ticket` relationship from the planned item to the ticket, so a later
reader (a person, `comprehend-plan`, or a repository's own release follow-up) can find the
customer request behind the work without searching for it.

## The argument

- **`--ticket <ticket number>[,<ticket number>]`**, anywhere in the skill's arguments (for example
  `/devstride:create-story --ticket I1234 add CSV export to the audit log`). Several tickets are
  separated by commas, with or without a space after each.
- **Take it out before reading the rest.** Remove the flag and its numbers from the arguments
  first, so a ticket number is never read as the parent item, the description or a profile word.
- **Absent → this file does not apply.** No ticket is inferred from the description, a comment or
  the conversation; only a number the person passed is linked.

## Verify before any write

Before the item it links is created (`plan`: at step 0, before anything is written), read each
ticket with `get_item` and `fields: ["number", "title", "requesterId", "status"]`:

- **`requesterId` set** → a Service Desk ticket; keep it.
- **No `requesterId`, or the item does not exist** → say so in plain words (`<number> is not a
  Service Desk ticket, so it will not be linked`) and drop it. The rest of the run goes on; a typo
  is the person's to correct, never guessed at.

## Which item is linked, and when

| Skill | Item linked | When |
| --- | --- | --- |
| `plan` | the parent item it plans under (the plan root) | once, at step 0 — the only write before step 2's hierarchy sign-off |
| `create-story`, `create-defect` | the item ONE-OFF step 1 creates | right after `create_item` returns its number |
| `insert-story`, `insert-defect` | the leaf step 3 creates | right after `create_item` returns its number |

DEFERRED placement (`create-story` / `create-defect` `deferred <item#>`) links nothing: a parked
follow-up is not the work the customer asked for. A `--ticket` given there is reported as not
used. Each ticket is linked to ONE item per run; it is never copied onto containers the skill
creates on the way.

## The write

- One `add_relationship` per ticket: `itemNumber` = the linked item, `type: "originating_ticket"`,
  `target` = the ticket.
- **Already linked** → skip it. Before writing, read the linked item's `relationships`
  (`get_item` with `fields: ["number", "relationships"]`); an entry with `type`
  `originating_ticket` and `referenceId` equal to the ticket means the link exists (a re-run of
  `plan` on the same root finds it there).
- **The relationship type is rejected** — the tool's own schema has no `originating_ticket` value,
  or the server answers that the type is unknown or invalid (an older DevStride) → say ONCE per run
  that this DevStride does not support linking an originating ticket yet, name the tickets that
  were not linked, make no further link calls in this run, and carry on with the skill. Never
  substitute another relationship type (`related_to` and the scheduling edges mean something else
  to every other skill).
- **Any other refusal** (permission, a missing item, a validation message) → show it as the server
  worded it, name the ticket, and carry on; the created item stands.
- The skill's final report lists each ticket as linked, already linked, or not linked with the
  reason.

## Reading the links

An item's `get_item` with `view: "full"` (or `fields: ["relationships"]`) lists its relationships
as `{type, entity, referenceId}`. Its originating tickets are the `referenceId` of every entry whose
`type` is `originating_ticket`. To report a ticket's state, read it with `get_item` and
`fields: ["number", "title", "status"]`. Reading never writes: a missing or broken link is reported,
never repaired from a read-only skill.

## Cited by

- `plan` SKILL.md step 0, Hard floors and step 2's root marker
- `create-story` SKILL.md argument and step 1
- `create-defect` SKILL.md argument and step 1
- `insert-story` SKILL.md argument and step 3
- `insert-defect` SKILL.md argument and step 3
- `comprehend-plan` SKILL.md steps 2 and 3
