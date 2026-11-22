---
load: contract
---
# Cut the release branch — the protected unit the release promotes

`release-steps`' `release-branch@1` step. The naming, the protection and the fix-exclusion check
are `${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-branch.md` §2 and §3, cited, not
copied; names are matched by `${CLAUDE_PLUGIN_ROOT}/skills/release/references/branch-patterns.md`,
never by substring.

1. **Config wins.** Load `.claude/ds-config.json`. No `release.releaseBranchPattern` →
   `NOT CONFIGURED`: the release pull request's head is `release.releaseSource`.
2. **An adopted or merged release is never cut again**
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`): shape `ADOPTED` or
   `MERGED`, or a release the tower claim adopted (the payload's `tower` says `adopted: true`) →
   `ADOPTED`, naming its branch. One the tower claim adopted is the branch the provider's local
   record names, and it gets the adoption check of `release-branch.md` §3 here, since the shape
   step never read it: a match → `REFUSED`, naming the files (abandon that branch and cut again).
3. **Scope `cut-to-deploy` with a `claims` block:** the tower was just claimed, and the release
   this run waited behind may have synced fixes into the source. Level the train again first, by
   `release-branch.md` §1 step 7's rule, under the train claim this run still holds.
4. **`<sourceHead>`** is the SHA the delta step recorded (its `sourceHead` evidence line, read
   back from the run's `status`), never a re-read source tip that another session's fetch may
   have moved. Only when the run's record no longer holds it: fetch, take the
   `origin/<releaseSource>` tip, and say it was read again.
5. **Name** it by `release-branch.md` §2: the pattern with today's date, `-2`, `-3` and so on
   only for a `[-n]` pattern whose name is taken. Without `[-n]` a taken name → `NAME TAKEN`. A
   branch of today's name already on origin AT `<sourceHead>` with no pull request is this run's
   own earlier attempt: answer `CUT` for it, never a second branch. Check every generated name
   against the pattern before pushing it.
6. **Heartbeat the tower** (`cut --branch <name>`) before the push, only when this session holds
   it (`resume-rules.md` "Heartbeats": scopes `release` and `cut-to-deploy`). Exit 4 is a stop.
7. `git switch -c <name> <sourceHead> && git push -u origin <name>` → `CUT`, naming the branch;
   the evidence names the SHA. The cut point goes into the pull request's marker when it opens.
8. **From here the branch is protected**: new commits only, each one first passing the
   fix-exclusion check (`release-branch.md` §3); never rebased, amended, force-pushed or deleted
   outside the one step that deletes it. Merges into the source after the cut ship in the NEXT
   release.

## Verdict

`RELEASE BRANCH: CUT <branch> | ADOPTED <branch> | NOT CONFIGURED | NAME TAKEN <branch> | REFUSED <files>`

## Result

`state`: `cut`, `adopted`, `not-configured`, `name-taken` or `refused`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
