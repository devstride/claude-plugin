---
load: contract
---
# As-built reconciliation — when a story ships differently from its description

**Goal:** the item's description says what was really built, and any spec linked to the item is
told, so no record falls behind quietly.

1. **Compose the as-built description** from the item's `view: 'full'` description: an italic
   as-built note, a **Deviations** list with one-line rationales, an **As shipped** summary.
2. **Send it with `record_as_built_change`** (`workItemNumber`, `newDescription: { html }`,
   `reason`). One call replaces the description, posts the before and after as an internal comment,
   and writes a note into every linked spec, live or as a proposed change where the spec's category
   needs approval.
3. **Word it for the spec's readers, who may be customers.** The note's summary is drafted from this
   description and `reason` goes in as written, so leave branch, commit, pull-request and tool names
   out of both. The completion ritual already points the item at its code.
4. **Report what did not update.** Name each returned spec left `out_of_sync` with its
   `skippedReason`, and `hiddenSpecsSkipped`. Never retry them: their watchers and author were told.
5. **Tool absent (an older server) or refusing (a ticket, an archived item):** `add_comment` the
   description verbatim under "📋 Original spec (as planned) — superseded by the description below"
   (HTML: pass `{ html }`, never Markdown), then `update_item` to the as-built text, citing the
   artifact that EXISTS (a pull request link; on the fast path, the merge SHA and branch).

## Cited by

- `skills/build-item/SKILL.md` — step 6, the completion ritual.
