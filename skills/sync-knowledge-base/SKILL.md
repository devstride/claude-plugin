---
name: sync-knowledge-base
description: "Step: run the knowledge-base sync hook (docs.knowledgeBaseSyncSkill) after documentation was published live, and print one verdict; release calls it after docs."
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/step-skills.md` first: the rule every step skill follows.

Arguments: $ARGUMENTS — `sync` and a fenced JSON payload `{ "docsOutcome": "...", "live":
true|false }` from the caller, or `check` (also what a bare run with no arguments does). Contract:
the knowledge-base section of `${CLAUDE_PLUGIN_ROOT}/skills/release/references/docs-hooks.md`.

## Verdict

`KNOWLEDGE BASE SYNC: DONE | CURRENT | FAILED | NOT RUN | NOT CONFIGURED`

## Steps

1. Read `docs.knowledgeBaseSyncSkill`. Null or absent → `NOT CONFIGURED`. A name with no
   `.claude/skills/<name>/SKILL.md` → `NOT CONFIGURED`, naming the dangling hook.
2. `sync`: run only when `docsOutcome` is `published` AND `live` is `true`. Anything else, or no
   payload → `NOT RUN`, with the reason ("documentation was staged", "no payload"), without
   invoking the skill: a knowledge base never runs ahead of its documentation.
3. Invoke the skill by name in mode `sync` with the payload; for `check`, in mode `check` with no
   payload, so it checks its own preconditions, read-only.
4. Pass its first line through when it is `DONE`, `CURRENT` or `FAILED`; any other first line
   or a failed run is `FAILED`. A `FAILED` verdict always carries the line
   `re-run: /devstride:sync-knowledge-base sync {"docsOutcome": "published", "live": true}`
   and, when `release.clearance` names a provider with an `owed` command, the settlement after it:
   `then, on DONE or CURRENT: <owed command> --done knowledge-base` — `bash
   ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/clearance-<provider>.sh owed` for `provider:
   github` or `devstride`, else `commands.owed`
   (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/clearance.md`). This step never runs it: settling owed work stays with whoever re-runs the sync.

A failure here never undoes, reverts or re-publishes the documentation push; it is owed work,
which the caller keeps owed as `knowledge-base` until a re-run succeeds and its printed
settlement line is run.
