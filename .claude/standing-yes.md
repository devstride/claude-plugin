# Standing yes for merges into `main`

Status: in force

Given by Phil Reynolds, the repository owner, on 2026-11-08, in his words:

> "once the safety checks are all green I want the standing yes to apply. The audit log should
> still show that I approved (which I did and am) but I don't actually want to have to manually
> approved anything beyond kicking off the build."

## What it covers

A pull request into `main` of this repository, merged by `plugin-release merge <pr>`
(`.claude/skills/plugin-release/SKILL.md`), when every condition below holds at the exact head it
merges. The per-change authorization is the owner starting the build of the tracked work item; this
standing yes replaces only the per-pull-request question that used to follow it.

## Conditions (all of them, at the exact head merged)

1. The pull request is open, not a draft, based on `main`, from a branch of this repository (never
   a fork), and authored by a repository admin.
2. It changes neither this file nor `.claude/skills/plugin-release/`: a change to the standing yes
   or to the step that applies it always needs the owner's own yes on that pull request.
3. The review settled clean: the last local round (Claude and Codex) found no P1 and no serious P2,
   and the head carries a repository admin's `devstride/reviewed` status for that pull request into
   `main` (`skills/review/scripts/reviewed-status.py verify`).
4. The version-bump, neutrality and public-hygiene checks pass, and `scripts/validate.sh --needles`
   passed on the head.
5. `skills/pr/scripts/merge-gate.py <pr> <head> --all-green` prints `MERGE`: every check, required
   or not, green on that exact commit.

## The audit trail

- This file, committed, dated and in the owner's words.
- The tracked work item, started on the owner's direction.
- On each pull request merged under it, a comment marked `<!-- devstride:standing-yes -->` naming
  this standing yes, the head, the checks and the review.
- A weekly report of every merge into `main`, saying which merged under this standing yes and which
  on a per-pull-request yes, for the owner to skim.

## Revoking it

Change `Status: in force` to `Status: revoked <YYYY-MM-DD>` (or delete this file) through a pull
request. From that merge on, every pull request needs the owner's own yes again.
