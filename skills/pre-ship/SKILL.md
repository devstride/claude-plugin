---
name: pre-ship
description: "Step: select or run the repository's local pre-ship checks (preShipChecks) for a pull request or a release, and print one verdict."
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/step-skills.md` first: the rule every step skill follows.

Arguments: $ARGUMENTS — `pr|release`, `select|run`, the final diff's base and head SHAs, and:

- `release run`: the class `classify-release` printed for THIS head (none → `full`).
- `--only <names>`: re-run just those selected entries — review 7.1b's failed/affected re-run.
- `--skip <name>` (repeatable, `release` only): the owner's explicit waiver of that entry.

## Verdict

`PRE-SHIP SELECTED: <names> | PRE-SHIP: NOTHING TO RUN` and `PRE-SHIP: PASS (<n> ran, <k> waived) | PRE-SHIP: FAIL <names>`

## Select

Names in array order; no `preShipChecks` → `NOTHING TO RUN` (an explicit no-op).

- **`pr`**: `when` ∈ {`perPr`, `always`}. A non-empty `pathGlobs` must match the FINAL changed
  files from a **SHA-pinned three-dot local diff** — never `gh pr view --json files` or REST
  pull-files (both capped) — renames on BOTH source and destination; empty → every PR.
  **Never narrow a glob to skip a run.**
- **`release`**: EVERY entry with `when` ∈ {`releaseOnly`, `always`} is selected, so the
  release's hold fires whenever one exists. **Run each selected entry UNCONDITIONALLY** — except
  a `releaseOnly` entry with `onlyWhenTouched: true`: it runs only when the release diff matches
  its `pathGlobs` (`${CLAUDE_PLUGIN_ROOT}/skills/release/references/review-once.md`); a diff that
  cannot be computed runs it. Each that will not run prints as evidence: `skip <name>: the
  release diff touches none of its pathGlobs`.

## Run

Re-select at this head. `--only` keeps just those names; one not selected → `FAIL <name>`, run
nothing. `--skip` on `pr` → refuse; on `release` that entry does not run and prints `WAIVED
<name> — the owner's explicit skip, recorded`: only on the owner's words, never assumed. Run the
rest **sequentially, in array order** (no dedup, no short-circuit), each in the BACKGROUND with a
long timeout (a foreground kill looks like a clean pass), `timeoutNote` first. `pr`: after
`verify.test`. `release`: export `RELEASE_CLASS` as the class passed for this head — never one
taken for an earlier head.

- All green → `PASS (<n> ran, <k> waived)`. **Any entry red, unresolvable or dead without a
  result → `FAIL` naming EVERY failed entry**, with the failing spec names: a block.
- Evidence per entry: name, command, result, file and test counts; each skip and waiver above.

Their CI check is EXPECTEDLY absent: never request, rerun or wait on it, or say "covered by CI".
