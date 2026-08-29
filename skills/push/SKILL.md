---
name: push
description: Stage, commit, type-check, and push the current branch following repo commit conventions
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

Load `.claude/ds-config.json` first. Its `verify`, `generated`, `protectedBranches` and
`commitConventions` values are authoritative; absent → use stated fallbacks and say so.

Execute the following git workflow:

1. Run `git add -u` to stage changes to already-tracked files only (do NOT sweep
   in untracked files with `git add .`)
2. Run `git status` to see what's being committed — and **stage any NEW file the change
   requires, BY NAME** (`git add path/to/new-file.ts`). `git add -u` misses new files. Never
   use `git add .`; leave unrelated untracked files alone
3. Run `git diff --cached --stat` to show a summary of staged changes
4. Create a commit with a meaningful message per `commitConventions` (fallback: Conventional
   Commits with the item tag, shaped per `itemTagFormat` — e.g. `[I#####]`, `[PROJ-123]` — so a
   repo whose tracker does not use DevStride-style numbers can still express its own). The item
   tag applies only when the work HAS an associated item —
   an itemless commit (a merge, a repo chore) keeps a meaningful conventional message with no
   tag; never compose an item number to satisfy the format
   - AI attribution trailers are optional. If the active session exposes valid current-session attribution metadata, append `Co-Authored-By:` plus the matching provider-specific session trailer (`Claude-Session:` or `Codex-Session:`). If that metadata is unavailable or incomplete, omit the AI trailers and continue without stopping to ask. Never invent values or reuse stale/example metadata.
   - The "no AI attribution" rule still applies to PR BODIES. Optional attribution belongs only on commits.
5. Resolve the exact type-check command list (`verify.typecheck` array, in order; use
   `verify.typecheckCombined` only when the array is absent). A caller may pass a verification
   receipt. Reuse it only when every validity rule in
   `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/verification-receipts.md` holds for the
   current tree and this exact list. Step 4 normally created a new commit and invalidated an older
   receipt, so run every command unless same-tree proof genuinely exists. With no command, ask
   rather than guessing. After a pass, write/refresh the receipt for downstream callers
6. If the type-check passes, OR the only failures are generated-file errors tolerated by
   `generated.toleratedTypeErrors` in files matched by `generated.paths`:
   - Push to remote with `git push`
   - If push is rejected (non-fast-forward), use `git push --force-with-lease` to force push safely
   - On success, recap the commit, branch, push result and checks that passed or did not run.
7. If TypeScript check fails with non-SDK errors:
   - Do NOT push
   - Report the errors and ask what to do

Do NOT create a pull request. This command stages, commits, and pushes only —
PRs are opened separately when you're ready, not on every push.

Tolerated generated-file errors are defined by config: an error is tolerated only when its file
matches `generated.paths` AND its text matches a pattern in `generated.toleratedTypeErrors`.
With neither key configured, nothing is tolerated — any type error stops the push, which is the
right default: a repo that has not declared generated files has none to forgive. Where they are
configured, fix such an error by re-running `generated.regenCommand`, never by hand-editing the
generated file.

IMPORTANT:

- Always use force-with-lease instead of force for safety
- Only force push if the rejection is due to rewriting history on the current branch
- Never force push to main/master branches
