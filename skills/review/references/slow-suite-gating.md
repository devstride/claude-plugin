# Slow-suite gating — the full applicability procedure

Some repos have a CI suite too slow or too expensive to run on every pull request — a large
end-to-end run, a full-dataset integration build, a cross-browser matrix. `verify.skipDuringStoryBuilds`
in `.claude/ds-config.json` lists those suites, and each entry declares WHEN its check is
mandatory. This file is the exact procedure for deciding that, and the failure modes it avoids.

**If `verify.skipDuringStoryBuilds` is empty — the default — none of this runs.** There is no
applicability to compute, no label to add, and no mapped check to wait on. Skip straight past it.
A repo with no slow cloud suite is the normal case; a slow suite that runs LOCALLY instead belongs
in `preShipChecks`, walked by `pr` step 2b and `release` step 2b, and never produces a CI check
at all.

**Each entry's three cases must mirror the repo's own workflow file exactly.** If you add,
remove, or narrow a case here, change the workflow trigger in the same commit — otherwise the loop
waits forever on a check that never runs, or merges without one that should have gated it.

## Evaluate in this order

### 1. BASE — short-circuits everything

The PR's base resolves to an entry in `alwaysRunWhenBase` (typically `productionBranch`) →
APPLICABLE unconditionally, **paths irrelevant**. Skip the whole path computation and go to the
check mapping. A docs-only or frontend-only release still runs the full suite; that guaranteed run
at the production boundary is exactly what earns the development-side path filter its narrowness.

### 2. MANUAL

The PR carries `manualTriggerLabel`, or the user asked for the suite this run.

**An instruction alone is NOT enough — materialize it as the label** before the ready-flip:

```
gh pr edit <pr> --add-label <manualTriggerLabel>
```

The workflow has no visibility into what a user told you; it reacts only to the label. Mark a
suite mandatory without adding the label and its check never runs, so the settle loop waits on it
indefinitely. Adding it after the flip works but costs a second workflow run.

### 3. PATHS

Resolve the COMPLETE, SHA-pinned final changed-file set:

1. After the last review-fix push, capture the PR's `baseRefName`, `headRefOid` and `changedFiles`.
2. Fetch the **CURRENT** base ref and `refs/pull/<pr>/head`; record those fetched OIDs as the
   snapshot. **Do not substitute the PR's historical `baseRefOid` for the current base tip.**
3. `git diff --name-status -z --find-renames <baseOid>...<headOid>`.
4. Treat `runWhenChangedPaths` as glob patterns — not literal strings — matched with the same
   semantics as the workflow's paths filter.
5. For renamed/copied entries, glob-match **BOTH source and destination**, so a file moved OUT of
   a watched directory stays applicable.
6. Re-read `baseRefName`, `headRefOid` and the remote current-base OID afterward; discard and
   restart the decision if the base was retargeted or either OID moved.

**Never** use `gh pr view --json files` (100-file cap) or the pull-files REST response (3,000-file
cap) as the sole source for an omission decision — this local three-dot diff has no cap. If the
exact snapshot cannot be fetched or diffed, do NOT guess non-applicable; surface the failure.
Recompute after every later push.

## None of the three matched → NON-APPLICABLE

Omit the suite completely. A skipped or absent named check is expected and does not make CI
unsettled. Do NOT request it, rerun it, wait on it, add a dummy matching file, run it against
another SHA, or treat GitHub's advisory `UNSTABLE` state as evidence that an omitted suite is
required.

Under a well-scoped path filter this is the COMMON outcome — most stories will not touch the
watched paths. Do not treat the suite's absence as suspicious.

## Applicable → map the base

Resolve the PR base through `ciChecksByBase`: `baseBranch` means the repo's configured development
branch, `productionBranch` means `release.productionBranch`. Require ONLY the check names mapped to
that base. Checks mapped to another base are expected to skip — a narrower per-PR gate commonly
skips on the production branch, where a stricter superset job runs instead.

**No mapped base = story-level exemption.** A story PR into an integration branch does not wait on
the slow suite even when its own diff matches; the accumulated release diff is evaluated afresh
when the integration branch targets `baseBranch`.

## The one case that must stop rather than spin

For a PR above GitHub's 3,000-file pull-files limit, the workflow's `paths-filter` can miss a match
that the complete local diff finds. If that happens and the mapped check is absent or skipped, do
not spin and do not relabel the suite non-applicable: STOP with the explicit CI path-detection
limitation, so the gate can be repaired or run by an owner-approved route.
