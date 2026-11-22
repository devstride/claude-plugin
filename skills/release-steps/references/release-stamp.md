---
load: contract
---
# Stamp the checks — proof of what they tested

`release-steps`' `release-stamp@1` step, the last of the checks a `merge-and-deploy` release
runs before it claims the tower
(`${CLAUDE_PLUGIN_ROOT}/skills/release/references/clearance.md` "Scope `merge-and-deploy`", "0p").
The stamp records the head, its tree, the production tip the checks started against and the
release class; the final gate verifies it, so the tree CI tested is the tree that merges.

1. **Config wins.** Load `.claude/ds-config.json`. A `MERGED` release
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`) has nothing to
   stamp: answer `STAMPED` with the detail `none (already merged)` and change nothing.
2. **Only over green checks.** Read this phase's rows in the run's `status`: the pre-ship step
   answered `PASS` or `NOTHING TO RUN`, the dev deploy wait `SERVING` or `NOT APPLICABLE`, the
   pre-merge check neither `HOLD` nor an unanswered `NOT RUN`. Anything else → no verdict line:
   say which check is red and stop. The open pull request keeps later releases queued behind
   it, and the owner decides.
3. **The inputs, read back, never remembered:** `<m>` from the row of
   `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-tip.md` (`PRODUCTION TIP: AT
   <m>`), the class from the classify step of this phase, the head from the detached checkout
   the checks ran on.
4. `python3 ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/release_checks.py stamp --head <head>
   --class <LIGHT|FULL> --master <m>`:
   - exit 0 → `STAMPED`. The detail is the printed line after its first two words (`head <h>
     tree <t> master <m> class <c> at <iso>`); the whole printed line is the first evidence
     line. Keep both exact: the final gate hands that line back to `verify`.
   - exit 3, `CHANGED master <m>..<now>` (production moved while the checks ran) → `CHANGED`,
     naming that range. Nothing is stamped: those results describe a production that is gone.
     The run issues this step again.
   - exit 1 → no verdict line: say why and stop.
5. **Issued again after `CHANGED`** (this step's row in `status` shows attempt 2 or more, and
   step 4 with the old `<m>` still exits 3): **rebuild, then stamp.** In this order, one call
   each: bring production in again, by the procedure of
   `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/production-in-branch.md` (a `CONFLICT`
   there → no verdict line, stop); read the tip again (`release_checks.py tip`, the new `<m>`);
   then on the new head, each by name and never inlined, `classify-release`, `pre-ship release
   run <class>` (with its `--ran-at-train` evidence as usual), the dev deploy wait
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/dev-deploy-wait.md`; a later round
   passes the first round's answer through) and `pre-merge-check`. All green → step 4 with the
   new head, class and `<m>`; the evidence carries each check's verdict line.
6. **At most three rounds.** Once this step has answered `CHANGED` three times in one run → no
   verdict line: say production moved three times while the checks ran, and stop for the owner.
   The final gate verifies the stamp under the tower, where production cannot move unseen.
7. **No heartbeat in this phase** (nothing is held, `resume-rules.md` "Heartbeats").

## Verdict

`CHECKS STAMP: STAMPED <stamp> | CHANGED <range>`

## Result

`state`: `stamped` or `changed`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-tip.md`
