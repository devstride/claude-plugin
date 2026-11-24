---
load: contract
---
# Close out the train — every one-off it carried is marked as reached

`release-steps`' `train-close-out@1` step. The rule is
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-branch.md` §1 step 6, cited, not copied:
its two subject patterns and its skip rules are read there. Nothing was recorded on the items
beforehand; the git history is the record.

1. **The train gate**
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/train-finish.md` "The train phase").
   Not applicable → `NOT APPLICABLE`.
2. **The pull request** is the train pull request this run just merged: the latest merged one
   that §1 "Finding release-train pull requests" finds. None → `NONE`. When this run merged none
   (nothing to ship), the latest merged one was already finished by `train-finish`; running
   steps 3 to 5 on it again changes nothing.
3. **Candidates** come from the merge subjects in its marker's range, `git log --first-parent
   --merges --format=%s <sourceBefore>..<trainSnapshot>`, never from the live train, and only
   the number that identifies each merge (§1 step 6's two patterns). Any other number a subject
   cites is reported, never closed; merges of the release source itself are skipped.
4. **Each candidate is LOOKED UP with `get_item` before any write.** Keep only an item of a
   `hierarchyRoles.leaf` type that is not Done and has no "reached" comment for this pull request.
   For each kept item: `update_item` to Done with `dueDate` today, then `add_comment` "reached
   <releaseSource> with release <name> (release train pull request #<n>)".
5. **Closing** (`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/deferred-container.md`), once
   per plan root above the items closed.
6. **Answer.**
   - Every candidate was closed here or was already Done or commented, and at least one was
     closed here → `CLOSED`, with the count.
   - Nothing to close → `NONE`.
   - A candidate could not be marked (not a leaf type, a lookup or a write that failed), or a
     merge subject carries no item number → `PARTIAL`, listing each as "not marked Done:
     <subject>", after closing the rest. Never guess a number. The run carries on, and the list
     is said.

## Verdict

`TRAIN CLOSE-OUT: CLOSED <count> | NONE | PARTIAL <skipped> | NOT APPLICABLE`

## Result

`state`: `closed`, `none`, `partial` or `not-applicable`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/train-finish.md` (the same close, for an
  interrupted earlier run)
