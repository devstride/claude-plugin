---
name: update-docs
description: "Step: run the repository's documentation hook (docs.updateSkill) once — update or check — and print one verdict; release and build-item call it."
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/step-skills.md` first: the rule every step skill follows.

Arguments: $ARGUMENTS — a mode (`update`, the default, or `check`) and, for `update`, the
delta payload as a fenced JSON block. Payload shape, modes, the publish rule and what the
release records for each verdict: `${CLAUDE_PLUGIN_ROOT}/skills/release/references/docs-hooks.md`.

## Verdict

`UPDATE DOCS: PUBLISHED | STAGED | CURRENT | NOT CONFIGURED | FAILED` and `UPDATE DOCS CHECK: PASS | FAIL | NOT CONFIGURED`

## Steps

1. A legacy `release.docsRepo` → say the shape is deprecated and name `/devstride:setup docs`,
   whatever `docs.updateSkill` holds; never act on it, and carry on (a valid hook still runs).
2. Read `docs.updateSkill`. Null or absent → `NOT CONFIGURED`: no documentation system is
   registered and no docs phase runs. A name with no `.claude/skills/<name>/SKILL.md` → `NOT
   CONFIGURED`, naming the dangling hook and its fix, `/devstride:setup docs` (it scaffolds the
   skill).
3. `update` with no payload → refuse: the caller computes the delta, this step never derives it.
   An `epic-release` payload is always `live: false`, never optional.
4. Invoke the skill by name with the mode and payload. It owns the pages, the edits, push or pull
   request, and whether the owner looks first.
5. Print the verdict from what the skill reports, never from what was asked:

| Verdict | When |
|---|---|
| `PUBLISHED` | Explicit evidence the docs are live (a push to the branch that publishes, a live URL); only possible with `live: true`. |
| `STAGED` | Staged work: a local branch, an unpublished draft, a docs pull request opened or awaiting the owner. Every `live: false` run that changed something. |
| `CURRENT` | The skill reports nothing to change (for example "no documentation changes for this release"). |
| `FAILED` | It errored, reported no destination, or said anything else. Its output follows. |

`check` passes the skill's `PASS`/`FAIL` and fix through. Then the skill's pages and destinations,
links kept exact, and any owner action left (a draft to look at, a pull request to merge).

Never edit documentation here, never write release notes, and never publish with `live` false.
