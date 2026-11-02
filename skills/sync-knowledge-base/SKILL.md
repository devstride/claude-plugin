---
name: sync-knowledge-base
description: "Step: run the knowledge-base sync hook (docs.knowledgeBaseSyncSkill) after documentation was published live, and print one verdict; release calls it after docs."
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/step-skills.md` first: the rule every step skill follows.

Arguments: $ARGUMENTS — a fenced JSON payload `{ "docsOutcome": "...", "live": true|false }`
from the caller, or nothing. Contract: the knowledge-base section of
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/docs-hooks.md`.

## Verdict

`KNOWLEDGE BASE SYNC: DONE | CURRENT | FAILED | NOT RUN | NOT CONFIGURED`

## Steps

1. Read `docs.knowledgeBaseSyncSkill`. Null or absent → `NOT CONFIGURED`. A name with no
   `.claude/skills/<name>/SKILL.md` → `NOT CONFIGURED`, naming the dangling hook.
2. With a payload: run only when `docsOutcome` is `published` AND `live` is `true`. Anything
   else → `NOT RUN`, with the reason ("documentation was staged", "documentation was skipped"),
   without invoking the skill: a knowledge base never runs ahead of its documentation.
3. Invoke the skill by name in mode `sync` with the payload. With no payload (run alone), invoke
   it in mode `check` so it checks its own preconditions, read-only.
4. Pass its first line through when it is `DONE`, `CURRENT` or `FAILED`; any other first line
   or a failed run is `FAILED`. A `FAILED` verdict always carries the line
   `re-run: /devstride:sync-knowledge-base`.

A failure here never undoes, reverts or re-publishes the documentation push; it is owed work,
recorded by the caller as `knowledge-base` and settled with `owed --done knowledge-base`.
