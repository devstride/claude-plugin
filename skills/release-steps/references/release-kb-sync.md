---
load: contract
---
# Sync the knowledge base — only after documentation was published live

`release-steps`' `release-kb-sync@1` step (the step `sync-knowledge-base`), right after the
documentation step. It calls the existing step skill **`sync-knowledge-base`** once, in mode
`sync`. The rule is `${CLAUDE_PLUGIN_ROOT}/skills/release/references/docs-hooks.md` "The
knowledge-base sync" and its owed table, cited, not copied. A knowledge base never runs ahead of
the documentation it mirrors.

1. **Config wins.** Load `.claude/ds-config.json`: `docs.knowledgeBaseSyncSkill`,
   `docs.updateSkill`, `release.clearance` (a repository provider without `commands.owed` gets no
   `owed` calls).
2. **When it applies**, from this run's recorded verdicts (the runner's `status`, never memory):
   - `docs.knowledgeBaseSyncSkill` unset → `NOT CONFIGURED`, saying nothing more: the release
     prints no line for a knowledge base it does not have.
   - The documentation plan left it out (`docs-plan` did not name it: no docs hook that resolves,
     a sync hook that does not resolve, or `SUPPRESSED`) → `NOT APPLICABLE`, saying why. A run
     with no `docs-plan` (the docs-only entry) resolves both hooks here instead, by
     `.claude/skills/<name>/SKILL.md` existing, as that step would.
   - The documentation step answered anything but `PUBLISHED` → `NOT APPLICABLE` when it answered
     `NOT APPLICABLE` (`no docs`, whose catch-up it already printed); else `NOT RUN`, naming that
     verdict, without invoking the skill. `knowledge-base` stays owed where the table keeps it
     (`STAGED`, `FAILED`) and was settled where it settles (`CURRENT`).
3. **Run it**: the Skill tool, `sync-knowledge-base sync`, with `{"docsOutcome": "published",
   "live": true}`. Its first line is the verdict: `DONE`, `CURRENT` or `FAILED`; a hook that does
   not resolve → `NOT CONFIGURED`; anything else or nothing → `FAILED`.
4. **Settle.** `DONE` or `CURRENT` → the provider's `owed --done knowledge-base`. `FAILED` → it
   stays owed; never undo or revert the documentation push. Add the line `re-run:
   /devstride:sync-knowledge-base sync {"docsOutcome": "published", "live": true}` and, with a
   provider that records owed work, `then, on DONE or CURRENT: <the provider's owed command>
   --done knowledge-base`. The run continues.

## Verdict

`KNOWLEDGE BASE SYNC: DONE | CURRENT | FAILED | NOT RUN | NOT CONFIGURED | NOT APPLICABLE`

## Result

`state`: `done`, `current`, `failed`, `not-run`, `not-configured` or `not-applicable`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
