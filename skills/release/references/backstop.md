---
load: contract
---
# The release backstop — a release when landed work has waited too long

**Goal:** work that landed on the release train never waits indefinitely because no session
noticed it. Releases still start whenever work is ready (`release.autoStart`, or by hand); the
backstop never delays, caps or replaces them. A check run on a schedule starts a release ONLY when
the oldest waiting landing is older than `release.backstop.maxWaitMinutes` (default 120) and
nothing is releasing it. Otherwise it does nothing and says why.

## When it applies

`release.backstop.mode`: `off` (default; also when the block is absent) → nothing here runs.
`shadow` → record what it would start, change nothing. `live` → start the release. Shadow or live
needs a `claims` block (doctor: an ERROR; at run time it does nothing) and a release train
(`release.mergeTrainBeforeCut` with `releaseTrain.branch`; doctor: a WARN). **Live is switched on
only after the shadow results were checked**: the owner reads the shadow records (below) over a
representative period and confirms each waiting piece of work produced one record, at the right
wait, and none while a release was in progress. Mode `off` is the default and the way back.

## Who runs it

Anything on a clock, every few minutes: `/devstride:release backstop` (by hand, or from a
scheduled session such as `/loop 10m /devstride:release backstop`), or a dispatcher that runs the
script and then the claim calls below. A run that does not START does nothing more.

## The check

`python3 ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/backstop.py due --json [--holds <file>]`
(`--now <ISO>` replaces the clock in tests). The first line, or the `verdict` field, decides:

| Verdict | Exit | Then |
|---|---|---|
| `START` | 0 | live: claim the backstop key (below) |
| `SHADOW` | 10 | shadow: claim the backstop key, record, start nothing |
| `SKIP` | 11 | stop, saying the reason once: not waiting long enough, nothing waiting, a release in progress, held, clearance unreadable, no train, no claims block |
| `OFF` | 12 | stop silently |
| `HOLDS` | 13 | read every listed item and each ancestor up to the root (`get_item(view: 'full')`), write `{"items": [{"number", "description"}...]}` to a file and run `due` again with `--holds <file>` |
| `ERROR` | 1 | say it once and stop |

- **Waiting work** is every landing on the train not yet on `release.releaseSource`: each
  first-parent commit of `origin/<source>..origin/<train>`, except a sync merge (a merge whose
  other parents are all on the source). Landings are `--no-ff` or pull-request merges, so a
  landing's committer time is when it landed; git carries it, so every machine computes the same
  wait. Story commits' own times (when they were written) are never used.
- **Nothing is releasing it**: with `release.clearance` set, its provider's `status --json` reads
  `clear` with no release pull request on final; held (stale included: the owner settles a stale
  release) or unreadable → SKIP. A release holding the train claim is found by claiming it (live,
  below): `claim_work` decides, a listing never does.
- **Holds** are `release-holds.md`'s, decided by `release-holds.py` over the items the waiting
  work's commit messages name; a line it cannot parse holds.

## The backstop claim — one starter per waiting work

Kind `release-train`, key the verdict's `<owner>/<repo>@<oldest landing sha>` (`:shadow` appended
in shadow mode, so shadow records never consume a live key). Every check while that work waits
computes the same key, whatever its clock or the landings since; once that landing ships, the key
moves to the next oldest. Claim it as `story-claims.md` claims (holder, `claim_record.py` record,
`claims.expiryMinutes["release-train"]` else 30), purpose `release backstop`, and decide with
`story-claim.py decide` in mode `select`: `skip` (another machine holds it, or it is already
finished) → stop silently; `takeover` → take it over once; `degrade` → do nothing, said once (the
backstop never runs without its claim).

- **Live, won:** claim the train (`auto-start.md`'s train claim, mode `select`). Lost to a live
  holder → a release is in progress: `release_claim` the backstop key with outcome `busy`, NOT
  final, so a later check may act once that release ends; stop. Won → `release_claim` the backstop
  key with `final: true`, outcome `started` and the `--json` record as `result`, then run
  **`release`** in this session declaring `started-by: auto` (inside `release backstop`: carry on
  as that release run; `auto-start.md`'s path: its step 0 refreshes the train claim; the
  unattended stop and the standing yes apply). One backstop per
  waiting work: a release that then stops leaves the next move to the owner, never another backstop.
- **Shadow, won:** read the train claim with `get_claim` (kind `release-train`, key
  `<owner>/<repo>`), never claiming it, and add `trainClaim` (`held by <machine>` or `free`) to the
  record; then `release_claim` the backstop key with `final: true`, outcome `shadow` and the record
  as `result`. Say the verdict line. Nothing else: no train claim, no tower, no branch, no pull
  request, no release.
- **Where shadow records go:** the claim store, shared by every machine and already proving one
  winner per key: `list_claims` kind `release-train`, `keyPrefix` `<owner>/<repo>@`, state
  `released`, gives each record's outcome and `result`. Nothing is written to the repository.
- **A `claims.commands` store** has no final release (its release verb takes `--outcome` only), so a
  released key may be won again and a stopped release restarted for the same work; doctor warns.

## Cited by

- `skills/release/SKILL.md` — the `backstop` argument.
- `skills/release/references/auto-start.md` — Auto start.
- `skills/setup/references/config-defaults.md` — `release.backstop`.
- `skills/release/scripts/backstop.py` — the check.
