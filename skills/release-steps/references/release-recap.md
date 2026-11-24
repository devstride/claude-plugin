---
load: contract
---
# Recap the release — what shipped, in plain English, and what is still owed

`release-steps`' `release-recap@1` step, the last report of every release run. What the recap
carries is `${CLAUDE_PLUGIN_ROOT}/skills/release/references/merge-and-deploy.md` "Step 4 — the
human recap" for the change list, and the owed work is
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/clearance.md` "The provider contract" (`owed`),
both cited, not copied. It changes nothing in git, on GitHub or in the tower.

1. **Read the run**, from this run's recorded verdicts and evidence (the runner's `status`, never
   memory), each word for word: every step's verdict line and the step it came from. A line that
   cannot be read is said to be missing, never guessed.
2. **Which recap.**
   - The production merge answered `MERGED` (or `merged-release` found the release this run
     closed out) → `MERGED <pr>`, with the pull request and its merge commit.
   - `release-delta` ended the run at `NOTHING TO RELEASE` → `NOTHING TO RELEASE`, naming the
     source head it compared.
   - Otherwise → `STOPPED AT <step>`, naming the step the run stopped at and its verdict.
3. **Human recap.** In the plain-language rule's words, leading with `Merged / Released`:
   every included item and its effect for the people who use it; the pull request and merge
   commit; whether the deploy is confirmed live; the release class; the pre-merge and health
   results, with "not run" and "not configured" kept apart; the documentation, knowledge-base and
   release-note results, with locations exact; whether the tower was handed back (kept, with the
   reason, when a check failed or the close-out stopped early); the consequence notices again;
   the estimates scored.
4. **Still owed**: the provider's `owed` for this release (a repository provider without
   `commands.owed`: the owed work this run's hand-back named), each item with its catch-up
   command; and any owner action left (a staged draft, a pull request to merge, a rollback
   decision).
5. **Memory.** Update any project memory that tracks release state (epics now in production, the
   date, documentation and notes). None kept → say nothing.

## Verdict

`RELEASE RECAP: MERGED <pr> | STOPPED AT <step> | NOTHING TO RELEASE`

## Result

`state`: `merged`, `stopped-at` or `nothing-to-release`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
