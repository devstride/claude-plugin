---
load: contract
---
# Stamp the checks — the head, tree and production tip they passed on

`release-steps`' `release-stamp@1` step (the step `checks-stamp`), the last of the checks under
scope `merge-and-deploy`. The stamp's rules are the header of
`${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/release_checks.py`; why a moved production voids the
checks is `${CLAUDE_PLUGIN_ROOT}/skills/release/references/clearance.md` "Scope
`merge-and-deploy`", both cited, not copied. Reaching this step means the pre-ship checks passed
and the pre-merge check did not hold: either one stops the run with the pull request open.

1. **Shape** `MERGED` (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`) →
   `STAMPED none`, saying nothing was checked for a release already merged.
2. **Inputs**, from this run's recorded verdicts (the runner's `status`, never memory): the head
   is the detached checkout's `HEAD` that `checks-tip` set; `<m>` is `checks-tip`'s `AT <m>`; the
   class is `classify-at-checks`' (`LIGHT` or `FULL`; anything unclear is `FULL`).
3. **Stamp**: `python3 ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/release_checks.py stamp --head
   <head> --class <class> --master <m>`.
   - Exit `0` → `STAMPED`, with the script's whole line (`CHECKS STAMP head <h> tree <t> master
     <m> class <c> at <iso>`) as its detail, exactly, so the stamp verify passes it to `verify
     --stamp` unchanged.
   - Exit `3` (`CHANGED master <m>..<now>`: production moved while the checks ran) → `CHANGED
     <m>..<now>`. Those results describe a production that is gone; the runner issues this step
     again.
   - Exit `1` → no verdict line, naming the error: the runner stops, never a stamp.
4. **The attempt after a `CHANGED`** runs the round itself before it stamps: bring production in
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/production-in-branch.md`), check out the
   new head detached, read the tip again
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-tip.md`), then by name, one
   verb per call: `classify-release` at that head, `pre-ship release run <class>`, the dev deploy
   wait (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/dev-deploy-wait.md`; the same cut,
   so it passes the first round's exit through) and `pre-merge-check`; then step 3 with the new tip
   and class. An attempt knows it follows a `CHANGED` from the runner's `status` row for
   `checks-stamp` (its earlier attempt's verdict). A conflict, `PRE-SHIP: FAIL` or a pre-merge
   `HOLD` → no verdict line, naming it: the run stops with the pull request open, and the owner
   decides. At most three rounds: a fourth `CHANGED` stops the same way, said so; the stamp
   verify under the tower is the floor.
5. **The round's evidence.** The runner records none of a round's verdicts, so its `STAMPED`
   carries them (class, `PRE-SHIP`, `DEV DEPLOY`, pre-merge) as evidence lines, and every later
   reader of the checks' lines (the "passed at" report, the standing yes's `--pre-ship` and
   `--dev-deploy`) takes them from there when the last stamp had a round.

## Verdict

`CHECKS STAMP: STAMPED <stamp> | CHANGED <range>`

## Result

`state`: `stamped` or `changed`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
