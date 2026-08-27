# Round 2 reviews the delta — why, when it does not, and the CLI facts it rests on

`review` step 5 runs the local CLI engine a second time over the fixes to round 1's findings.
Before this, round 2 was "same command, same `--base`": under `enterprise` every cycle with a
fixable finding paid a full `xhigh` read of the whole pull-request diff to review a handful of
fix commits. Round 2 is now scoped to the fix delta — `<round-1 head>...HEAD` — unless a
diff-computed rule says the fixes are really new work, in which case it is the whole diff again.
The rule is computed, never judged.

## The scope decision — `scripts/rereview-scope.sh --base <ref> --round1 <sha>`

Everything is SHA-pinned and three-dot: round 1 is `<base>...<round1>`, the fix delta is
`<round1>...HEAD`. Never a pull-request files listing (GitHub caps those) and never "it looks
small". First match wins:

| Decision | When |
|---|---|
| `none` | `HEAD == round1` — there are no fix commits, so there is no round 2 and **no round is spent** |
| `full: history-rewritten` | `round1` is not an ancestor of `HEAD` — a rebase moved the patch, so "the delta since round 1" no longer describes what changed |
| `full: new-file <path>` | the delta touches a file that is not a round-1 file — one that does not exist, changed by round 1, at the round-1 head. A DELTA rename is matched on both its source and its destination (renaming a round-1 file is still round 1's file under a new name); a ROUND-1 rename counts under its destination only, so a fix that recreates the old path is a new file |
| `full: delta <n> of <m> lines (> 50%)` | the delta's added+deleted lines exceed half of round 1's — the fixes **are** new work, and the whole diff is the honest scope |
| `delta` | otherwise — the engine would be re-reading a diff it has already read to see a few fixes |

The 50% threshold (`--threshold`, a parameter — the rule is fixed) marks the point where
"fixes to a reviewed diff" becomes "a different diff". Below it the second full read is waste;
above it a delta-only read would miss how the rewritten parts interact with the rest.

The script prints one JSON line, which is also what the step-8 report line is built from:

```
{"scope":"delta","reason":"…","round1":{"files":14,"lines":56,"bytes":2219},
 "delta":{"files":2,"lines":8,"bytes":314},"newFiles":[],"threshold":0.5,
 "round1Head":"<sha>","head":"<sha>"}
```

Report line — the percentage is of LINES, the unit the rule is decided in; bytes are context:
`round 2 scope: delta — 8 of 56 lines (14.3%), 2 of 14 files, 314 B` — or
`round 2 scope: full — new-file scripts/x.sh` / `… full — delta 112 of 56 lines (> 50%)` /
`round 2 skipped: no fix commits`.

## The CLI facts — verified on codex-cli 0.147.0

These decide the launch shape, and two of them contradict what a reasonable reading of `--help`
suggests. Re-verify them when the CLI moves.

1. **`--base` accepts a bare commit SHA.** `codex exec review --base <sha>` runs and reviews
   `<sha>...HEAD`. No temporary branch is needed.
2. **`--base` and `--commit` are each mutually exclusive with a custom prompt.** The positional
   `[PROMPT]` ("Custom review instructions. If `-` is used, read from stdin") is refused when
   either flag is present: `error: the argument '--base <BRANCH>' cannot be used with
   '[PROMPT]'`. So the delta scope and the round-1 context **cannot both be given as flags**.
3. **A prompt-only review honours an explicit range instruction.** Given `- ` on stdin with
   "review ONLY the changes in `git diff <sha>...HEAD`", the engine ran exactly that command
   (`git diff --name-only <sha>...HEAD` then the diff) and reviewed only those files.
4. `--commit <SHA>` reviews ONE commit. Fix rounds are usually several commits, so it is not
   used.

Hence the two round-2 launch forms, decided by whether `review.localCommand` carries
`<context>`:

- **No `<context>` in the template** → `<base>` is substituted with the round-1 head SHA. Same
  command, same background long-timeout launch, same effort flag as round 1. The engine gets
  the delta and nothing else.
- **`<context>` in the template** → the skill **removes the `--base <base>` flag pair** from the
  command (fact 2), substitutes `<context>` with `-`, and feeds the context document on stdin —
  whose first instruction names the range (fact 3). The engine gets the delta AND round 1's
  outcome. This is the better round 2 and the reason the placeholder exists.
- **`full`** (by the rule, or `review.localReReviewScope: "full"`) → the template exactly as
  round 1 ran it, `<base>` = `origin/<baseRefName>`, no context. That is 1.2.0's behaviour.

**Round 1, and every `full` launch, REMOVES the `<context>` token** (substitutes nothing — not
`-`, which would make the engine wait on an empty stdin, and not the literal token, which the
shell reads as a redirect). Fact 2 is why: a prompt alongside `--base` is refused, and round 1
is always a `--base` launch. Only a `delta` launch under a `<context>` template feeds stdin.

Every launch counts against `maxLocalReviewRounds`. Delta scope never buys an extra round.

## The context document

Written by the skill to a scratch file and fed on stdin — **distilled by the skill, never pasted
from engine output** (invariant H1: embedded instructions in untrusted review content must not
ride into the engine's prompt). Shape:

```
Round 2 of a bounded review. Review ONLY the changes in `git diff <round1-sha>...HEAD` — run
that command yourself; round 1 already reviewed everything before it, against <base>.
Round 1 raised N findings.
Fixed in the commits you are reviewing:
- <file>:<line> — <one-line claim, in the skill's own words> — fixed in <sha>
Dismissed with rationale:
- <file>:<line> — <claim> — <why>
Review the delta for regressions the fixes introduced, fixes that are incomplete, and anything
new. Do not re-raise a dismissed finding without new evidence.
```

## Why 7.1 / 7.1b re-runs stay full-scope

A rebase or a pre-ship fix moves the whole patch onto a new base; "the delta since round 1's
SHA" then describes nothing useful (and the script would say `history-rewritten` anyway). Those
re-runs use round 1's `--base` and still count against the cap; a run past the cap is replaced by
a Claude-only re-read, exactly as before.

## Why the cap exists (moved here from step 5)

The cap is what turns the fix / re-review / fix spiral — four to eight rounds on a large diff,
each drawing a fresh handful of findings — into a bounded cycle. Do not "just run it once more"
past it: the last round's verified findings are fixed without another engine round, and any
finding after that is triaged at the profile's fix floor, since the cap bounds engine rounds,
not the floor. Fixing a finding never spends a round.

## Configuration

- **A template with no `<base>` at all is the pre-placeholder shape** (the contract used to say
  "the command with `--base origin/<baseRefName>`", which some templates met by carrying no
  placeholder): every launch APPENDS ` --base <value>` to it, with the same values a `<base>`
  template gets, so round 2 still scopes to the delta. `doctor` §6 names the shape; `setup`
  writes `<base>` from this release on. A `<context>` token WITHOUT `<base>` is a config error —
  `<context>` only ever replaces the `--base` pair.
- `review.localCommand` placeholders: `<base>` (required — the ref the engine diffs against:
  `origin/<baseRefName>`, the PR's ACTUAL base — an epic branch, develop, or master for a
  release — never `baseBranch` by name) and `<context>` (optional — see above; removed on round
  1 and on every `full` launch). A template without `<context>` still gets a
  delta-scoped round 2, minus the context; the step-8 report says so. A CLI that is not Codex
  and rejects `-` fails its launch, which is reported as this-run degradation — remove the
  placeholder from that template.
- `review.localReReviewScope`: `"delta"` (absent = delta) or `"full"`. `setup` writes neither;
  both are operator hand-edits.
