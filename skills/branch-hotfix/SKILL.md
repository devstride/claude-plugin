---
name: branch-hotfix
description: Create a new hotfix branch off a fresh copy of the production branch, for urgent fixes that must not carry unreleased work
---

Create a new hotfix branch off a fresh copy of the production branch. Use for urgent fixes that
must branch from production code rather than from the development branch — a hotfix cut from the
development branch would drag every unreleased change along with it.

Branch name argument: $ARGUMENTS

**Repo config.** The production branch this hotfix cuts from, the protected-branch list, and the branch-naming prefix/date live in **`.claude/ds-config.json`** at the repo root (`hotfixBaseBranch`, `protectedBranches`, `branchNaming`). Load it first and treat it as authoritative: wherever a step below names `master` as the production/base branch, substitute `hotfixBaseBranch`; derive the branch prefix and date format from `branchNaming` (the hotfix pattern keeps its own `/hotfix/` infix). The literals shown inline are the plugin's shipped defaults, kept for readability — **if the file disagrees, the file wins**. If the file is absent, fall back to the inline literals and say so.

## Pre-flight (verify BEFORE touching anything)

1. **Working tree must be clean** — run `git status --porcelain`. If there are
   uncommitted changes, STOP and ask whether to stash or commit first. Do NOT
   carry changes onto the production branch.
2. If no branch name argument is provided, ask the user for one.

## Steps

1. `git checkout master`
2. `git pull` to get the latest production code.
3. Create the hotfix branch off the production branch with the naming convention:
   - Format: `<user-prefix>/hotfix/<MM-DD-YY>/<branch-name>`
   - Derive `<user-prefix>` from the local git identity: first name from
     `git config user.name`, lowercased (e.g. "Jane Doe" → `jane`). If
     empty or ambiguous, ask the user what prefix they want.
   - Use today's date in MM-DD-YY format.
   - Use the provided argument as the branch-name suffix.
   - Example: "Jane Doe" → `jane/hotfix/01-23-26/fix-login-crash`
4. Push the new branch and set upstream: `git push -u origin <new-branch-name>`

**Local environment.** A hotfix moves the checkout from the development branch back to production
code, which can leave a running dev server or a locally-migrated database out of step with the
tree. If this repo has a local-environment reset or reseed procedure, run it now — that procedure
is repo-specific and lives with the repo, not in this skill. At minimum, stop any running dev
server before switching branches and restart it afterwards.

A PR is NOT opened here — a freshly-created branch has no commits ahead of the
production branch, so there is nothing to compare. A hotfix merges back to the
production branch, not the development branch — open the PR to production with **`/devstride:pr`**
when the fix is ready, so it gets the standard draft-first, review-before-CI treatment — a
review-fix push on a non-draft PR would restart CI, which is exactly what the
draft hold exists to prevent.
If you open it by hand, use `gh pr create --base master` with `--draft` iff the repo holds CI
on drafts (`review.openPullRequestsAsDraft`, true here) — never `--fill`.

## After

- Confirm you're on the new hotfix branch (`git rev-parse --abbrev-ref HEAD`).
- Confirm the branch was created and pushed; report the full new branch name and
  what happened at each step.

## On failure

- If any step fails after you've left the production branch, do NOT strand the user. Report
  exactly which step failed and its output, and ask how to proceed before making
  further changes.
- The previous branch is NOT deleted — keep it until the hotfix is merged.
