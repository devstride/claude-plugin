---
name: branch-feature
description: Create a new feature branch off develop with proper naming convention
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

**Goal:** a correctly named feature branch, cut from a freshly pulled working base and pushed with
its upstream set. Branch name argument: $ARGUMENTS (none → ask for one).

## Rules

- **Config wins.** Load `.claude/ds-config.json` first (`baseBranch`, `integrationBranch`,
  `branchNaming`, `protectedBranches`); every literal below is a shipped default kept for
  readability — **if the file disagrees, the file wins**. No file → use the defaults and say so.
- **Working base**, in precedence: (1) the base the CALLER passed — `build-item` derives it (the
  story's epic integration branch, or `baseBranch` when the item has no release unit) and says
  "branch off `<name>`"; (2) config `integrationBranch` when non-null; (3) `baseBranch`. An
  integration branch must already exist on the remote (`build-item` step 0 creates the epic
  branch); if checking it out fails, STOP and tell the caller to create it off `baseBranch` — never
  fall back to develop silently.
- **Stay in the checkout you hold.** Branch inside the current checkout (under `build-item`'s
  checkout-pool lease when the repo declares a pool); this skill never creates a worktree or
  instance.
- **Never carry changes.** `git status --porcelain` dirty → STOP and ask whether to stash or commit.
- **Name**: `branchNaming` in config; default `<user-prefix>/<date>/<branch-name>` with the date in
  `branchNaming.dateFormat` (shipped default `MM-DD-YY`, today) and `<user-prefix>` the first name
  from `git config user.name`, lowercased ("Jane Doe" → `jane/03-14-26/new-feature`); empty or
  ambiguous → ask for the prefix.
- **Never delete the previous branch automatically** — keep it until its PR merges. Only on an
  explicit request: `git branch -d <previous>` (`-D` only once confirmed), and never a branch in
  `protectedBranches` or an active `integrationBranch`.

## Steps

1. Check the tree is clean; note the current branch (`git rev-parse --abbrev-ref HEAD`).
2. `git checkout <working base>` then `git pull`.
3. `git checkout -b <new-branch>` then `git push -u origin <new-branch>`.
4. Confirm it was created and pushed; report the full branch name.
