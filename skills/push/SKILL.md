---
name: push
description: Stage, commit, type-check, and push the current branch following repo commit conventions
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

**Goal:** the current branch's intended changes committed under the repo's conventions,
type-checked, and pushed — never a pull request (those open separately, not on every push).

## Rules

- **Config wins.** Load `.claude/ds-config.json` first; its `verify`, `generated`,
  `protectedBranches`, `commitConventions` and `itemTagFormat` values are authoritative. Absent →
  the stated fallbacks, said so.
- **Stage deliberately.** `git add -u` for tracked files, then read `git status` and stage every NEW
  file the change requires BY NAME. Never `git add .`/`-A`; leave unrelated untracked files alone.
  Show `git diff --cached --stat`.
- **Message** per `commitConventions` (fallback: Conventional Commits with the item tag shaped by
  `itemTagFormat` — `[I#####]`, `[PROJ-123]`). The tag applies only when the work HAS an item; an
  itemless commit (a merge, a chore) keeps a conventional message with no tag. **Never compose an
  item number** to satisfy the format.
- **Attribution trailers are optional and commit-only.** With valid current-session attribution
  metadata, append `Co-Authored-By:` plus the matching provider session trailer (`Claude-Session:`
  or `Codex-Session:`); without it, omit them and continue — never ask, invent, or reuse stale or
  example values. PR bodies stay free of attribution (`pr`'s rule).
- **Type-check before pushing**: the `verify.typecheck` array in order (`verify.typecheckCombined`
  only when the array is absent); no command configured → ask, never guess. A caller's verification
  receipt is reused only when every rule in
  `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/verification-receipts.md` holds for the
  current tree and this exact list — the new commit usually invalidates it, so run everything unless
  same-tree proof exists. After a pass, write/refresh the receipt for downstream callers.
- **Tolerated errors are declared, never assumed**: an error passes only when its file matches
  `generated.paths` AND its text matches `generated.toleratedTypeErrors`. Neither configured →
  nothing is tolerated. Fix one by re-running `generated.regenCommand`, never by hand-editing.
- **Any other type error → do NOT push**; report the errors and ask.
- **Push**: `git push`. Rejected as non-fast-forward because this branch's history was rewritten
  → `git push --force-with-lease`, never `--force`. **Never force-push a branch in
  `protectedBranches`** — nor main/master when the key is absent.

Recap on success: the commit, branch, push result, and which checks passed or did not run.
