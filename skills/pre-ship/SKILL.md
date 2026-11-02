---
name: pre-ship
description: "Step: select or run the repository's local pre-ship checks (preShipChecks) for a pull request or a release, and print one verdict."
---

Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/step-skills.md` first: the rule every step skill follows.

Arguments: $ARGUMENTS — scope `pr` or `release`, action `select` or `run`, and the final diff's
base and head SHAs (default: base branch, `HEAD`).

## Verdict

`PRE-SHIP SELECTED: <names> | PRE-SHIP: NOTHING TO RUN` and `PRE-SHIP: PASS (<n> ran) | PRE-SHIP: FAIL <name>`

## Select

Print the selected names in array order. Absent or empty `preShipChecks` → `PRE-SHIP: NOTHING TO
RUN`, an explicit no-op; say so.

- **`pr`**: `when` ∈ {`perPr`, `always`}. A non-empty `pathGlobs` must match the FINAL changed
  files from a **SHA-pinned three-dot local diff** — never `gh pr view --json files` (100-file
  cap) or REST pull-files (3000 cap) — renames on BOTH source and destination; empty → every pull
  request. **Never narrow a glob to skip a run.**
- **`release`**: `when` ∈ {`releaseOnly`, `always`}.
  **Run each selected entry UNCONDITIONALLY** — except a `releaseOnly` entry with
  `onlyWhenTouched: true`: it runs only when the release diff matches its `pathGlobs`.

## Run

Select again; run matches **sequentially, in array order** (no dedup, no short-circuit), each in
the BACKGROUND with a long timeout (a foreground kill looks like a clean pass), each `timeoutNote`
surfaced first. `pr`: after `verify.test`, `RELEASE_CLASS` unset. `release`: export
`RELEASE_CLASS` from `classify-release` (unknown → `full`).

- All green → `PRE-SHIP: PASS (<n> ran)`. **Red → `PRE-SHIP: FAIL <name>`** with the failing spec
  names, a block; so is a command that does not resolve or dies without a result.
- Evidence per entry: name, command, pass or fail, file and test counts. A waiver exists only at
  `release` scope, on the owner's explicit "skip <name>": recorded, never assumed.

Their CI check is EXPECTEDLY absent: never request, rerun or wait on it; never "covered by CI".
