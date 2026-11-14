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

- **Plan root.** The root the caller already works under (`build-item`'s plan root, the plan
  being authored or re-cut); without one, `get_item` with `view: "full"` on the item the finding
  concerns, walking its hierarchy UPWARD to the top-most item under the portfolio. That root — not
  the item's own parent — owns the container.
- **Identity.** A DIRECT child of the plan root whose title, trimmed, inner whitespace collapsed
  and case ignored, equals `defects.deferredContainerTitle` (shipped default `Deferred`) or a
  legacy title: the built-in `Deferred defects` plus every entry of
  `defects.deferredContainerLegacyTitles` (shipped default `["Deferred defects"]`; a configured
  list only adds to the built-in). Exact after normalising: a title that merely contains the word
  is NOT a match, and an archived item never is. Matching an old NAME is the only legacy rule.
- **Never by eye.** List the root's descendants (`search_items` with `hierarchy: [root]`, every
  page), drop archived items, keep those whose `parentNumber` is the root, and pipe
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
  intermediate level the `parentWorkTypeId` chain requires, titled `defects.deferredContainerTitle`.
  When the only type allowed directly under the root is a leaf type, no container can hold work:
  the finding is noted for the owner, not filed, and nothing is created. The container gets
  a one-paragraph description: a parking container whose items are never built from here
  automatically, carry no execution-order number and no blocking links, and link back to what
  produced them. `plan` step 2 provisions it up front this same way; otherwise the first filing
  does. It takes no board: an explicit `boardId: null` (an omitted one can inherit the root's)
  on it and every level created with it.

## Filing into it

- **The kind.** A finding that describes behaviour wrong TODAY is a Defect (`isBug: true`), filed
  by `/devstride:create-defect deferred <item#>`. Everything else — tech debt, a clean-up,
  hardening with nothing wrong yet, a dated after-deploy step, a follow-up — is a Story, filed by
  `/devstride:create-story deferred <item#>`. The leaf work type is resolved at run time
  (`get_work_type_hierarchy`), never assumed.
- **The item.** `create_item` with an honest spec as its description and, as `parentNumber`, the
  container — or, when the hierarchy does not allow a leaf directly under its type, the node of
  the leaf's parent type beneath it (reuse the one there, else create the chain down to it, each
  titled `defects.deferredContainerTitle`; everything under the container is a member); NO execution-order `[N]` prefix; NO `blocked_by` or `blocks` edge in either
  direction; one `add_relationship` related-to edge to the item whose review or planning produced
  it (the story under build, or the release unit for an epic-release review) — the relationship
  type read from the `add_relationship` schema, never assumed. No board, status, priority or
  assignee interview: filing normally runs unattended inside a build loop, so set one only when a
  user is present and asks; `boardId` is otherwise an explicit `null`, as on the container and
  on every node created here, and never `activeAgents.boardId`. Filing writes no date; the item is never built and never given a
  delivery phase. A person who names one by number can still build it as a one-off.
- **What does not widen.** The bar is the CALLERS' (`review` step 4, `build-item` 6.5, `release`
  step 2): only a verified P1, a security finding, or a finding both likely and material is filed;
  anything below it is dismissed with a one-line reason. A person's explicit `deferred` request is
  filed as asked. Discovered scope
  the plan genuinely needs is not deferred work: it splices into the chain with `insert-story`.
- **No plan root** (a one-off outside any plan) → noted for the owner, not filed.

## How the rest of the loop treats it

- **Selection and counts** (`build-item` steps 0 and 7, `next-unblocked.md`): every `members`
  number is excluded — never a candidate, never remaining, never a release unit.
- **Planning gates** (`plan` step 5, `rebalance` step 3b): members are edge-free by rule, so the
  orphan gates skip them; `rebalance` never merges, splits, renumbers or archives one, and only
  `rationalize-gantt`'s deferred pass moves their dates.
- **`comprehend-plan`** reports the container in its own section, apart from the value tree.
- **Dating** (`rationalize-gantt`): members stay out of the graph, the cascade and the violation
  pass, then are dated after the plan's last value leaf. Filing never writes a date.
- **The closing report.** When the plan root reaches zero remaining value leaves, `build-item`
  (step 7, and step 0's "plan complete") and `comprehend-plan` list **Still open in Deferred**: for
  every member of a leaf work type (never a container or an intermediate node) that is not Done
  and not closed, its number, title, kind (Defect when `isBug`, else Story) and the item its
  related-to edge points at (`get_item` with `fields: ["number", "title", "workType", "status",
  "isBug", "completedAt", "endedOutcome", "relationships"]`).

## Closing — the container and the plan close when the work under them is finished

An open container whose work is all finished keeps its plan from ever showing Done, so both close
themselves. **Unbuilt deferred work keeps both open** (owner decision): the loop never builds,
moves or closes a deferred LEAF; a person builds it by number or closes it by hand.

- **When.** `build-item` at step 0's terminal exits, at step 7 when the root reaches zero, and
  when an item it lands Done sits under a plan root (a deferred item built by number included);
  `release` after its train merge closes one-offs (`release-branch.md` §1 step 6); `create-story`
  / `create-defect` after filing (a closed container or Done root reopens). `comprehend-plan` and
  `doctor` only report the decision.
- **The decision is code.** `search_items` with `hierarchy: [root]` (every page, no archived,
  `fields: ["number", "parentNumber", "workType", "status", "completedAt", "endedOutcome"]`),
  every container from `match` (`all`), then `{"root": {"number", "done"}, "containers": […], "nodes":
  [{"number", "parentNumber", "leaf", "done"}…]}` into `deferred-container.py settle`. `leaf`: a
  `hierarchyRoles.leaf` type; `done`: a done-type status, `completedAt` or `endedOutcome` (a
  landed leaf not yet Done is open).
- **Acting.** Each `close` number in order (container nodes, and outside them a grouping item
  whose work is all Done), then the root on `close`: `update_item` to the
  done-type status in its collection (as `item-status.py` resolves it; not exactly one → report,
  never guess), `add_comment` "closed: everything under it is finished", `get_item` to read it
  back. `reopen` goes to the first open status as "Closed or Done" says, commented "reopened:
  <numbers> still open". A failed write is a report line, never a stop, and skips the closings
  after it, the root included: the next run's decision repeats them.
- **Report** what closed, and for an open plan its `openValue` numbers and **Still open in
  Deferred**. A closed root leaves the Active Agents board by `active-agents.md` §2.

## Repair procedure — merging duplicates

Run only by a story or a person that names it, never by a caller filing a finding: run `match`
over the root's direct children; for each `duplicates` entry, move its children into `container`
one at a time with `reparent_item` (related-to edges survive a reparent), add a comment on the
emptied duplicate pointing at `container`, then `archive_item` it. Never `delete_item`. Report the
numbers moved, or "none found".
