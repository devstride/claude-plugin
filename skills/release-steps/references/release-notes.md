---
load: contract
---
# Write release notes — only when they were asked for

`release-steps`' `release-notes@1` step (the step `write-release-notes`), after the documentation
and the close-out. It calls the existing step skill **`write-release-notes`** once, in mode
`publish` or `draft`. The rule is `${CLAUDE_PLUGIN_ROOT}/skills/release/references/docs-hooks.md`
"Who decides what — the rule" and the `write-release-notes` line under its owed table, cited, not
copied. **Release notes are never written without being asked for**: this step never decides a
release deserves one.

1. **Config wins.** Load `.claude/ds-config.json`: `docs.releaseNotesSkill`,
   `release.productionBranch`, `release.clearance` (a repository provider without
   `commands.owed` gets no `owed` calls).
2. **Was it asked for?** The payload's `releaseNotes` first: `true` → `publish`, `draft` →
   `draft`, `false` → not asked. With none in the payload, the words this run was started with:
   `--release-notes true` (a bare flag, or "release notes") → `publish`; `--release-notes draft`
   → `draft`. A run of the release-notes-only entry (the runner's `status` names its workflow
   `release-notes`) IS the request: `publish`, or `draft` when that word accompanied it; never "not requested" there.
   Absent or `false` → `NOT REQUESTED`, with the evidence line "release notes: not requested".
3. **What must hold first**, from this run's recorded verdicts (the runner's `status`, never
   memory): the deploy confirmation answered `CONFIRMED` or `NOT CONFIGURED`, and the health
   check, when this run has one, did not answer `FAIL`. Otherwise no verdict line, naming it: a
   note is public, and is never written about a release whose deploy or health is in question.
4. **The payload**: the `production-release` payload of `docs-hooks.md` "The delta payload" over
   the range the merge brought (`<merge>^1..<merge>`; the merge commit is `production-merge`'s
   `sha`, else `merged-release`'s), with `mergeCommit`, `mergedAt` and `live: true`.
5. **Run it**: the Skill tool, `write-release-notes`, with the mode and that payload as a fenced
   JSON block. Its first line is the verdict:
   - `PUBLISHED` or `DRAFTED` → translate it, the location and whether it is live or awaiting the
     owner exact; then the provider's `owed --done release-notes`.
   - `NOT CONFIGURED` (`docs.releaseNotesSkill` unset or not resolving) → `NOT CONFIGURED`: say
     the request cannot be met, with the fix (`/devstride:setup docs`). Nothing is improvised, and
     the run stops.
   - `FAILED`, anything else, or nothing → `FAILED`: `release-notes` stays owed, with the re-run
     line. The run continues.

## Verdict

`RELEASE NOTES: PUBLISHED | DRAFTED | NOT REQUESTED | NOT CONFIGURED | FAILED`

## Result

`state`: `published`, `drafted`, `not-requested`, `not-configured` or `failed`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
