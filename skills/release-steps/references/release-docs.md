---
load: contract
---
# Update documentation — publish for the release that is live, then settle what was owed

`release-steps`' `release-docs@1` step (the step `update-docs`), after the deploy is confirmed and
the health check did not fail. It calls the existing step skill **`update-docs`** once, in mode
`update`, and translates its verdict. The payload, the publish rule and the owed table are
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/docs-hooks.md` "The delta payload" and "What
`release` does with each docs verdict", cited, not copied.

1. **Config wins.** Load `.claude/ds-config.json`: `docs.updateSkill`,
   `docs.knowledgeBaseSyncSkill`, `release.productionBranch`, `release.clearance` (whether it is a
   provider with owed work: a repository provider without `commands.owed` gets no `owed` calls).
2. **What must hold first**, from this run's recorded verdicts (the runner's `status`, never
   memory): the deploy confirmation answered `CONFIRMED` or `NOT CONFIGURED`; the health check, when
   this run has one, did not answer `FAIL`. Otherwise no verdict line, naming it: nothing public is
   written about a release whose deploy or health is in question, and the run stops.
3. **`no docs` or `skip docs`** was said for this run (`docs-plan` answered `SUPPRESSED`) →
   `NOT APPLICABLE`. Print the catch-up whole, because a bare `/devstride:update-docs update`
   refuses without a payload: `/devstride:update-docs update` followed by this release's completed
   payload (step 4) as a fenced JSON block, then, when `docs.knowledgeBaseSyncSkill` is set,
   `/devstride:sync-knowledge-base sync {"docsOutcome": "published", "live": true}` once the docs
   are live. Nothing was owed, so nothing is settled.
4. **The completed payload**: the `production-release` payload over the range the merge brought
   (`<merge>^1..<merge>`; the merge commit is `production-merge`'s `sha`, else
   `merged-release`'s), with `mergeCommit`, `mergedAt` and `live: true`: the deploy is confirmed.
   Items are summarised in plain English, as `docs-hooks.md` says.
5. **Run it**: the Skill tool, `update-docs update`, with that payload. Its first line is the
   verdict: `PUBLISHED`, `STAGED`, `CURRENT`, `NOT CONFIGURED` (unset, or a hook that does not
   resolve) or `FAILED`; anything else or nothing → `FAILED`. Translate the evidence with pages,
   branch, pull request and live address exact.
6. **Settle by the table**, through the provider's `owed --done <item>`:
   - `PUBLISHED` → settle `docs`; `knowledge-base` stays owed for the sync that follows.
   - `CURRENT` → settle `docs` and `knowledge-base`: nothing new to mirror.
   - `STAGED` → settle `docs`, and name the owner action (a draft to look at, a pull request to
     merge); `knowledge-base` stays owed, with the catch-up once the docs are live.
   - `FAILED` → both stay owed; say so, with the re-run line. The run continues.
   - `NOT CONFIGURED` → never owed; nothing to settle.
7. The close-out's `docs` value comes from this verdict by the same table: `published`,
   `nothing to change`, `skipped` or `failed`.

## Verdict

`UPDATE DOCS: PUBLISHED | STAGED | CURRENT | NOT CONFIGURED | FAILED | NOT APPLICABLE`

## Result

`state`: `published`, `staged`, `current`, `not-configured`, `failed` or `not-applicable`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
