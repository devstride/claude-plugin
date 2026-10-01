---
load: contract
---
# Matching a branch or path against a configured pattern

One rule for every pattern the loop reads: `protectedBranches` entries,
`release.releaseBranchPattern` and `release.releaseBranchFixExclusions`. Every skill that tests a
name against one of them applies THIS rule and never a substring test — an unanchored match is
silent over-match, and here an over-match either protects nothing or refuses a harmless fix.

## The rule

- **The whole string must match** — anchored at both ends. `release/*` does not match
  `foo/release/x`, and `stacks/**` does not match `docs/stacks/x`.
- **`*` matches within ONE path segment** (any run of characters except `/`, at least one).
  `release/*` matches `release/26-10-02`, never `release` or `release/` or `release/a/b`.
- **`**` matches across segments** (any run of characters, `/` included, at least one).
  `stacks/**` matches `stacks/api.ts` and `stacks/a/b/c.ts`, never `stacks` itself.
- **`<YY-MM-DD>`** (any date token spelled like `branchNaming.dateFormat`) matches exactly two
  digits, a hyphen, two digits, a hyphen, two digits.
- **A trailing `[-n]`** matches nothing, or a hyphen followed by one or more digits.
  `release/<YY-MM-DD>[-n]` matches `release/26-10-02` and `release/26-10-02-2`; it does not match
  `release/26-10-02-`, `xrelease/26-10-02`, `release/26-10-02/extra` or `release/`.
- **Anything else is literal**, including `.`: `sst.config.ts` matches only that path.
- **An entry with no wildcard or token is an exact name**, exactly as before patterns existed — a
  configuration that lists only names behaves as it always did.

A shell `case` statement or `[[ == ]]` is NOT this rule (its `*` crosses `/`); translate the
pattern to an anchored regular expression — `*` → `[^/]+`, `**` → `.+`, `<YY-MM-DD>` →
`[0-9]{2}-[0-9]{2}-[0-9]{2}`, `[-n]` → `(-[0-9]+)?`, every other character escaped — and test
with `grep -Eq '^<regex>$'`.

## Protected and merge-only heads

**Protected** — never rebased, amended or force-pushed, never `--delete-branch`ed by a pull-request
merge, and never written onto by the lessons store: `release.releaseSource`,
`release.productionBranch`, any name matching a `protectedBranches` entry, any name matching
`release.releaseBranchPattern`, and `supportTrain.branch`. The last two are protected by the key
alone, whether or not `protectedBranches` lists them. **Merge-only** — a protected head, or a head
the caller declared `merge-only: true` (the sync of production into the source, the support train's
snapshot): its merge commits are the record, so a rebase would destroy them.

What `review` does with one at step 7.1 when the base has advanced:

- **A release branch** (the caller declared `release-branch: true`) → hand back to `release`, whose
  hotfix rule merges the production branch in and re-enters review.
- **The support train, or a declared merge-only head** → no refresh: continue to 7.1b. GitHub
  tests the pull request's merge with its base, so CI still covers the combination; a merge
  conflict STOPS for the operator, never auto-resolved.
- **Any other protected head** → STOP; the owner decides.

**On a release-branch head, or a head whose caller declared `fix-exclusions: true` (the support
train's snapshot), every fix commit first passes the fix-exclusion check**
(`${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-branch.md` §3) — in `review` step 5 as
much as in `release`; a match is refused and handed back to `release`.

## Fixtures

| Pattern | Matches | Does not match |
| --- | --- | --- |
| `release/<YY-MM-DD>[-n]` | `release/26-10-02`, `release/26-10-02-2` | `release/26-10-02-`, `xrelease/26-10-02`, `release/26-10-02/extra`, `release/` |
| `release/*` | `release/anything` | `release`, `a/release/b`, `release/a/b` |
| `stacks/**` | `stacks/x.ts`, `stacks/a/b.ts` | `docs/stacks/x`, `stacks` |
| `sst.config.ts` | `sst.config.ts` | `sstXconfigXts`, `apps/sst.config.ts` |

## Cited by

- `skills/release/SKILL.md` — the protected-head and fix-exclusion rules.
- `skills/release/references/release-branch.md` — the cut, the fix-commit check and the deletion.
- `skills/review/SKILL.md` — the protected-head test (step 5, the lessons write and step 7.1).
- `skills/build-item/SKILL.md` — `--delete-branch` and the support-train exclusion.
- `skills/push/SKILL.md` — never force-push a protected branch.
- `skills/branch-feature/SKILL.md` — never delete a protected branch.
- `skills/doctor/SKILL.md` — the release-branch protection warning.
