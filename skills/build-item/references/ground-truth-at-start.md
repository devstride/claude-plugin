# Ground truth at the start of a loop — origin before memory

A loop that starts from a memory handoff or a checkout that has sat for a while reasons from a
copy of the repository that no longer exists. Nothing on disk detects this: the stale copy is the
one in the conversation, and every command run against it succeeds. So the first act of a loop is
to refresh from the remote and to re-derive every remembered fact from what is there now.

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

- `skills/build-item/SKILL.md` — step 0, before selecting the story.
- `skills/release/SKILL.md` — step 0, alongside the branch sync.
