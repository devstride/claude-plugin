# Standing yes for merges into `main`

Status: in force

Given by Phil Reynolds, the repository owner, on 2026-11-08, in his words:

> "once the safety checks are all green I want the standing yes to apply. The audit log should
> still show that I approved (which I did and am) but I don't actually want to have to manually
> approved anything beyond kicking off the build."

Widened by him on 2026-11-12, in his words:

> "I need you to accept my standing yes in that repo exactly as you do in the main devstride repo."

In the main DevStride repository his standing yes covers every change whose review settled clean
and whose checks are all green at the exact reviewed head, with one carve-out: a database migration
needs his approval of that migration. It makes no exception for instruction files, guard files,
workflows or the release procedure. This repository has no database migrations, so here it covers
every pull request that meets the conditions below.

## What it covers

A pull request into `main` of this repository, merged by `plugin-release merge <pr>`
(`.claude/skills/plugin-release/SKILL.md`), when every condition below holds at the exact head it
merges. The per-change authorization is the owner starting the build of the tracked work item; this
standing yes replaces only the per-pull-request question that used to follow it.

A pull request that changes this file, the release procedure, the checks, the workflows or the
instruction files (`CLAUDE.md`, `AGENTS.md`) is covered like any other. It still cannot change the
rules for its own merge: the merge session reads this file, its procedure and both gate scripts
from `main`, never from the pull request (see below), so a change to them applies only to the
pull requests merged after it.

## Conditions (all of them, at the exact head merged)

1. The pull request is open, not a draft, based on `main`, from a branch of this repository (never
   a fork), authored by the owner's account, with the owner as the author of every commit and the
   only account that pushed to its branch, and linked to a tracked work item whose build the owner
   started.
2. The review settled clean: the last local round (Claude and Codex) found no P1 and no serious P2,
   and the head carries a `devstride/reviewed` status for that pull request into `main`, posted
   under the owner's account after that round.
3. The version-bump, neutrality and public-hygiene checks pass, and `scripts/validate.sh --needles`
   passed on the head, run by the build in its own checkout; the merge session never runs the pull
   request's code.
4. `skills/pr/scripts/merge-gate.py <pr> <head> --all-green`, run from `main`, prints `MERGE`: every
   check, required or not, green on that exact commit. `main` requires `release-guard`,
   `merge-path` and `public-hygiene`, and only org owners can update it, through a pull request.

The merge step runs in a session started in a clean worktree of `main`, and reads this file, its
own procedure and both gate scripts from there, never from the pull request being merged. Right
before merging it checks that `main` hasn't moved since it read this file, and stops if it has, so
a revocation that lands meanwhile stops it. It merges with a merge commit.

## The audit trail

- This file, committed, dated and in the owner's words.
- The tracked work item, started on the owner's direction.
- On each pull request merged under it, a comment marked `<!-- devstride:standing-yes -->` naming
  this standing yes, the head, the checks and the review. A merge on the owner's own yes instead
  carries `<!-- devstride:owner-yes -->` with the reason the standing yes did not apply.
- A weekly report of every merge into `main`, saying which merged under this standing yes and which
  on a per-pull-request yes, for the owner to skim.

## Revoking it

Change `Status: in force` to `Status: revoked <YYYY-MM-DD>` (or delete this file) through a pull
request. From that merge on, every pull request needs the owner's own yes again.
