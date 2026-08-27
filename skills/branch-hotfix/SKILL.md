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

**An ABSENT key is the shipped `null`** — every config written before `recreate` existed omits it
entirely, which is the commonest shape you will meet, not a rare one. Read a missing member as
`null` throughout.

Three cases, and the third is the one that matters:

1. **`recreate` set** → run it. **Substitute the placeholders the contract allows before running
   it, and never pass one through to a shell** — `<base>` reaching `sh` unexpanded is parsed as
   input redirection, and the command fails in a way that reads like a broken environment rather
   than a broken invocation. Bind `<base>` to the hotfix base ref (`hotfixBaseBranch`, fetched —
   a stale tracking ref rebuilds from an old production commit), `<branch>` to the hotfix branch
   just created, and **`<name>` per `localEnvironment.recreateMode`, which is the
   ONLY thing that says what the command does.** Do not infer it from the command text: an opaque
   wrapper (`./scripts/recreate <name> <base>`) reveals nothing, and both wrong guesses are bad —
   treating an in-place command as second-instance leaves the session on the schema-ahead
   database, and the reverse resets an instance somebody is using.
   - `"newInstance"` → bind `<name>` to a NEW name (the hotfix item number makes an obvious one),
     then move the session into the instance it creates.
   - `"inPlace"` → bind `<name>` to the instance the session is ALREADY in, whose name comes from
     running `localEnvironment.instanceName`. If that is null or fails, **STOP and ask** — a guess
     from a directory name resets a different instance, silently, and on a shared machine that is
     somebody else's data.
   - **absent or `null` while `recreate` contains `<name>` → STOP and ask.** Say that
     `recreateMode` is unset and what the two values mean. Never pick one.
   (A `recreate` with no `<name>` needs no mode: there is nothing to bind.)

   **What matters is not how many instances exist afterwards, but that the session is still in a
   working one.** Do not leave the session in a directory whose instance was torn down, or on a
   detached HEAD in a checkout the rebuilt instance no longer belongs to: a config command cannot
   move the caller, so the skill would then check its own postcondition from the wrong place. An
   in-place rebuild of the current instance's database satisfies this and is usually the simplest
   thing a repository can offer.
2. **`recreate` absent or `null`, and you can say WHY the schema has not diverged** (the instance
   has been on the production line all along, or the environment has no schema) → `migrate` then
   `seed`, in that order, since a seed against a stale schema fails or lies.
3. **`recreate` absent or `null`, and the schema HAS diverged or you cannot tell** → **STOP and
   ask.** Do not run migrate+seed, and do not restart the server and carry on: that is precisely
   how a hotfix comes to be validated against a schema production does not have. Say what is
   missing (`localEnvironment.recreate`), offer the manual route — a fresh instance from the
   hotfix base — and continue only once the user confirms the environment was rebuilt or tells
   you to proceed anyway.

**Say which case you took and why.** "The environment was reset" reads identically for all three
and only two of them are sound. Then restart the dev server pre-flight step 2 asked the user to
stop.

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
