---
load: contract
---
# Migration approval before joining — work that needs the owner's yes waits by itself

**Goal:** the release train and the base branch only ever hold work that can ship on the owner's
standing yes. A new or changed migration is asked about while the work still sits on its own
branch, so no release, and no release queued behind it, ever waits for that answer. The release's
own check (`standing-yes.py`, `${CLAUDE_PLUGIN_ROOT}/skills/release/references/auto-start.md`) is
unchanged and stays the backstop that still stops.

## When it applies

With `release.fullRelease.standingYes` true and `release.fullRelease.migrationGlobs` set, unless
`release.fullRelease.approveBeforeJoining` is `false` (absent means on). Otherwise nothing here
runs and the release asks as before. Hotfixes are never asked here, and neither is content
already on the train or in production: it joined before.

## The check — never by eye

`python3 ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/migration-approval.py check --base
origin/<base> --head <head> [--already origin/<branch>]…`, after fetching those refs. It reads the
config committed at the head and answers `{applies, approved, reason, unapproved: [{path, blob,
status}]}`: exit 0 approved or not applicable, **2 unapproved, 1 could not tell — and wherever a
merge would follow, 1 is treated as unapproved.** `--already` names the release train (when the
base is the base branch) and the production branch.

## Where it runs

- **A release unit onto the train or the base branch** (`build-item` step 8, a plan release the
  same way): on the unit's head, BEFORE its release pull request is cut, and again by the merge
  gate before it merges.
- **Any pull request into the train or the base branch**: `merge-gate.py` runs it and prints no
  `MERGE` line for an unapproved head.

## Unapproved: ask, never guess

- **Someone is answering** → ask in the session, once, listing each file with one plain sentence
  on what it does to the database. Only the owner's own words, in the moment, approve; a relayed
  yes, a reply in a tracker thread or an earlier approval of other content never does.
- **On the yes**, for each file: `migration-approval.py entry --head <head> --path <file> --item
  <I#####> --unit <unit> --asked <when the question was first put>` builds the `approvedMigrations`
  entry, the commit subject and three trailers. Add the entry to
  `release.fullRelease.approvedMigrations` in a commit of its own ON THE BRANCH THAT CARRIES THE
  MIGRATION, with that subject and the trailers as the message's last paragraph, so the approval
  travels with the work. Run the check again, then carry on. An edit after approval is unapproved
  again; a `deleted` or `not-a-file` answer cannot be approved by content and merges only on the
  owner's own yes for that pull request.
- **Nobody is answering** (an unattended run) → write ONE notice on the unit
  (`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/needs-you.md`, kind NOTICE: approving a
  migration), send one notification where the harness has a notification tool, report the unit as
  "release-ready, waiting for the owner's yes on a migration", and move on to the next unit.
  **Never wait, never merge.**

## The hold record

The trailers on the approving commit say which unit waited, from when, until when:
`Migration-Approval-Unit`, `Migration-Approval-Asked`, `Migration-Approval-Approved` (ISO times,
UTC). They are read from git history alone, for example `git log
--format='%(trailers:key=Migration-Approval-Unit,valueonly)'`.

## Cited by

- `skills/build-item/references/epic-release-steps.md` (before the cut)
- `skills/pr/scripts/merge-gate.py` (before its `MERGE` line)
- `skills/setup/references/config-defaults.md` (`release.fullRelease.approveBeforeJoining`)
