---
name: branch-hotfix
description: Create a new hotfix branch off a fresh copy of the production branch, for urgent fixes that must not carry unreleased work
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

**Goal:** a correctly named hotfix branch cut from a freshly pulled production branch and pushed,
with the local environment brought back in step with production code — never carrying the
development branch's unreleased work. Branch name argument: $ARGUMENTS (none → ask for one).

## Rules

- **Config wins.** Load `.claude/ds-config.json` first: `hotfixBaseBranch` (shipped default
  `master`) is the base wherever `master` appears below; `protectedBranches`; `branchNaming`;
  `localEnvironment`; `stage`. Inline literals are defaults — **if the file disagrees, the file
  wins**; no file → defaults, said so.
- **Clean tree first.** `git status --porcelain` dirty → STOP and ask whether to stash or commit;
  never carry changes onto the production branch.
- **Recommend stopping any running dev server BEFORE the switch** — production code under a server
  or a database migrated to the development schema causes confusing failures. It runs in the user's
  terminal, so remind them now; you cannot stop it.
- **Name**: `<user-prefix>/hotfix/<date>/<branch-name>` — the `/hotfix/` infix is fixed; the prefix
  and the date format come from `branchNaming` (`branchNaming.dateFormat`, shipped default
  `MM-DD-YY`, today). `<user-prefix>` = first name from `git config user.name`, lowercased
  ("Jane Doe" → `jane/hotfix/01-23-26/fix-login-crash`); empty or ambiguous → ask.
- **Never delete the previous branch** — keep it until the hotfix merges.
- **No PR here** — a new branch has nothing ahead of production. When the fix is ready open it to
  the production branch with **`/devstride:pr`** for the draft-first, review-before-CI treatment (a
  review-fix push on a non-draft PR restarts CI). By hand: `gh pr create --base <hotfixBaseBranch>`
  with `--draft` iff the repo holds CI on drafts (`review.openPullRequestsAsDraft`, default true),
  never `--fill`. Once it merges, an open release branch (`release.releaseBranchPattern`) must take
  it too: `release` merges the production branch into that branch and re-reviews it — never a
  rebase.
- **On failure** name the failed step and its output, say which branch the checkout is on now (a
  failure in step 1, or in step 2 before the branch exists, leaves it ON the production branch —
  easy to overlook), and ask before changing anything else.

## Steps

1. `git checkout <hotfixBaseBranch>`, then `git pull`.
2. `git checkout -b <hotfix-branch>`, then `git push -u origin <hotfix-branch>`.
3. Bring the local environment in step with production code (below).
4. Confirm the current branch (`git rev-parse --abbrev-ref HEAD`) and the push; report the full
   branch name, what happened at each step, and which environment case was taken.

## The local environment — a BACKWARD transition

**Name the stage first**, when the repo has a `stage` block: run `stage.resolve` and say "this
checkout deploys to `<stage>`". A result in `stage.productionStages` → **STOP and ask before any
environment command** — a `recreate` aimed at production is the worst outcome here and no config
value pre-authorizes it. No block or an empty result → carry on (a warning, never a new gate).

The production branch is OLDER than what the instance has been running. `migrate` and `seed` only go
forward, so running them leaves the instance schema-AHEAD of the code — the hotfix then validates
against a schema production does not have. **An ABSENT `localEnvironment` member is the shipped
`null`** (every config written before `recreate` existed omits it) — read every missing member as
`null` throughout. Three cases:

1. **`recreate` set** → run it after substituting its placeholders — **never pass one through to a
   shell** (`<base>` unexpanded is input redirection and reads as a broken environment). `<base>` =
   the fetched `hotfixBaseBranch` ref (a stale tracking ref rebuilds old production); `<branch>` =
   the new hotfix branch; **`<name>` per `localEnvironment.recreateMode`, the ONLY thing that says
   what the command does — never inferred from the command text** (a wrapper is opaque, and both
   wrong guesses do damage):
   - `"newInstance"` → a NEW name (the hotfix item number is an obvious one); then move the session
     into the instance it creates;
   - `"inPlace"` → the instance the session is ALREADY in, named by running
     `localEnvironment.instanceName`; null or failing → **STOP and ask** (a directory-name guess
     silently resets someone else's instance);
   - mode absent/`null` while `recreate` contains `<name>` → **STOP and ask**, explaining both
     values; never pick. (No `<name>` → no mode needed.)

   The session must end in a WORKING instance — never in a directory whose instance was torn down,
   or on a detached HEAD the rebuilt instance no longer belongs to.
2. **`recreate` absent/`null` and you can say WHY the schema has not diverged** (the instance stayed
   on the production line, or there is no schema) → `migrate` then `seed`, in that order (a seed
   against a stale schema fails or lies).
3. **`recreate` absent/`null` and the schema HAS diverged or you cannot tell** → **STOP and ask.**
   Never migrate forward and carry on. Name the missing `localEnvironment.recreate`, offer the manual
   route (a fresh instance from the hotfix base), and continue only once the user confirms a rebuild
   or says to proceed anyway.

**Say which case you took and why** — "the environment was reset" reads the same for all three and
only two are sound. Then restart the dev server you asked the user to stop. Block absent, or every
command `null` → the procedure is repo-specific: say so and ask; never invent a reset command.
