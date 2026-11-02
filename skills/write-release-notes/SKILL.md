---
name: write-release-notes
description: "Step: run the release-notes hook (docs.releaseNotesSkill) in publish or draft mode, only when the owner asked, and print one verdict."
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/step-skills.md` first: the rule every step skill follows.

Arguments: $ARGUMENTS — the mode (`publish` or `draft`) and the delta payload as a fenced JSON
block. Contract and authority: `${CLAUDE_PLUGIN_ROOT}/skills/release/references/docs-hooks.md`.

## Verdict

`RELEASE NOTES: PUBLISHED | DRAFTED | NOT CONFIGURED | FAILED`

## Steps

1. Run only on the owner's request — `release` calls this step only for `--release-notes true`
   or `draft`, and a person runs it by name. Never decide on anyone's behalf that a release
   deserves a note.
2. Read `docs.releaseNotesSkill`. Null, absent or naming no `.claude/skills/<name>/SKILL.md` →
   `NOT CONFIGURED`: the request cannot be met; name `/devstride:setup docs`. Never improvise a
   note.
3. `publish` needs `live: true` in the payload (the deploy confirmed); otherwise refuse with
   `FAILED` and say so. `draft` may run with either.
4. Invoke the skill by name with the mode and payload. Print `PUBLISHED` or `DRAFTED` from what
   it reports, `FAILED` with its output otherwise, then the note's location — whether it is live
   or awaiting the owner — with the link kept exact.
