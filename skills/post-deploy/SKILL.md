---
name: post-deploy
description: "Step: run the post-deploy health hook (release.postDeployCheckSkill) in check or close-out mode and pass its verdict through; release calls it."
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/step-skills.md` first: the rule every step skill follows.

Arguments: $ARGUMENTS — the mode (`check` or `close-out`) and the payload as a fenced JSON block
(`productionBranch`, `mergeCommit`, `deployConfirmedAt`; `close-out` adds `docs`). Contract,
payload and timing: `${CLAUDE_PLUGIN_ROOT}/skills/release/references/post-deploy-check.md`, which
this step follows unchanged.

## Verdict

`POST-DEPLOY HEALTH: PASS | FAIL | NOT RUN | NOT CONFIGURED` and `POST-DEPLOY CLOSE-OUT: DONE | PARTIAL`

## Steps

1. Read `release.postDeployCheckSkill`. Null or absent → `POST-DEPLOY HEALTH: NOT CONFIGURED`;
   the recap says **post-deploy health: not configured**. A name with no
   `.claude/skills/<name>/SKILL.md` → `POST-DEPLOY HEALTH: NOT RUN`, naming the dangling hook.
2. Invoke the skill by name with the mode and payload, once.
3. `check`: pass its first line through unchanged when it is `PASS`, `FAIL` or `NOT RUN`. Any
   other first line, or a failed run → `POST-DEPLOY HEALTH: NOT RUN` with the reason — never a pass.
4. `close-out`: pass `DONE` or `PARTIAL` through; anything else → `POST-DEPLOY CLOSE-OUT:
   PARTIAL` with the reason and what is left.
5. Then its evidence lines, each naming its command. A `CLOSE-OUT OWED: <list>` line is kept
   verbatim as the LAST line, so the owed accounting is never lost.

This step does not interpret health, decide a rollback or send anything. The stop-and-ask
decisions — `FAIL` stops the release for a rollback decision, `NOT RUN` asks whether to proceed —
belong to `release` step 5a.
