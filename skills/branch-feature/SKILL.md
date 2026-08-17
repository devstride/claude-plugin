---
name: branch-feature
description: Create a new feature branch off develop with proper naming convention
---

Create a new feature branch with the following workflow:

Branch name argument: $ARGUMENTS

**Repo config.** The base branch, branch-naming pattern, and protected-branch list this skill uses live in **`.claude/ds-config.json`** at the repo root (`baseBranch`, `integrationBranch`, `branchNaming`, `protectedBranches`). Load it first and treat it as authoritative: wherever a step below names a concrete branch or naming rule, substitute the matching config value. The literals shown inline are the plugin's shipped defaults, kept for readability — **if the file disagrees, the file wins**. If the file is absent, fall back to the inline literals and say so.

**Working base.** Resolve the branch to base off of in this precedence: (1) an explicit base the CALLER passed you — the `build-item` loop derives a working base (by default the story's **epic integration branch**, `<prefix>/<MM-DD-YY>/<epic-number>-<epic-title-slug>`; plain develop when the item has no Epic) and tells you to "branch off `<name>`"; that wins over config. (2) Otherwise `integrationBranch` if it is set (non-null) in the config. (3) Otherwise `baseBranch`. When the working base is an integration branch (epic-derived or explicit — see the config's `_integrationBranch_readme`), it must already exist on the remote (`build-item` step 0 creates the epic branch before invoking this skill); if `git checkout` of it fails, STOP and tell the caller to create it off `baseBranch` first rather than silently falling back to `develop`. Everywhere a step below says "develop", read "the working base".

1. Check for uncommitted changes with `git status --porcelain`. If the tree is
   dirty, STOP and ask whether to stash or commit first — do not carry changes
   onto the working base.
2. Save the current branch name (`git rev-parse --abbrev-ref HEAD`) for reference.
3. Run `git checkout <working base>` then `git pull` to sync with remote.
4. Create a new branch with the naming convention:
   - Format: `<user-prefix>/<MM-DD-YY>/<branch-name>`
   - Derive `<user-prefix>` from the local git identity: first name from
     `git config user.name`, lowercased (e.g. "Jane Doe" → `jane`). If
     empty or ambiguous, ask the user what prefix they want.
   - Use today's date in MM-DD-YY format.
   - Use the provided argument as the branch-name suffix.
   - Example: "Jane Doe" → `jane/03-14-26/new-feature`
5. Push the new branch and set upstream: `git push -u origin <new-branch-name>`

IMPORTANT:
- If no branch name argument is provided, ask the user for one.
- The previous branch is NOT deleted automatically — keep it until its PR merges.
  If the user explicitly asks, delete it with `git branch -d <previous-branch>`
  (offer `-D` only if they confirm, and never delete develop/master or an active
  `integrationBranch`).
- Confirm the branch was created and pushed; report the full new branch name.
