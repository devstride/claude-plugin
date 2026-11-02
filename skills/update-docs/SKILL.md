---
name: update-docs
description: "Step: run the repository's documentation hook (docs.updateSkill) once — update or check — and print one verdict; release and build-item call it."
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/step-skills.md` first: the rule every step skill follows.

Arguments: $ARGUMENTS — a mode (`update`, the default, or `check`) and, for `update`, the
delta payload as a fenced JSON block. Payload shape, modes and the publish rule:
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/docs-hooks.md`.

## Verdict

`UPDATE DOCS: PUBLISHED | STAGED | NOT CONFIGURED | FAILED` and `UPDATE DOCS CHECK: PASS | FAIL | NOT CONFIGURED`

## Steps

1. Read `docs.updateSkill`. Null or absent → `NOT CONFIGURED`: no documentation system is
   registered and no docs phase runs. A legacy `release.docsRepo` beside it → say the shape is
   deprecated and name `/devstride:setup docs`; never act on it.
2. The name has no `.claude/skills/<name>/SKILL.md` → `NOT CONFIGURED`, naming the dangling
   hook and its fix, `/devstride:setup docs` (it scaffolds the skill).
3. `update` with no payload → refuse: the caller computes the delta, this step never derives it.
   An `epic-release` payload is always `live: false`, never optional.
4. Invoke the skill by name with the mode and payload. It owns the pages, the edits, push or pull
   request, and whether the owner looks first.
5. Print the verdict: `PUBLISHED` when the payload said `live: true` and the skill reports it
   pushed or published; `STAGED` when it staged (any `live: false` run); `FAILED` with its
   output when it errored or reported no destination. `check` passes the skill's `PASS`/`FAIL`
   and fix through. Then the skill's pages and destinations, links kept exact.

Never edit documentation here, never write release notes, and never publish with `live` false.
