---
load: contract
---
# Open the release pull request — a draft into production

`release-steps`' `release-pr@1` step. The body and its markers are
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-pr.md` "Step 1 — the release-flavored
body", cited, not copied.

1. **Config wins.** Load `.claude/ds-config.json`: `release.productionBranch`,
   `release.releaseSource`, `release.releaseBranchPattern`, `release.clearance`,
   `prBodyTemplate`.
2. **Never a second one**
   (`${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`): shape `ADOPTED` or
   `MERGED`, or a release the tower claim adopted (the payload's `tower` says `adopted: true`) →
   `ADOPTED`, naming its pull request. A pull request this run already opened (open into production, headed by the branch
   this run cut) → `OPENED` for it again; nothing is created.
3. **The head** is the release branch this run cut; with no `release.releaseBranchPattern` it
   is `release.releaseSource`.
4. **The body**, from the delta (recomputed by the rule of
   `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/release-delta.md` over
   `origin/<productionBranch>..<sourceHead>`): `prBodyTemplate.sections` in order, flavored by
   position, ending with the loop marker and, on a release branch, the
   `devstride:release-branch <name> cut <sha>` marker (the cut point, read back on adoption).
   Under the scope `release-pr.md` names, the `devstride:release-holder` marker is written NOW:
   the body is never edited after the ready flip.
5. **Draft whenever pull-request workflows exist** (the draft holds CI until the review's ready
   flip): `gh pr create --draft --base <productionBranch> --head <head>`. With no pull-request
   CI (the fact `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/ci-hold-proof.md` proved)
   omit `--draft` and say `no pull-request CI`. Never `--fill`. Request no cloud review here:
   the review step does, and it alone flips the pull request ready. Pre-ship checks never run
   in CI.
6. **Never `--delete-branch`** a pull request headed by the release source, a release branch or
   any `protectedBranches` match.
7. **Heartbeat the tower** (`pr --pr <n>`) once it is open, only when this session holds it
   (`resume-rules.md` "Heartbeats": scopes `release` and `cut-to-deploy`). Exit 4 is a stop.
8. `OPENED`, naming the number; the evidence gives its address and whether it is a draft.

## Verdict

`RELEASE PR: OPENED <pr> | ADOPTED <pr>`

## Result

`state`: `opened` or `adopted`; `links` beside it holds the pull request's address.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md`
