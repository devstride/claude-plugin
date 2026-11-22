---
load: contract
---
# Plan the documentation — prepare, never publish yet

`release-steps`' `release-docs-plan@1` step. The payload's shape and the rule for each hook are
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/docs-hooks.md` "The delta payload" and "What
`release` does with each docs verdict" (its step-3 rule), cited, not copied.

1. **Config wins.** Load `.claude/ds-config.json`: `docs.updateSkill`,
   `docs.knowledgeBaseSyncSkill`, `docs.releaseNotesSkill`, `release.productionBranch`, and the
   deprecated `release.docsRepo` (reported whenever present, never acted on).
2. **Build the `production-release` payload** over `origin/<productionBranch>..<reviewedHead>`
   (the head the review settled), with `live: false` and `mergeCommit` and `mergedAt` null. Shape
   `MERGED` (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`): the range
   that merge brought, with its merge commit and time, `live` still false.
3. **`no docs` or `skip docs` was said for this run** → `SUPPRESSED`: the documentation update and
   the knowledge-base sync are left out. Release notes are a separate decision.
4. **Resolve each hook** by checking that `.claude/skills/<name>/SKILL.md` exists:
   `docs.updateSkill`; `docs.knowledgeBaseSyncSkill`, which joins only beside a docs hook that
   resolves; `docs.releaseNotesSkill` only when release notes were asked for
   (`--release-notes`), never because a release seems to deserve one.
   - Resolves → it joins the plan and is owed after the deploy.
   - Set but dangling → report it with its fix (`/devstride:setup docs`) and leave it out; it is
     never owed.
   - Unset → `docs.updateSkill`: "none registered"; the knowledge-base sync: say nothing.
5. **Answer.** At least one hook joined → `HOOKS <hooks>`, naming each. None → `NONE REGISTERED`.
   The plan goes into the go-ahead's recap. Nothing is invoked or published here: documentation
   and notes run only after the deploy is confirmed.

## Verdict

`DOCS PLAN: HOOKS <hooks> | NONE REGISTERED | SUPPRESSED`

## Result

`state`: `hooks`, `none-registered` or `suppressed`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
