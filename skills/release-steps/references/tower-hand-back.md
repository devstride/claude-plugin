---
load: contract
---
# Hand back the tower — naming every piece of work still owed

`release-steps`' `tower-hand-back@1` step: `hand-back-after-deploy` under scope
`merge-and-deploy` (once the deploy is confirmed), `tower-hand-back` under `release` and
`cut-to-deploy` (after the close-out's branch work). The rule is
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-branch.md` §5 step 4 and
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/clearance.md` "Where the release skill calls it"
(Hand-back) and its two scope sections, cited, not copied.

1. **Config wins.** Load `.claude/ds-config.json`: `release.clearance` (its `scope`, and whether
   it is a repository provider with or without `commands.owed`). The payload's `scope` wins when
   set. No clearance block → `NOT APPLICABLE`. This session's local clearance record
   (`clearance.md` "The local record") names no hold → `NOT APPLICABLE`, saying nothing was held
   (a hand-back already made; a re-run).
2. **What must hold first**, from this run's recorded verdicts (the runner's `status`, never
   memory). Any one missing or not a pass → `KEPT <why>`, naming it: a stop before the hand-back
   keeps clearance for the retry, and the recap says so.
   - Every scope: the deploy confirmation answered `CONFIRMED` or `NOT CONFIGURED`.
   - Scope `release`: the health check (`post-deploy-check`) answered `PASS`, `NOT CONFIGURED`,
     or `NOT RUN` accepted by the owner; then the sync, the release-branch deletion and the
     train levelling all answered (§5 steps 1–3).
   - Scope `cut-to-deploy`: the sync, the deletion and the levelling answered, and
     `post-pending-status` answered `PENDING POSTED`.
   - Scope `merge-and-deploy`: `post-pending-status` answered `PENDING POSTED`.
3. **The owed items**, only those that will run, in this order:
   - `post-deploy-check` (scopes `cut-to-deploy` and `merge-and-deploy`), then `sync`
     (`merge-and-deploy` only: §5 steps 1–3 run after the hand-back);
   - `docs` and `knowledge-base` when the documentation plan (`docs-plan`'s `DOCS PLAN: HOOKS`
     line) names those hooks and the run did not say `no docs`; `release-notes` when the plan
     names the notes hook;
   - `close-out` when the health check printed `CLOSE-OUT OWED: …` (scope `release`). Under the
     other scopes the check runs after the hand-back, so `close-out` is not on the list; the
     close-out step still runs on that line, and the evidence names it for the recap.
4. **Hand back** through the provider: ONE `release` call, `--owed <item>` repeated for each item
   (`release --owed post-deploy-check --owed sync --owed docs`). A repository
   provider without `commands.owed` gets plain `release`, never `--owed`, and the evidence names
   the owed work for the recap instead. Exit `0` → `HANDED BACK <owed>` (`none` when nothing is
   owed), quoting `RELEASED …` and the `Close-out owed:` line. Exit `4` (NOT HOLDER) → no verdict
   line: another session owns the release now, and the run stops. Never `--force`: that is the
   owner's command.
5. Every later owed step settles its item with the provider's `owed --done <item>`.

## Verdict

`TOWER: HANDED BACK <owed> | KEPT <why> | NOT APPLICABLE`

## Result

`state`: `handed-back`, `kept` or `not-applicable`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
