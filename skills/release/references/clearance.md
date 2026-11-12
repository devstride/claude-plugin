---
load: contract
---
# Release clearance — one cleared release at a time, across every machine and account

**Goal:** when releases are cut from several machines, people or agents, only one is in flight. A session asks for CLEARANCE before it touches anything a release touches
(the release train, the cut, the release pull request), keeps a heartbeat while it works, and hands
clearance back as soon as nothing the next release depends on is left: after the post-deploy check
and the source sync, before documentation and the rest of the close-out. A second session is told
who holds it and waits; the next cleared release carries that session's work, so there is never a
reason for two.

Everything here is opt-in through `release.clearance`. **Absent or `null` → nothing is claimed or
shown, and `release` runs exactly as before.** Nothing ever blocks a hotfix.

## The config block

```json
{ "release": { "clearance": { "provider": "github" } },
  "releaseTower": { "overrideLabel": "release-tower-override", "hotfixPattern": "*/hotfix/**" } }
```

- **`{ "provider": "github" }` or `{ "provider": "devstride" }`** — a built-in provider below; both
  honour one contract (verbs, exit codes, verdict lines, local record, `status --json`). Optional:
  `"ref"` (github; default `refs/clearance/release`), `"credentialsFile"` (devstride), `"staleMinutes"`
  (default `20`), `"waitMinutes"` (default `180`, how long `claim --wait` polls),
  `"phaseBudgetMinutes"` (phase → minutes over the defaults `{ "pre-ship": 120, "deploy": 60,
  "close-out": 45 }`; `0` or `null` switches a phase's alarm off, an unnamed phase has none — `review`
  and `train` wait on people and CI; a block that is not an object, or a value that is not a number,
  is ignored with a `status` warning, never an error that could stop a heartbeat or a hand-back).
- **`{ "commands": { "claim": "…", "status": "…", "heartbeat": "…", "release": "…", "adopt": "…" } }`**
  — a provider the repository supplies (a shell command per verb, run from the repository root;
  the verb's own arguments are appended). It honours the same contract. A block with BOTH keys is a
  config error (`doctor` and `setup validate` report it); so is a `provider` other than `github` or
  `devstride`.
- **`"scope"`** — `"release"` (default), `"cut-to-deploy"` (§ Scope `cut-to-deploy`) or
  `"merge-and-deploy"` (§ Scope `merge-and-deploy`), in either shape; any other value is a config error.
- **`releaseTower`** — read by the `release-tower` check and the built-in `status`: `overrideLabel`
  passes a pull request an owner approved by hand; `hotfixPattern` names hotfix heads (the
  branch-patterns rule, `${CLAUDE_PLUGIN_ROOT}/skills/release/references/branch-patterns.md`).
  Absent → those defaults.

## The provider contract — six commands (and `identity`), five exit codes

Every provider prints its verdict as the FIRST line of stdout and exits as follows. The skill
reads the exit code and quotes the line; it never parses further.

| Command | Exit 0 | Other exits |
| --- | --- | --- |
| `claim [--wait [--ignore-stuck]] [--purpose <text>] [--branch <b>] [--pr <n>]` | `CLEARED <holder> <takenAt>` (`--branch`/`--pr` are written into the record the claim creates or renews) | `2` BUSY: `BUSY held by <user> on <machine> since <takenAt>, phase <phase>, heartbeat <age> — <branch> #<pr>` (plus `— STUCK …` when it is) · `3` STALE with a pull request still open, or merged but never closed out: `STALE … pull request #<n> still open — adopt or wait` · `5` STUCK (`--wait` only, ended at the first poll that finds the holder stuck): `STUCK <the BUSY line>` · `1` error, a killed call included (never proceed uncleared) |
| `status [--short] [--json]` | the clearance line (or `CLEAR`), then `On final: #<n> <head>` for the oldest open release pull request into the production branch, `Waiting: #<n> <head>` for each later one, `Hotfix landed: #<n> <head> <mergedAt>` for each hotfix merged into production since `takenAt`, `Close-out owed: <release> #<pr> — <items> (handed back <age> by <user> on <machine>, session …)` for each entry in this machine's owed file | `1` the store could not be read: `UNKNOWN (…)` — never shown as clear |
| `heartbeat <phase> [--branch <b>] [--pr <n>]` | `HEARTBEAT <phase> <at>` | `4` NOT HOLDER: another session owns the clearance now — STOP |
| `release [--force] [--owed <item>]… [--step-aside]` | `RELEASED <branch>`, or `CLEAR (nothing to release)`; with `--owed`, a second line `Close-out owed: <items>`; with `--step-aside`, `RELEASED <branch> (stepped aside)` | `4` NOT HOLDER (`--force` releases anyway, prints the record first, and is the owner's command) · `1` `--step-aside` with `--owed` or `--force` |
| `adopt --yes [--original-stopped]` | `ADOPTED <branch> #<pr>` then `Resume: branch …, pull request …, phase …` | `2` not stale (nothing to adopt), or STUCK and still alive without `--original-stopped` · `4` nothing held |
| `owed [--done <item>]… [--clear] [--release <name>] [--pr <n>]` | `OWED <release> #<pr> — <items> (…)` per entry, or `NONE` | never fails: the file is local and advisory |
| `identity` | this session's holder, alone (the one verb that prints it; needs no `gh`, git or network) | `1` `ERROR: no identity` when no source below exists |

- **`claim --wait`** polls every 60 s up to `waitMinutes`, printing the BUSY line each poll on
  stderr, and exits 0 the moment it wins. A STALE result ends the wait with exit 3: the skill asks
  the owner. **It runs in the background with a long timeout**: a call a tool kills yields no
  verdict, and no verdict is `1`. Progress lines (polls, a generated token, a takeover note) go to
  stderr; stdout's first line is the verdict.
- **`status --short`** prints one token line for the status line — `release/26-10-17 · alice · ci`,
  with `· STALE` past the stale threshold and `· STUCK` past the phase budget — or, when clear,
  `close-out owed · <release> · <items>` while this machine owes close-out work, else nothing.
  `--json` prints `{ state: clear|held|unknown, stale, stuck, phaseMinutes, phaseBudgetMinutes,
  record, onFinal, waiting, hotfixesLanded, closeOutOwed, warnings, staleMinutes }`; a provider may
  add `record.pluginVersion`, the plugin version the holder claimed with.
- **Stale** = heartbeat older than `staleMinutes`. A stale clearance with no pull request, or one
  CLOSED unmerged, is taken over by the next `claim` (one atomic change on the stale record, so two
  takers cannot both win). One whose pull request is OPEN, or MERGED but never closed out (its
  session died before step 6 ended, so production may be unsynced), is never
  taken silently: it is ADOPTED (`adopt --yes`, after the owner's yes) and the release resumes on
  the adopted-release-branch path (at close-out, for a merged one). A pull-request state that
  cannot be read is an error (`1`), never a `3`.
- **Stuck = alive but not moving.** A `heartbeat` that CHANGES the phase stamps `phaseStartedAt` (a
  claim at `takenAt`; an adoption restarts it; the keeper never touches it). Past its phase's
  budget the clearance is STUCK: `status` and every BUSY line append `— STUCK in <phase> for <n>
  min (budget <b> min), session <holder> on <machine>`. STUCK alarms; it never takes over. **A
  STUCK clearance still alive is adopted only on the owner's yes AND their word that the original
  session has stopped** (`adopt --yes --original-stopped`): the provider cannot prove it, and two
  live sessions closing out one release do everything twice.
- **Liveness is the keeper's job.** `claim` and `adopt` start a detached keeper that re-stamps the
  heartbeat every `staleMinutes/3` while the agent process that claimed is alive and the local
  record still names this holder; `release` stops it. A long wait stays fresh; a crashed agent
  goes stale on schedule. The skill's `heartbeat <phase>` calls record progress and
  prove ownership; they do not keep the clearance alive. With no owning process found the provider
  says so, and the skill heartbeats at least every `staleMinutes` itself.
- **Holder identity** — one identity means one thing across the clearance commands:
  `CLEARANCE_HOLDER_TOKEN` (the older `DEVSTRIDE_LEASE_TOKEN` is read when it is unset); else `codex:$CODEX_THREAD_ID` and/or
  `claude:$CLAUDE_CODE_SESSION_ID` joined with `+`; else `token:<random>`, printed once (stderr)
  for a plain terminal to export as `CLEARANCE_HOLDER_TOKEN`. `identity` prints it (exit `1` for the
  random fallback), so other skills use this one rule. `user` is `gh api user`'s login; `machine` is
  the claim machine name (`claim_record.py`). A claim or adoption by the session that already holds it renews the heartbeat.
- **Session name (display only).** `claim`, a renewing claim and `adopt` store `session` beside
  `holder`: `CLEARANCE_SESSION_NAME` (empty reads as unset), else the claim session name
  (`claim_record.py`), cleaned and at most 64 characters; a session with no name drops the previous
  one. Heartbeats keep it; `status --json` and the human line (`… on <machine> (session <name>)`)
  show it; `--short` does not. Never used to decide who holds the clearance; records without it
  read as before. **The DevStride provider never sends it in the payload** — the server reserves
  the key `session` and refuses the call — but as the claim's own `sessionName`, read back from
  there; the server decides what a nameless renewal keeps.
- **The local record.** On `claim` and `adopt` the provider writes
  `${XDG_CACHE_HOME:-$HOME/.cache}/devstride/release-clearance/<owner>__<repo>.json` — `{ repo,
  holder, user, machine, session, branch, pr, takenAt, keeperPid }`, mode 0600, the real holder under either
  provider — updates `branch`/`pr` on each heartbeat, and removes it on `release` and on any `NOT
  HOLDER`, so a session that lost the clearance is not still vouched for. A hook answers "does THIS session hold clearance for THIS repository?" from
  that file alone, with no network; it is an observation, not proof against the store. The path
  and shape are part of this contract.
- **Close-out owed.** Work that runs after the hand-back is recorded by `release --owed <item>`
  (repeatable) in `<record path minus .json>.owed.json` — `{ entries: [{ repo, release, pr,
  holder, user, machine, releasedAt, owed }] }`, 0600, one entry per release, keyed by release name
  AND pull request — beside the record, never in it (the record means "this session holds
  clearance"). `owed --done <item>` settles an item of this session's newest entry (else the
  newest; or the one `--release`/`--pr` name; the last item removes it), `--clear` drops one
  whole; any session on the machine may do so.
  **A repository provider without `commands.owed` gets plain `release` (never `--owed`) and no
  `owed` calls**; the recap names the owed work instead.
- **Hotfix facts are DERIVED** from GitHub's merged pull requests, never recorded; the record holds
  only clearance state (holder, user, machine, purpose, phase, phaseStartedAt, branch, pr, takenAt,
  heartbeatAt).

## The github provider: `${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/clearance-github.sh`

Needs a checkout whose `origin` can push, `gh` signed in (pull-request facts, the user name) and
python3. Both providers read the keys above from the nearest `.claude/ds-config.json`; one that
cannot be parsed is an error, never a fallback (that would claim a different ref).

The clearance is the custom git ref `refs/clearance/release`, pointing at an annotated tag object
whose message is the record as JSON. **Every move of the ref is a compare-and-swap**: `git push
--force-with-lease=<ref>:<expected>`, where a claim expects the ref absent and a heartbeat, an
adoption or a stale takeover expects exactly the object it read. The server rejects every stale
expectation, so there is no look-then-act, not even on the stale path; a holder's own command whose
push the keeper's stamp beat retries on the stamped object (only a record naming someone else is
NOT HOLDER). The push runs no repository
hook (`--no-verify`), and the tag points at a blob of its own, so a checkout behind production
still claims. A record that is not
valid JSON with a holder and a time is UNREADABLE, taken over by nobody but the owner's `release
--force`. The ref is neither a branch nor a tag: no workflow, no list, no ruleset pattern matches
it. **One caveat:** a ruleset that restricts ALL ref creation blocks it — the push is refused with
the server's own words, and `doctor` reports it. Raw `git push` can move the ref: the commands are a speed
bump, the check below is the floor.

## The devstride provider: `${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/clearance-devstride.sh`

One DevStride claim (the MCP server's claim tools over HTTP): kind `release-tower`, key
`owner/name`, expiry `staleMinutes` (a dead keeper's claim lapses on schedule); the server decides
every race. The record rides in the payload, the holder as the server's digest (lines show its
first 12 characters), never the holder. Credentials `DEVSTRIDE_API_KEY`, `DEVSTRIDE_API_SECRET`,
`DEVSTRIDE_ORG_ID`, optionally `DEVSTRIDE_ORG_SLUG` and `DEVSTRIDE_BASE_URL` (an
`api[-x].devstride.com|dev` host): the environment first, then the `KEY=VALUE` file
`credentialsFile` names (from the repository root, `~/` expanded; **a file open to group or other
is refused: `chmod 600`**). Nothing prints the key, the secret or the holder. A server without the
claim tools, or a key lacking `MANAGE_AGENT_CLAIMS`, is exit `1` saying so; `status --short` prints
nothing on any failure. `gh` still serves pull-request facts.

## Where the release skill calls it

Only when `release.clearance` is set; scope `cut-to-deploy` changes 0a, 4 and 5a–5b, and
`merge-and-deploy` also 2 (below). **0a** `claim --wait --purpose release` before anything else (with a `claims` block, after the `release-train` claim only: `auto-start.md`'s lock order),
in the background with a long timeout: `0` continue (say who was waiting when stderr said so); `3`
ask the owner once — adopt `<branch>` / `#<n>`, or keep waiting — and on adopt run `adopt --yes`
and enter the adopted path (0b skips the train, 0c skips the cut, step 2 reviews the open pull
request; a merged one resumes at step 5a's confirmation and close-out); `5` tell the owner ONCE (a
push notification where there is one) the line's phase, minutes, machine and session, then `claim
--wait --ignore-stuck`; on their yes AND word that session stopped, `adopt --yes
--original-stopped` and the adopted path; `1` STOP as a release blocker. **`heartbeat <phase>` at
the START of each phase**, before its first mutation — `train` before 0b merges anything, `cut
--branch <b>` before 0c pushes, `pr --pr <n>` after step 1 opens it, `review` before 2, `pre-ship`
before 2b, `final` as step 4 presents READY and waits for the yes (the owner-wait measure reads
it), `merging` on the owner's yes BEFORE the merge, `deploy` before 5a, `close-out` before
5b — so a lost clearance (exit 4) stops the release before it touches anything. **Step 4**
appends `status` to the go-ahead: a `Hotfix landed` line goes to `release-branch.md` §4 first; a
`Waiting` line names who is next; on the yes, the release pull request must be the one `On final`,
else STOP (the GitHub check is a snapshot; this is the order at the moment of merge).
**Hand-back (5b):** `release` once the post-deploy check passed (including anything the next
release needs it to publish), production is synced into the source, the release branch deleted
and the train level (`release-branch.md` §5 steps 1–3) — BEFORE documentation, the check's
close-out and release notes, each passed as `--owed <item>` and settled by `owed --done <item>`,
run by the same session one after another. A failed check, or a 5b that stops early, KEEPS
clearance for the retry, and the recap says so. **`branch-hotfix` and the hotfix path never
claim**, and a hotfix pull request into the production branch merges with no clearance step.

## Scope `cut-to-deploy`

`release.clearance.scope` (default `"release"`: everything above, unchanged) set to
`"cut-to-deploy"` holds clearance only from the cut until the deploy is confirmed, so the next
release reviews and tests while this one deploys. The provider contract does not move; only where
the release skill calls it does.

- **0a moves.** 0b (the train) runs uncleared, with no `heartbeat train`. `claim --wait --purpose
  release` runs just before 0c, with the exits handled as above; the first heartbeat is `cut
  --branch <b>`. Step 0 adopts an open release pull request only when `status` shows no live
  holder (clear, or stale under the adoption rules); a live holder's stays theirs: run 0b, wait at
  the claim, and re-read step 0's shape once cleared, before cutting — with a `claims` block, also
  re-level the train by `release-branch.md` §1 step 7's rule under the train claim it still holds,
  since the release it waited on may have synced fixes into the source and skipped its own leveling. With a `claims` block the
  `release-train` claim is taken before any of this (`auto-start.md`'s lock order). 0b's train pull request body carries
  `<!-- devstride:release-train-holder <digest> on <machine> -->` (`<digest>`: the first 12 hex
  characters of the SHA-256 of `identity`'s answer; the holder itself is never written). An open
  train pull request whose marker names another holder is never adopted silently: STOP, name it,
  adopt only on the owner's yes. Its own marker is adopted as before. With a `claims` block the
  `release-train` claim comes first and decides which markers are adoptable (`auto-start.md`).
- **Step 4 gates the merge on the previous release.** Before the recap, and again on the yes
  before merging: `${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/previous-release-gate.sh --wait`.
  `0` continue; `2` (still pending after its 45-minute wait) STOP, naming that release and
  `/devstride:release post-deploy only`; `1` STOP: "Production merge refused: release <name>
  (#<n>) failed its post-deploy check." — the owner may override in words, recorded as a comment
  on this pull request; `3` ask the owner once (the first release under this scope, or one from
  before it); `4` (unreadable, a config error too) ask the owner. It never blocks the cut, the review or a hotfix.
- **Hand back at deploy-confirmed.** 5a confirms the merge, approves and confirms the deploy, and
  stops there. 5b then runs its branch work (`heartbeat close-out`, the sync, the release branch
  deleted, the train level), posts `post-deploy-status.sh <merge sha> pending "<release> by
  <machine> / <session name>: post-deploy check running"` (a session NAME, never the holder), and
  runs `release --owed post-deploy-check` with the other `--owed` items. The post-deploy check is then the FIRST owed
  item: `post-deploy check`, its result posted as `release/post-deploy`, then `owed --done
  post-deploy-check`. `PASS` posts `success`. `FAIL` posts `failure`, then STOP for the rollback
  decision; documentation and release notes never run. `NOT RUN` asks the owner: a yes posts
  `success` with "not run — owner accepted: <reason>", a no posts `error` and stops.
- **`post-deploy only`** — for a session that died after the hand-back: on the newest release
  merge, run 5a's confirmation, the `check` and the status post, then stop. Any session may; it
  claims nothing.
- `post-deploy-status.sh` and `previous-release-gate.sh` print `SKIPPED` / `NOT GATED` and do
  nothing under the default scope, so a repository that never sets the key sees no new status.

## Scope `merge-and-deploy`

`"merge-and-deploy"` is `cut-to-deploy` — the whole section above applies: the train runs
uncleared, the holder markers, the post-deploy check as the first owed item, the previous-release
gate — with the tower held only to cut, open, merge and deploy. Every long check and every wait
runs outside it.

- **0p. Pre-claim checks**, after step 0's delta and class and before any tower claim, on a
  detached checkout at the head they test (`<sourceHead>`, exactly where 0c cuts, on the first
  round; the release branch's head on a later one). FIRST `python3
  ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/release_checks.py tip`: keep its `PRODUCTION TIP
  <m>`. Then `classify-release` (`head: <that head>`); `pre-ship release run <class>` (with
  `--ran-at-train` evidence as usual); the dev deploy wait (`release.devDeployVerification`,
  every release, and **`RELEASE_COMMIT` is always the cut `<sourceHead>`**, the develop commit the
  release branch was cut from, on every round: the release source's deploy never carries a release
  branch's own commits until 5b's sync, so a later round passes the first round's exit through
  rather than waiting on a commit that source will never deploy); and `pre-merge-check` at that
  head. `PRE-SHIP: FAIL` or `HOLD` → STOP, holding nothing. Then `release_checks.py stamp --head
  <that head> --class <class> --master <m>`: `CHECKS STAMP …` → keep it and 0p's verdict lines;
  `CHANGED master` (production moved while the checks ran: the release ahead merged meanwhile) →
  run 0p again, since those results describe a production that is gone.
- **The queue, before every claim.** `python3
  ${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/tower-queue.py check` (`--own-pr <n>` once this
  release's pull request exists; `--waited-minutes <m>`, the minutes this release has waited in the
  queue so far). `WAIT` → do not claim: poll every 60 s, heartbeat the train claim while it is held
  (`auto-start.md`), and after `waitMinutes` STOP naming the pull request ahead. `ASK` (exit 3, once
  this release has waited `staleMinutes` behind another release pull request) → tell the owner ONCE
  (a `PushNotification` where there is one) which pull request it waits behind and that, if that
  release's session has stopped, they may say adopt; then keep polling as for `WAIT`, never asking
  again. A release that stepped aside holds nothing that heartbeats, so this notice is how a release
  orphaned while it waited is found in minutes rather than after `waitMinutes`. `CLEAR` → `claim
  --wait`, its exits as in 0a. No release claims while another release pull request is open into
  production, so releases still merge oldest first, one at a time.
- **Every claim after the cut names the release.** `claim --wait --branch <release branch> --pr
  <n>` (just `--branch` between the cut and step 1): the record is created naming its pull request
  in the same write, so if the session dies under it the next claim is `STALE … still open` or `…
  merged but the release was never closed out` (exit 3, adopt on the owner's yes), never a silent
  takeover as "pull request never opened".
- **Verify on every claim.** Right after `CLEARED`, re-read step 0's shape as above, then
  `release_checks.py verify --stamp '<line>' --head <head>` (`<sourceHead>` before the cut, the
  release pull request's head after). `UNCHANGED` → go on. `CHANGED` → `release --step-aside`, run
  0p again at the new head (its stamp replaces the old one), then queue, claim and verify again;
  after three rounds the checks run under the tower, said so. `BEHIND` (production holds commits the
  head does not: a hotfix, or the fix commits of the release ahead, not yet in the release source)
  → `release-branch.md` §4 merges production into the release branch (before the cut: cut first,
  then §4), then as for `CHANGED`. `ERROR` → step aside, then STOP.
- **Step 2.** The pre-ship hold is declared exactly as under every other scope (`release-pr.md`).
  At 7.1b, when the settled head's tree equals the stamp's tree, 2b reports 0p's `PRE-SHIP` line
  ("passed before the claim at <sha>") and 2c discharges the hold at once. When it differs (fix
  commits, a hotfix merge by `release-branch.md` §4): `release --step-aside`, 0p at the settled
  head, then queue, claim, verify, and only then 2c's `PRE-SHIP RESUME`, so the ready flip always
  follows pre-ship on the final tree and CI runs once.
- **Step 4 steps aside to wait.** `previous-release-gate.sh` runs WITHOUT `--wait` (one read).
  Pending (`2`), a standing-yes `ASK`, or this pull request not `On final` → `heartbeat final`,
  `release --step-aside`, the unattended-stop notice (`auto-start.md`), then wait outside the tower:
  for the owner's words, and for the gate (one read every 60 s, at most its 45 minutes). Still `2`
  after those 45 minutes → STOP, naming that release and `/devstride:release post-deploy only`; `1`
  while waiting → the failure STOP of § Scope `cut-to-deploy`. On the yes, or with the standing yes
  once the gate reads `0`: queue (`--own-pr`), claim (`--branch --pr`), `heartbeat final`, **the
  previous-release gate once more** (one read: `0` → go on; `2` → step aside again and keep
  waiting; `1` → the failure STOP, overridable only in the owner's words recorded on the pull
  request; `3`/`4` → ask; an in-the-moment yes never lifts a pending gate), verify against the
  stamp at `<reviewedHead>`, `pre-merge-check` again, `pre-ship release run <class> --only <names>`
  for every `rerunAtMerge` entry, `standing-yes.py` again (or apply the in-the-moment yes), then
  `heartbeat merging` and the merge. `CHANGED` or `BEHIND` → back to step 2; any yes is void.
- **A stepped-aside release holds nothing.** `release --step-aside` releases with outcome
  `stepped-aside`, removes the local record and stops the keeper exactly like `release`, and owes
  nothing, so it vouches for nothing. Every step after a re-claim starts with its `heartbeat`:
  exit 4 still STOPs.
- **Adoption.** The release pull request body carries `<!-- devstride:release-holder <digest> on
  <machine> -->` (the train marker's digest rule), written when step 1 opens it, never after the
  ready flip. An open release pull request whose marker names another holder is never adopted
  silently, even with the tower clear (that release may only have stepped aside): this release
  waits at the queue behind it (the queue's `ASK` tells the owner), and adopts it only on the
  owner's yes and their word that its session stopped.
- **An older holder.** A re-claim that is BUSY reads `status --json`: a `record.pluginVersion`
  older than this plugin, with this release's pull request `On final`, sends ONE `PushNotification`
  naming that session and the fix (`release` in it, or the owner's `release --force`). The STUCK
  alarm on `final` is the floor.

## The floor: the `release-tower` check

`/devstride:setup ci` offers, when `release.clearance` is set, the template
`${CLAUDE_PLUGIN_ROOT}/skills/setup/references/ci-templates/release-tower.yaml` with its checker
`release-tower-check.mjs` (written to `.github/workflows/release-tower.yaml` and
`.github/scripts/release-tower-check.mjs`; GitHub only, Node 22, no dependencies). It runs
`pull_request_target` on the production branch; GitHub runs that event from the repository's
DEFAULT branch (since 2025-12-08), so a pull request cannot edit its own gate (the head is never
checked out), and the check runs once the files reach the default branch. It passes a
hotfix head, the OLDEST open release pull request, and a pull request carrying
`releaseTower.overrideLabel`; a later release pull request is held with `<head> (#n) is on final;
this release waits`; any other head gets the retarget line. Whenever a release pull request opens,
reopens, closes or is retargeted onto production, the newest run of every OTHER open release pull
request is re-run, so the queue re-settles without a push. One retargeted AWAY from production
fires no event there: run `gh workflow run release-tower.yaml`, or wait — step 4 checks `On final`
at the moment of merge regardless. **Making it REQUIRED on the production
branch's ruleset is the owner's change**, after it has posted green on one real release pull
request — then even an administrator cannot land a second release beside the first.

## Cited by

- `skills/release/SKILL.md` — the clearance floor, steps 0a, 4, 5b and 6;
  `references/merge-and-deploy.md` — step 4's recap.
- `skills/setup/SKILL.md` and `references/ci-cost-patterns.md` §E — the `setup ci` template.
- `skills/doctor/SKILL.md` — the config audit of `release.clearance` and `releaseTower`.
- `skills/setup/references/statusline-segments.md` — the `release` segment.
- `skills/branch-hotfix/SKILL.md` — a hotfix never claims.
- `skills/release/scripts/post-deploy-status.sh`, `previous-release-gate.sh` — scopes `cut-to-deploy`
  and `merge-and-deploy`; `release_checks.py`, `tower-queue.py` — scope `merge-and-deploy`.
