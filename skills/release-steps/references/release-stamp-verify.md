---
load: contract
---
# Verify the checks stamp — the tree that was tested is the tree that merges

`release-steps`' `release-stamp-verify@1` step, scope `merge-and-deploy` only: run right after the
final tower claim and once more just before the merge confirmations, because production may have
moved in between. The stamp's meaning is
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/clearance.md` "Scope `merge-and-deploy`"
("Rebuilt when what is ahead changes"), cited, not copied.

1. **Config wins.** Load `.claude/ds-config.json`: `release.clearance.scope`,
   `release.productionBranch`. Shape `MERGED`
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`) → `UNCHANGED`, saying
   nothing is left to verify.
2. **The stamp** is the NEWEST printed stamp of this run, word for word, from the evidence the
   runner's `status` with `evidence` `true` keeps: the first evidence line of the stamp step, of a
   discharge that stamped the settled head (`pre-ship-resume.md`) or of a `SAME TREE` hotfix
   catch-up, the latest of them. It is the text that starts `CHECKS STAMP
   head …`, never the `CHECKS STAMP: STAMPED` label, which `verify` cannot parse. No such line, or
   another scope → `ERROR`, saying there is no stamp. It is never rebuilt from memory.
3. Run `python3 ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/release_checks.py verify --stamp
   '<line>' --head <reviewedHead>`, the head being the one the review settled on, or the new head
   a `SAME TREE` catch-up stands in for it.
4. **Act on the answer, exactly:**
   - `UNCHANGED` (exit 0) → `UNCHANGED`.
   - `CHANGED` or `BEHIND` (exit 3: the release ahead was reverted, a hotfix landed, or anything
     else moved production since the checks) → run the provider's `release --step-aside` when
     this session holds the tower, then answer `CHANGED` or `BEHIND` with the script's line. The
     runner sends the run back to the hotfix catch-up, which rebuilds the release on what is now
     ahead (production merged in, the review, checks, stamp and CI again, the tower claimed
     again). Any owner yes is void.
   - `ERROR` (exit 1), or no answer → step aside the same way, then `ERROR`. Never `UNCHANGED`.
5. A stepped-aside release holds nothing and owes nothing. Every step after a new claim starts
   with its heartbeat, and exit 4 there is a stop.

## Verdict

`CHECKS STAMP: UNCHANGED | CHANGED | BEHIND | ERROR <reason>`

## Result

`state`: `unchanged`, `changed`, `behind` or `error`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
