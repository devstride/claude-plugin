---
load: contract
---
# Close out the release — the work the health check said waits until after the hand-back

`release-steps`' `release-close-out@1` step (the step `post-deploy-close-out`), after the
documentation steps. It calls the existing step skill **`post-deploy`** once, in mode
`close-out`. The contract is `${CLAUDE_PLUGIN_ROOT}/skills/release/references/post-deploy-check.md`
"Work that waits until after the hand-back", and the `docs` value comes from
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/docs-hooks.md` "What `release` does with each docs
verdict", both cited, not copied.

1. **Config wins.** Load `.claude/ds-config.json`: `release.postDeployCheckSkill`,
   `release.productionBranch`, `release.clearance` (a repository provider without
   `commands.owed` gets no `owed` calls).
2. **When it applies**, from this run's recorded evidence (the runner's `status` with `evidence`
   `true`, the health check's row; never memory, and never the verdict alone, which carries no
   evidence): only when that row's `evidence` holds a `CLOSE-OUT OWED: <list>` line. No such line,
   no health check in this run, or `release.postDeployCheckSkill` unset → `NOT APPLICABLE`: a
   skill that printed no such line is never invoked with `close-out`.
3. **Safe to re-run.** An earlier attempt of this step in this run answered `DONE` → `DONE`
   again, invoking nothing: the close-out runs once.
4. **The payload**: `productionBranch`; `mergeCommit` (`production-merge`'s `sha`, else
   `merged-release`'s); `deployConfirmedAt` (the deploy confirmation's `confirmedAt`); and `docs`
   from the documentation step's verdict by the table: `PUBLISHED` → `published`, `CURRENT` →
   `nothing to change`, `STAGED`, `NOT CONFIGURED` or `NOT APPLICABLE` (`no docs`) → `skipped`,
   `FAILED` → `failed`.
5. **Run it**: the Skill tool, `post-deploy close-out`, with that payload as a fenced JSON
   block, once. Its first line is the verdict:
   - `DONE` → the provider's `owed --done close-out --pr <n>` → `DONE`.
   - `PARTIAL`, anything else, or nothing → `PARTIAL`: the item stays owed, and the evidence names
     what is left for the recap and the owner. The run continues.

## Verdict

`POST-DEPLOY CLOSE-OUT: DONE | PARTIAL | NOT APPLICABLE`

## Result

`state`: `done`, `partial` or `not-applicable`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
