---
name: classify-release
description: "Step: ask the repository's release.classifySkill whether a release is light or full; anything but a clear answer is FULL."
---

Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/step-skills.md` first: the rule every step skill follows.

Arguments: $ARGUMENTS — the payload `{ "productionBranch", "releaseSource", "head" }` as a fenced
JSON block (run alone: the configured branches and the release source's tip). Contract:
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-safety-hooks.md`.

## Verdict

`RELEASE CLASS: LIGHT | FULL`

## Steps

1. Read `release.classifySkill`. Null or absent → `RELEASE CLASS: FULL`, reason "no classifier
   configured". A name with no `.claude/skills/<name>/SKILL.md` → `FULL`, naming the dangling hook.
2. Invoke the skill by name in mode `classify` with the payload, once.
3. Its first line is `RELEASE CLASS: LIGHT` or `RELEASE CLASS: FULL` → pass it through with its
   reason line. A failed run or any other first line → `RELEASE CLASS: FULL`, with the reason.

A safety step: a release is never light by default, by guess, or because the classifier could not
answer. The second line is always the one-line reason.
