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
`release.fullRelease.approveBeforeJoining` is `false` (absent means on) — **as the BASE branch's
committed config says**: a branch cut before the rule, or one that edits it, is still asked.
Otherwise nothing here runs and the release asks as before. A merge into the production branch
is never asked here (a hotfix is never held), and neither is content already on the train or in
production: it joined before.

## The check — never by eye

`python3 ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/migration-approval.py check --base
origin/<base> --head <head> [--already origin/<branch>]…`, after fetching those refs. The rule is
read from the base's committed config and the approvals from the head's, never the work tree. It
answers `{applies, approved, reason, unapproved: [{path, blob, status}]}`: exit 0 approved or not
applicable, **2 unapproved, 1 could not tell — and wherever a merge would follow, 1 is treated as
unapproved.** `--already` names the release train (when the base is the base branch) and the
production branch.

## Where it runs

- **BEFORE a pull request into the train or the base branch is cut**, on the head as it will be
  merged — a release unit (`build-item` step 8), a plan release, a one-off or infrastructure
  change (`pr`): run it every time, whatever the diff looks like, so the question is put before
  review and the ready flip, never after them.
- **Again by the merge gate**: `merge-gate.py` runs it and prints no `MERGE` line for an unapproved
  head.

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
  again. A `deleted` or `not-a-file` answer cannot be approved by content: the owner merges that
  pull request themselves, on their own yes for it; the loop never does.
- **Nobody is answering** (an unattended run) → write ONE notice on the unit
  (`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/needs-you.md`, kind NOTICE: approving a
  migration), send one notification where the harness has a notification tool, report the unit as
  "release-ready, waiting for the owner's yes on a migration", and move on to the next unit.
  **Never wait, never merge.** With no `needsYou.label`, the report line alone carries it.

## The hold record

The trailers on the approving commit say which unit waited, from when, until when:
`Migration-Approval-Unit`, `Migration-Approval-Asked`, `Migration-Approval-Approved` (ISO times,
UTC). They are read from git history alone, for example `git log
--format='%(trailers:key=Migration-Approval-Unit,valueonly)'`.

## Cited by

- `skills/build-item/references/epic-release-steps.md`, `skills/build-item/references/plan-scope.md`
  and `skills/pr/SKILL.md` (before the cut)
- `skills/pr/scripts/merge-gate.py` (before its `MERGE` line)
- `skills/release/references/auto-start.md` (approving a migration)
- `skills/setup/references/config-defaults.md` (`release.fullRelease.approveBeforeJoining`)
