---
load: contract
---
# Item status — the one rule for status moves at start and landing

`python3 ${CLAUDE_PLUGIN_ROOT}/skills/build-item/scripts/item-status.py decide` decides an item's
status move and comment as its build starts (`build-item` step 1) and lands (step 6, a train
merge, an epic or plan merge). Its docstring is the contract; `item-status-fixtures.json` beside
it holds the canonical cases. Any other tool that moves item status for the loop (a repository's
own CLI, a script) runs this file, never a copy.

1. Read the item (`statusId`, and its board's `statusCollectionId` via `get_board` when it is on
   one) and `get_workspace_context` (`statuses`, `statusCollections`).
2. Pipe one JSON request into `decide`:
   - `event`: `start` or `landed`;
   - `item`: `{number, statusId, statusCollectionId?}` (no board → omit it: the default collection);
   - `workspace`: `{statuses, statusCollections}` as read;
   - `target` (landed only): `{kind, branch, sha?, pullRequest?, releaseUnit?, releaseTarget?}`, where
     `kind` is `routing.py target`'s kind: `epic`/`plan` and `train` land (merged status and the
     landed comment); `base`, `integration` and `explicit` are Done;
   - `mergedStatusName`: `epicIntegrationBranches.mergedStatusName` as configured; leave it out when absent.
3. Exit 0: `statusId` present → `update_item` to it and read the item back; absent → leave the
   status. `comment` present → `add_comment` it, whatever the status did. Show `message`.
   Exit 2 or 1 → move nothing, post nothing, and report its `item-status:` line.

It never moves an item out of a done-type status (the landed comment still posts) and never posts
progress comments.
