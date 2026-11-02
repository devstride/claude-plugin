---
name: pre-ship
description: "Step: select or run the repository's local pre-ship checks (preShipChecks) for a pull request or a release, and print one verdict."
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/step-skills.md` first: the rule every step skill follows.

Arguments: $ARGUMENTS — `pr|release`, `select|run`, and the final diff's base and head SHAs.

## Verdict

`PRE-SHIP SELECTED: <names> | PRE-SHIP: NOTHING TO RUN` and `PRE-SHIP: PASS (<n> ran) | PRE-SHIP: FAIL <name>`

## Select

Names print in array order. No `preShipChecks` → `NOTHING TO RUN`, an explicit no-op.

- **`pr`**: `when` ∈ {`perPr`, `always`}. A non-empty `pathGlobs` must match the FINAL changed
  files from a **SHA-pinned three-dot local diff** — never `gh pr view --json files` or REST
  pull-files (both capped) — renames on BOTH source and destination; empty → every pull request.
  **Never narrow a glob to skip a run.**
- **`release`**: `when` ∈ {`releaseOnly`, `always`}.
  **Run each selected entry UNCONDITIONALLY** — except a `releaseOnly` entry with
  `onlyWhenTouched: true`: it runs only when the release diff matches its `pathGlobs`.

## Run

Select again; run matches **sequentially, in array order** (no dedup, no short-circuit), each in
the BACKGROUND with a long timeout (a foreground kill looks like a clean pass), `timeoutNote`
first. `pr`: after `verify.test`. `release`: export `RELEASE_CLASS` from `classify-release`
(unknown → `full`).

- All green → `PASS (<n> ran)`. **Red → `FAIL <name>`** with the failing spec names, a block; so
  is a command that does not resolve or dies without a result.
- Evidence per entry: name, command, pass or fail, file and test counts. A waiver exists only at
  `release` scope, on the owner's explicit "skip <name>": recorded, never assumed.

Their CI check is EXPECTEDLY absent: never request, rerun or wait on it; never "covered by CI".
