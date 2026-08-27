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
2. **Recommend stopping any running dev server BEFORE the branch switch.** Moving the checkout
   from the development branch back to production code underneath a running server, or a
   database migrated to the development branch's schema, is a common source of confusing
   failures. You cannot stop it for the user — it runs in their terminal — so remind them now,
   while there is still time to act on it.
3. If no branch name argument is provided, ask the user for one.

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

**Local environment.** Now that the branch exists, bring the local environment back into step with
production code. Read `localEnvironment` from `.claude/ds-config.json`.

**This is a BACKWARD transition, and that decides which commands to run.** A hotfix branches from
the production branch, which is OLDER than whatever the instance has been living on. `migrate` and
`seed` almost always only go forward — migrations do not un-apply, and a seed rewrites rows, not
schema — so running them here leaves the instance schema-AHEAD of the code it is now running, and
the hotfix can validate against a schema production does not have, or fail for reasons that have
nothing to do with the fix.

So: when `recreate` is set, use it — a fresh instance built from the hotfix base. Prefer the form
that stands up a NEW instance over one that destroys the instance the session is working in.
Fall back to `migrate` then `seed` (in that order — a seed against a stale schema fails or lies)
ONLY when `recreate` is `null` AND you can say why the schema has not diverged; **say which path
you took and why**, because "the environment was reset" reads identically either way and only one
of them is sound. Then restart the dev server pre-flight step 2 asked the user to stop.

When the block is absent, or every command is `null`, the procedure is repo-specific and lives
with the repo, not in this skill: say so and ask rather than guessing, and never invent a reset
command.

A PR is NOT opened here — a freshly-created branch has no commits ahead of the
production branch, so there is nothing to compare. A hotfix merges back to the
production branch, not the development branch — open the PR to production with **`/devstride:pr`**
when the fix is ready, so it gets the standard draft-first, review-before-CI treatment — a
review-fix push on a non-draft PR would restart CI, which is exactly what the
draft hold exists to prevent.
If you open it by hand, use `gh pr create --base master` with `--draft` iff the repo holds CI
on drafts (`review.openPullRequestsAsDraft`, true by default) — never `--fill`.

## After

- Confirm you're on the new hotfix branch (`git rev-parse --abbrev-ref HEAD`).
- Confirm the branch was created and pushed; report the full new branch name and
  what happened at each step.

## On failure

- If any step fails, do NOT strand the user — and note that steps 1-2 leave the checkout ON the
  production branch, so a failure there is especially easy to overlook. Report exactly which step
  failed and its output, say which branch the checkout is on now, and ask how to proceed before
  making further changes.
- The previous branch is NOT deleted — keep it until the hotfix is merged.
