---
load: contract
---
# The deferred container — CANONICAL DEFINITION

One place holds a plan's deliberately postponed work: a container directly under the plan root.
Every skill that files into it, skips it, counts around it or dates it cites this file and
restates nothing. Why it sits beside the plan and is never a release unit:
`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/epic-release.md` ("Why deferred work lives
beside the plan").

## Finding it

- **Plan root.** `get_item` with `view: "full"` on the item the finding concerns, walking its
  hierarchy UPWARD to the top-most item under the portfolio. That root — not the item's own
  parent — owns the container.
- **Identity.** A DIRECT child of the plan root whose title, trimmed, inner whitespace collapsed
  and case ignored, equals `defects.deferredContainerTitle` (shipped default `Deferred`) or a
  legacy title: the built-in `Deferred defects` plus every entry of
  `defects.deferredContainerLegacyTitles` (shipped default `["Deferred defects"]`; a configured
  list only adds to the built-in). Exact after normalising: a title that merely contains the word
  is NOT a match, and an archived item never is. Matching an old NAME is the only legacy rule.
- **Never by eye.** List the root's descendants (`search_items` with `hierarchy: [root]`, every
  page), keep those whose `parentNumber` is the root, and pipe
  `{"title", "legacyTitles", "children": [{"number", "title"}]}` to
  `python3 ${CLAUDE_PLUGIN_ROOT}/skills/build-item/scripts/deferred-container.py match`. It prints
  `container` (the lowest matching number), `all`, `duplicates`, `matchedBy` and `create`.
  Membership: pipe `{"containers": <all>, "nodes": [{"number", "parentNumber"}]}` to the same
  script's `members`; every number it prints is in the container, duplicates included.
- **More than one match.** `container` is THE container. Report the `duplicates` by number; never
  file into one, never create another, never merge them from a caller — only the repair procedure
  below moves items.
- **Closed or Done.** A set `completedAt` or `endedOutcome` (`get_item` with `view: "full"`) means
  closed: reopen and reuse it — `update_item` with `statusId` = the first open status of its work
  type's collection (`get_workspace_context`, as `build-item` step 1 resolves In Progress); the
  `reopen` tool only when it is already on a board. No open status resolves → STOP and report;
  never create a second container to get around it.
- **Creation**, only when `create` is true: the work type the organization's hierarchy requires
  directly under the root (`get_work_type_hierarchy`; an Epic under a Capability), creating every
  intermediate level the `parentWorkTypeId` chain requires, titled `defects.deferredContainerTitle`,
  with a one-paragraph description: a parking container whose items are never built from here
  automatically, carry no execution-order number and no blocking links, and link back to what
  produced them.

## Filing into it

- **The kind.** A finding that describes behaviour wrong TODAY is a Defect (`isBug: true`), filed
  by `/devstride:create-defect deferred <item#>`. Everything else — tech debt, a clean-up,
  hardening with nothing wrong yet, a dated after-deploy step, a follow-up — is a Story, filed by
  `/devstride:create-story deferred <item#>`. The leaf work type is resolved at run time
  (`get_work_type_hierarchy`), never assumed.
- **The item.** `create_item` with the container as `parentNumber` and an honest spec as its
  description; NO execution-order `[N]` prefix; NO `blocked_by` or `blocks` edge in either
  direction; one `add_relationship` related-to edge to the item whose review or planning produced
  it (the story under build, or the release unit for an epic-release review) — the relationship
  type read from the `add_relationship` schema, never assumed. No board, status, priority or
  assignee interview — filing normally runs unattended inside a build loop; set one only when a
  user is present and asks — no date, never built, never given a delivery phase. A person who names one
  by number can still build it as a one-off.
- **What does not widen.** Only a verified P1, a security finding, or a finding both likely and
  material is filed; anything below that bar is dismissed with a one-line reason. Discovered scope
  the plan genuinely needs is not deferred work: it splices into the chain with `insert-story`.
- **No plan root** (a one-off outside any plan) → noted for the owner, not filed.

## How the rest of the loop treats it

- **Selection and counts** (`build-item` steps 0 and 7, `next-unblocked.md`): every `members`
  number is excluded — never a candidate, never remaining, never a release unit.
- **Planning gates** (`plan` step 5, `rebalance` step 3b): members are edge-free by rule, so the
  orphan gates skip them; `rebalance` never merges, splits, renumbers or archives one.
- **`comprehend-plan`** reports the container in its own section, apart from the value tree.
- **Dating** (`rationalize-gantt`): members stay out of the graph, the cascade and the violation
  pass, then are dated after the plan's last value leaf. Filing never writes a date.
- **The closing report.** When the plan root reaches zero remaining value leaves, `build-item`
  (step 7, and step 0's "plan complete") and `comprehend-plan` list **Still open in Deferred**: for
  every open member, its number, title, kind (Defect when `isBug`, else Story) and the item its
  related-to edge points at (`get_item` with `fields: ["number", "title", "isBug",
  "relationships"]`).

## Repair procedure — merging duplicates

Run only by a story or a person that names it, never by a caller filing a finding: run `match`
over the root's direct children; for each `duplicates` entry, move its children into `container`
one at a time with `reparent_item` (related-to edges survive a reparent), add a comment on the
emptied duplicate pointing at `container`, then `archive_item` it. Never `delete_item`. Report the
numbers moved, or "none found".
