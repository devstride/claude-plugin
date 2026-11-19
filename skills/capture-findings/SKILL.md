---
name: capture-findings
description: "File deferred findings as tracked items and splice in discovered scope."
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/step-skills.md` first: the rule every step skill follows.

Arguments: $ARGUMENTS — one JSON object, the `capture@1` payload
(`${CLAUDE_PLUGIN_ROOT}/schemas/step-contracts.json`): `item`, `oneOff`, and the results of the
build (`build`), the risk check (`riskCheck`) and the review (`review`), whose `untrackedDeferrals`
lists (and the build's `deferrals`) are what this step files. The epic release calls it too, for its
release unit's review (`item` is the release unit; only `review` is given).

## Verdict

`FINDINGS: FILED [<items>] | NONE`

## Steps

1. **What is filed.** A finding worth filing is a P1, a security finding, or one both likely and
   material (the bar of `review` step 4); any other is dismissed, never filed, and a finding a
   step already dismissed is never filed.
2. **A deferred finding → DEFERRED placement** in the plan root's ONE container
   (`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/deferred-container.md`):
   `/devstride:create-defect deferred <item#>` for a bug, `/devstride:create-story deferred
   <item#>` otherwise, related to the item whose review produced it (the RELEASE UNIT for the epic
   release's review). **Never splice a deferred finding into the chain**, under any profile: the
   container is never selected and never counts (the reference says why).
3. **Discovered scope → `/devstride:insert-story`**, spliced so selection reaches it.
4. **A one-off's follow-ups** become their own one-offs (`/devstride:create-story` /
   `/devstride:create-defect`), never `insert-*`; a deferred finding keeps the DEFERRED placement
   under the root this item resolves to.
5. A deferral owned by an EXISTING item goes on that item, as a comment, and is not filed again.
6. Report what went where: each finding and its new or existing item. Nothing to file → `NONE`.

Every item number written is the one the creating skill returned, read back with `get_item`; never
composed.

## Result

After the verdict and its evidence, one fenced `json` block: `filed` (each item created or
commented on, with the finding it holds) and `inserted` (each item spliced into the plan).

**Step rules.** This step only; verdict first; safe to re-run (a finding whose item exists is
found, never filed twice); config wins; it starts no subagent and never decides what runs next.
