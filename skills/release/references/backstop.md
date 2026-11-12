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
| `SKIP` | 11 | stop, saying the reason once: not waiting long enough, nothing waiting, a release in progress, held, unreadable, no train, no claims block, or changed since the claim |
| `OFF` | 12 | stop silently |
| `HOLDS` | 13 | read every listed item and each ancestor up to the root (`get_item(view: 'full')`), write `{"items": [{"number", "description"}...]}` to a file and run `due` again with `--holds <file>` |
| `ERROR` | 1 | say it once and stop |

- **Waiting work** is every landing on the train not yet on `release.releaseSource`: each
  first-parent commit of `origin/<source>..origin/<train>`, except a sync merge (a merge whose
  other parents are all on the source). Landings are `--no-ff` or pull-request merges, so a
  landing's committer time is when it landed; git carries it, so every machine computes the same
  wait. The OLDEST landing is the one with the smallest committer time (on a tie, the earlier in
  first-parent order), never the one at the end of the list: a merge stamped by a skewed clock
  counts from its stamp. Story commits' own times (when they were written) are never used.
- **Nothing is releasing it**, checked BEFORE anything is claimed: no open pull request into
  `release.productionBranch` headed by the release source or a `release.releaseBranchPattern`
  branch (`gh pr list --repo <host>/<owner>/<repo>`, all three read from origin, always, with or
  without clearance; a release waiting at step 4 for the owner's yes may have let its train claim
  lapse, and the backstop never adopts it); and, with `release.clearance` set, its provider's
  `status --json` reads `clear`, `derived`, with no release pull request on final. Held (stale
  included: the owner settles a stale release), unreadable, a failed or truncated list, an origin
  with no host to read, or a status not derived → SKIP. A release holding the train claim is found
  by claiming it (below): `claim_work` decides, a listing never does. **Under
  `release.clearance.scope` `cut-to-deploy` or `merge-and-deploy` neither the pull-request list
  nor the provider's status is read**: a release there holds the tower only from its cut and hands
  the train claim on at the cut, so an open release pull request or a held tower is a release that
  has already left this waiting work behind. The train claim alone decides, and the `--json`
  record's `releasePullRequests` and `clearance` say "not read".
- **Holds** are `release-holds.md`'s, decided by `release-holds.py` after fetching
  `origin/<productionBranch>`, over every item the release itself would check: the commits on the
  train or the source that are not on production. A line it cannot parse holds.

## The backstop claim — one start per waiting work per window

The `--json` record carries the claim to make: `claim` (kind `release-train`, key
`<owner>/<repo>@<oldest landing sha>`, `:shadow` appended in shadow mode so shadow records never
consume a live key; `expiryMinutes` = `maxWaitMinutes`, 15 to 1440, as a claim lives at most a day;
purpose `release backstop`) and `trainClaim` (key `<owner>/<repo>`). Every check while that work
waits computes the same key, whatever its clock or the landings since; once that landing ships, the
key moves to the next oldest. Read it before claiming: `get_claim` (a `commands` store:
`claims.commands.get`, which doctor requires) piped as `{"stage": "before", "response": <answer>,
"now"}` to `python3 ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/backstop.py decide`. `skip` → stop
silently: a live claim blocks a start WHOEVER holds it, this session included (a `/loop` that
started a release at 10:02 starts nothing at 10:12), and is never claimed again, so never renewed
or extended. `claim` → `claim_work`; `takeover` (the window lapsed) → `claim_work` with `takeover:
{expectedHolderDigest: <takeoverDigest>}`. Each claim is `story-claims.md`'s (holder,
`claim_record.py` record) with the record's fields and one payload key more, `backstop`: the
`--json` record; pipe its answer as `{"stage": "after", "before": <the before action>, …}`:
`proceed` → on (this session taking back its own lapsed claim included); `skip` → stop silently;
`degrade` (either stage) → do nothing, said once (the backstop never runs without its claim).
Never heartbeat it and never release it on a start: it lapses after `maxWaitMinutes`, so each
waiting work gets at most one start per window, and a release that stops early (a hold, a red
check, the owner's no) is retried once per window while the work still waits and nothing is in
progress.

- **Live, won:** claim the train (`auto-start.md`'s train claim, mode `select`). Lost to a live
  holder → a release is in progress: `release_claim` the backstop key with outcome `busy`, NOT
  final, with the record as `result`, so a later check may act once that release ends; stop. Won →
  run `due --json --recheck <key>` (with `--holds` again, re-read): anything but `START` → release
  the train claim (outcome `released`, never final) and the backstop key (outcome `changed`, not
  final), and stop. `START` → run **`release`** in this session declaring `started-by: auto`
  (inside `release backstop`: carry on as that release run; `auto-start.md`'s path: its step 0
  refreshes the train claim; the unattended stop and the standing yes apply).
- **Shadow, won:** the same steps, reading instead of claiming: `get_claim` the train key; live →
  `release_claim` the backstop key with outcome `busy`, not final, the record (with `trainClaim:
  "held by <machine>"`) as `result`, as live would. Free → `due --json --recheck <key>`; anything
  but `SHADOW` → release it with outcome `changed`, not final; `SHADOW` → keep the claim, which
  lapses like a live start. Say the verdict line. Nothing else: no train claim, no tower, no
  branch, no pull request, no release.
- **Where shadow records go:** the claim store, shared by every machine and already proving one
  winner per key: `list_claims` kind `release-train`, `keyPrefix` `<owner>/<repo>@`, state `all`,
  gives each would-start (the `backstop` payload) and each `busy` or `changed` outcome with its
  `result`. Nothing is written to the repository.

## Cited by

- `skills/release/SKILL.md` — the `backstop` argument.
- `skills/release/references/auto-start.md` — Auto start.
- `skills/setup/references/config-defaults.md` — `release.backstop`.
- `skills/release/scripts/backstop.py` — the check.
