---
name: pre-merge-check
description: "Step: ask the repository's release.preMergeSkill whether production needs anything before the release merges, and print one verdict."
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/step-skills.md` first: the rule every step skill follows.

Arguments: $ARGUMENTS — the payload `{ "productionBranch", "releaseSource", "head", "pullRequest" }`
as a fenced JSON block. Contract: `${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-safety-hooks.md`.

## Verdict

`PRE-MERGE: CLEAR | HOLD | NOT RUN | NOT CONFIGURED`

## Steps

1. Read `release.preMergeSkill`. Null or absent → `PRE-MERGE: NOT CONFIGURED`, printed by the
   release as **pre-merge production check: not configured** — never read as "nothing needed".
2. A name with no `.claude/skills/<name>/SKILL.md` → `PRE-MERGE: NOT RUN`, naming the dangling
   hook.
3. Invoke the skill by name in mode `check` with the payload, once. It is read-only: it reports
   what production needs and changes nothing.
4. Pass `CLEAR`, `HOLD` or `NOT RUN` through with its evidence; a `HOLD` carries the action that
   must happen first. A failed run or any other first line → `PRE-MERGE: NOT RUN` with the reason.

A safety step: `HOLD` stops the release before the go-ahead and `NOT RUN` asks the owner — both
decisions belong to `release` step 4.
