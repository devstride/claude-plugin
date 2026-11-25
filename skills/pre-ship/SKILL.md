---
name: pre-ship
description: "Step: select or run the repository's local pre-ship checks (preShipChecks) for a pull request or a release, and print one verdict."
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/step-skills.md` first: the rule every step skill follows.

Arguments: $ARGUMENTS — `pr|release|train` (`train`: no class), `select|run`, the final diff's base and head SHAs, and:

- `release run`: the class `classify-release` printed for THIS head (none → `full`).
- `--only <names>`: re-run just those selected entries (review 7.1b's re-run, or `rerunAtMerge`,
  `clearance.md`).
- `--ran-at-train <names>@<sha>` (`release`): those `runAt: train` entries passed at `<sha>`; skipped only if `<sha>` is the commit the release branch was cut from or has the head's tree.
- `--skip <name>` (repeatable, `release` only), or `answer: skip <name>` (the owner's words): their waiver.
- `answer: moved <sha>` (`release`; a fix pushed after a `FAIL`) → `HEAD MOVED <sha>`, run nothing.

## Verdict

`PRE-SHIP SELECTED: <names> | PRE-SHIP: NOTHING TO RUN` and `PRE-SHIP: PASS (<n> ran, <k> waived) | PRE-SHIP: FAIL <names> | HEAD MOVED <sha> | NOT APPLICABLE`

## Select

In array order; no `preShipChecks` → `NOTHING TO RUN`.

- **`pr`**: `when` ∈ {`perPr`, `always`}. A non-empty `pathGlobs` must match the FINAL changed
  files from a **SHA-pinned three-dot local diff** — never `gh pr view --json files` or REST
  pull-files (both capped) — renames on BOTH source and destination; empty → every PR.
  **Never narrow a glob to skip a run.**
- **`train`**: every entry with `when` = `releaseOnly` AND `runAt` = `train`, run
  unconditionally at the snapshot head (`pathGlobs` unread); no snapshot head → `NOT APPLICABLE`.
- **`release`**: EVERY entry with `when` ∈ {`releaseOnly`, `always`} is selected (the hold fires whenever one exists); a `runAt: "train"` entry
  is dropped only per `--ran-at-train`, its one automatic skip (`runAt` with `onlyWhenTouched` is a config error); each dropped prints `skip <name>: passed at the train, <sha>`. **Run each selected entry UNCONDITIONALLY**, except
  a `releaseOnly` entry with `onlyWhenTouched: true`: it runs only when the release diff matches
  its `pathGlobs` (the release skill's `review-once.md`); a diff that
  cannot be computed runs it. Each not run prints `skip <name>: the release diff touches none
  of its pathGlobs`.

## Run

Re-select at this head. `--only` keeps just those names; one not selected → `FAIL <name>`, run
nothing. `--skip` on `pr` or `train` → refuse; on `release` the entry does not run and prints `WAIVED
<name> — the owner's explicit skip, recorded`: only on the owner's words, never assumed. Run the
rest **sequentially, in array order** (no dedup, no short-circuit), each in the BACKGROUND with a
long timeout (a foreground kill looks like a clean pass), `timeoutNote` first. `pr`: after
`verify.test`. `release`: export `RELEASE_CLASS` as the class passed for this head, never an
earlier head's.

- All green → `PASS (<n> ran, <k> waived)`. **Any entry red, unresolvable or dead without a
  result → `FAIL` naming EVERY failed entry**, with its failing specs: a block (fixed → resume with
  `answer: moved <head>`).
- Evidence per entry: name, command, result, counts, each skip and waiver.

Their CI check is EXPECTEDLY absent: never request, rerun or wait on it, or say "covered by CI".
