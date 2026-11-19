---
name: branch-feature
description: "Create a feature branch off the working base, named by the repository's convention."
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/step-skills.md` first: the rule every step skill follows.

**Goal:** a correctly named feature branch, cut from a freshly pulled working base and pushed with
its upstream set. Arguments: $ARGUMENTS — the branch name, then optionally `base: <branch>`, the
working base to cut it from (the Build workflow passes `I<number>-<slug> base: <working base>`).
No name → ask for one, standalone only.

## Verdict

`BRANCH: CREATED [<branch>] | EXISTS [<branch>] | REFUSED [<reason>]`

## Rules

- **Config wins.** Load `.claude/ds-config.json` first (`baseBranch`, `integrationBranch`,
  `branchNaming`, `protectedBranches`); every literal below is a shipped default kept for
  readability — **if the file disagrees, the file wins**. No file → use the defaults and say so.
- **Working base**, in precedence: (1) the `base:` the CALLER passed — the Build workflow's branch
  step, passing the working base explicitly, as `build-item` derived it (the story's epic integration branch; for
  a one-off the release train when `releaseTrain.branch` is set, else `baseBranch`); (2) config
  `integrationBranch` when non-null; (3) `baseBranch`. An integration branch must already exist on
  the remote (`build-item` step 0 creates the epic branch); if checking it out fails, answer
  `REFUSED` and tell the caller to create it off `baseBranch` — never fall back to develop silently.
- **Stay in the checkout you hold.** Branch inside the current checkout (under `build-item`'s
  checkout-pool lease when the repo declares a pool); this skill never creates a worktree or
  instance.
- **Never carry changes.** `git status --porcelain` dirty → `REFUSED`, the question (stash or
  commit?) in the reason; a step never asks a flow question its caller owns.
- **Name**: `branchNaming` in config; default `<user-prefix>/<date>/<branch-name>` with the date in
  `branchNaming.dateFormat` (shipped default `MM-DD-YY`, today) and `<user-prefix>` the first name
  from `git config user.name`, lowercased ("Jane Doe" → `jane/03-14-26/new-feature`); empty or
  ambiguous → `REFUSED`, asking for the prefix.
- **Safe to re-run.** A branch of that name already on origin or local, any date
  (`<user-prefix>/*/<branch-name>`: a resumed story, or one moved to another base) → check it out,
  `git pull --ff-only`, and answer `EXISTS`; never cut a second one. A pull that cannot
  fast-forward (a local branch rewritten and never pushed) → `REFUSED`, naming both heads; never
  merge or reset to get past it.
- **Never delete the previous branch automatically** — keep it until its PR merges. Only on an
  explicit request: `git branch -d <previous>` (`-D` only once confirmed), and never a branch
  matching `protectedBranches` (anchored, per
  `${CLAUDE_PLUGIN_ROOT}/skills/release/references/branch-patterns.md`) or an active
  `integrationBranch`.

## Steps

1. Check the tree is clean; note the current branch (`git rev-parse --abbrev-ref HEAD`); look for
   an existing branch of this name.
2. `git checkout <working base>` then `git pull`.
3. `git checkout -b <new-branch>` then `git push -u origin <new-branch>`.
4. Confirm it was created and pushed; report the full branch name.

## Result

After the verdict and its evidence, one fenced `json` block: `branch` (the full name), `base` (the
working base) and `created` (`false` when it existed).
