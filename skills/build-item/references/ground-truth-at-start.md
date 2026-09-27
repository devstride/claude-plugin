---
load: contract
---
# Ground truth at the start of a loop — the checkout, then origin before memory

A loop that starts from a memory handoff or a checkout that has sat for a while reasons from a
copy of the repository that no longer exists. Nothing on disk detects this: the stale copy is the
one in the conversation, and every command run against it succeeds. So the first act of a loop is
to refresh from the remote and to re-derive every remembered fact from what is there now.

## Take the checkout first — the lease protocol

A clean tree does not mean a checkout is free: a release can hold one detached for hours, another
session can be running tests or a dev server in it, and two sessions can both see "clean" before
either switches branch. So when the repository's `conventionsDoc` or config declares a fixed pool of
checkouts, a session works only in a pool member it holds under a LEASE, and never creates another
worktree or local instance (`localEnvironment.create`, `git worktree add`, a worktree-isolated
agent) unless the owner asks for one in the current conversation — a busy pool means asking the
holder or the owner, not minting a new copy. Which checkouts form the pool, the lease file's name
and the hand-back ref are the repository's to state; read them from its conventions, never assume
them.

- **Take it atomically.** The lease is a file inside that checkout's OWN git directory
  (`git -C <dir> rev-parse --absolute-git-dir`), so it never dirties the tree, created under
  `set -o noclobber` so the create fails if the file exists and exactly one session wins. It
  records who holds it, for what, and since when.
- **Won the lease, then check the tree.** Dirty, or checked out on any branch but the base (detached
  is fine) → a session from before the lease rule may be mid-flight there: remove your lease and take another
  member. A lease that already exists is BUSY: read who holds it and pick another member or ask
  them. Never delete someone else's lease; a stale one is the owner's call.
- **Hold it across branch switches** — the lease, not the branch, makes the checkout yours.
- **Hand it back** when the work merges or is handed over: stop every process you started there
  (test runs, dev servers, watchers), leave it clean and detached at a freshly fetched base, then
  remove the lease. An owner-approved extra worktree is removed by the session that made it when
  its approved purpose ends.

Without a declared pool, the current checkout is the only environment and no lease is taken.

## The procedure

1. `git fetch --prune origin` — before reading a branch, a log, or a pull-request list.
2. Look at what OTHER people (and other sessions of yours) landed on the branches this run will
   touch — the base branch, and the release-unit integration branch once one is resolved:

   ```bash
   git log --format='%h %an %ad %s' --date=relative \
     origin/<branch> --since='<handoff timestamp, else 6 hours ago>'
   ```

   A branch push by another author, an open pull request from a branch that is not yours, or a
   merge you did not make is evidence that another session is active. **Say so explicitly** —
   "another session merged X to develop 40 minutes ago" — before touching that branch. Silence
   here reads as "nothing happened".
3. Treat every fact carried in from memory as a CLAIM: the integration branch's name, the last
   story that shipped, which pull requests are open, "nothing else has landed". Verify each
   against `origin` or `gh` before acting on it, and when the two disagree the remote wins and the
   memory entry is corrected at the next handoff write.
4. State what was verified, in one line, and what could not be — an unverified fact stays labelled
   unverified in every message that repeats it.

## Why this is a step and not a habit

Two shapes of failure, both quiet:

- A session read "the documentation was never updated" off its own checkout and began writing
  duplicate pages, when a peer session had published them an hour earlier. The local files were
  simply behind.
- A release was assured that "nothing merges under this release" — from memory — while a peer
  session had already merged a release unit into the source branch. The assurance was retracted
  mid-release, after it had been repeated to the owner.

Neither is caught by a diff against `HEAD`, because the checkout can be current while the
conversation is not. Only a fetch plus a fresh read of the remote catches them, which is why the
fetch is the first command of the loop rather than something `branch-feature` happens to do
later.

A repository can also opt in to a bounded fetch at every session start
(`localEnvironment.fetchOnSessionStart`, honoured by `hooks/version-check.sh`) — it shortens the
window but does not replace this step: a session that has been running for hours is exactly the
one whose session-start fetch is stale.

## Cited by

- `skills/build-item/SKILL.md` — step 0, before selecting the story, and the checkout-pool floor
  (the lease protocol).
- `skills/release/SKILL.md` — step 0, alongside the branch sync.
