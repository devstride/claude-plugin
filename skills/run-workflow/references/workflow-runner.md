---
load: contract
---
# The step runner — one step at a time, with the proof each step leaves

`${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/scripts/workflow.py` walks a workflow definition
(`${CLAUDE_PLUGIN_ROOT}/schemas/workflow.schema.json`) against the step contract catalog
(`${CLAUDE_PLUGIN_ROOT}/schemas/step-contracts.json`). **It decides and records; it never acts**: no
skill run, git only to read, and one bounded call per command, which sends the run's own history to
DevStride ("History", below). Whoever drives it runs the steps.
It decides which step is next, checks each step's answer and proof, and remembers where the run is,
also across a restart or a cleared conversation.
This file is what a driver needs: the commands, the answers, the stops, the history and resuming.
**Read `${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/references/workflow-contracts.md` in full before
writing or changing a definition or a contract, or when a stop names a refused proof and you need
why**: what `start` refuses, payloads, proofs and their bindings, the named rules, and what is
reported.

## Commands

`python3 -B workflow.py <command>`: one JSON object on stdin, one on stdout. Exit 0 is an answer.
Exit 2 is a refusal: exactly one `workflow: <code>: <message>` line on stderr, nothing on stdout,
nothing changed. Exit 1 is anything else, also one line: the runner or its install is broken, so
say the line and stop; never retry it. Every request may carry `session` (else the agent's own
session id) and names its run by `item`, by `runId`, or by being the session's only open run. A
run with no item is named only by its `runId`; a session holds one open such run of a workflow.

| Command | Request | What it does |
|---|---|---|
| `start` | `definition` or `definitionFile` (a file of at most 256 KB), `context`, `fetched`?, `replace`?, `rehearsal`?, `beside`? | Validates everything before writing anything, then issues the first step. An open run for the same session and item (no item: the same workflow) is refused (`run-open`) unless `replace` is true, which ends the old run as interrupted; with `fetched`, its current position comes back instead. `beside` true (no item, no `replace`) starts a second one on purpose (two open: `ambiguous-run`). `fetched` is the tracker's answer for the item (`fetching-the-workflow.md`): `start` pins the organization's definition or the built-in one and adds `definitionSource`, `workflow` and `notice`. `rehearsal` true runs what is not switched on yet (`skill-dormant`): only for a rehearsal a person asked for |
| `next` | `gateAnswer`?, `facts`? | The next action. Asked again before `done`, it hands back the issued step and attempt as they were: the step may already have acted, so only its `done` moves the run on. `gateAnswer` is what `get_workflow_gate` read for the gate or checkpoint the run is parked at (refused `not-parked` when it is parked at none). `facts` decide a condition (`need-facts`; `start`, `done` and `resume` take them too) |
| `done` | `stepId`, `attempt`, `output` (the step's whole final answer, as text) | Records the issued step's answer and returns the next action plus `recorded`. Any other step or attempt is refused (`not-current-step`), except the step a stopped run stopped on, repaired by hand. A gate takes only `APPROVAL: REQUESTED` or `APPROVAL: UNAVAILABLE`, a checkpoint only `CHECKPOINT: REQUESTED` or `CHECKPOINT: UNAVAILABLE` (`gate-answered-by-agent`) |
| `wait` | `stepId`, `attempt`, `reason`? (one line) | For a step that waits inside itself (a queue, a deploy, another release): the issued step is reported `waiting` with the reason, on the same attempt, until its `done`. Nothing else changes: the step still ends with its verdict, and any other step or attempt is refused (`not-current-step`). Never for a gate or a checkpoint (`wait-not-a-step`): those park the run ("Waiting and parked") |
| `status` | `evidence`?; or `all`, `others`?, `unsent`?, `cwd`? | Read-only: `state` (running, stopped, parked or finished), `position`, one row per step, a ready Markdown `table`, `parkedAt` (the gate a parked run is at: `stepId`, `id`, `since`; else null) and `history` (`events` kept so far, `unsent`: how many DevStride does not hold yet, `stopped`: why no more are kept, or null, `off`: true when history is switched off). With `evidence` `true`, each row also carries its step's recorded `evidence`, `result` and `waiting`: a later step reads them there, never from memory. With `all` `true` and no run named: `runs`, this session's unfinished runs, oldest first, each with `runId`, `item`, `workflowId`, `state`, `position`, `stopped`, `waiting` and `parkedAt`; `others` `true` adds `others`: other sessions' unfinished runs in this checkout (`cwd`), with `sessionId`, adopted by run id once that session has ended; `unsent` `true` adds `unsent`: every run of this user on this machine whose history DevStride does not hold yet (`runId`, `sessionId`, `item`, `events`, `since`, `ended`) |
| `resume` | `workflow`, `answer`?, `cwd`?, `landed`?, `close`?, `beside`? | Continues after a restart or a stop, only a run of `workflow` (the id of the built-in definition this entry starts, such as `build` or `hotfix`; an organization's workflow standing in for it counts): this session's run of another workflow is refused `other-workflow`, another session's is never adopted. An issued step comes back as it was, otherwise as `next`. `answer`, a person's reply to a question, reaches that step's payload for that attempt only; at a `confirm` stop it must start with yes or no (the table below). A merge stop comes back as the stop until `landed` is `false`. `close` `true` ends the run as interrupted |

The context: `item` (an item number or null), `goal`, `profile` (`name` and `source`),
`workingBase`, `oneOff`, `route` (`train`, `develop-pr` or `epic-release`), `releaseUnit`,
`reviewMoment`, `branchSlug`, `mode` (the story claim's mode:
`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/story-claims.md`), `cwd` (default: the current
directory), `trigger` (default: the definition's `startsWhen`; a `children-complete` trigger or
definition with any other on the opposite side is refused, `trigger-mismatch`). The runner adds `repository`. A `children-complete` start also needs `rollup`,
`rollup.py ready`'s answer for the item: any verdict but `READY` is refused (`rollup-not-ready`,
`rollup is WAITING: …`), and its claim is the story claim on the rollup item. A start is refused (`context-missing`) unless the context
holds every key a step's payload reads without a `?`: for the shipped contracts, all of them.

An action is one of:

- **`run`**: `step` (`id`, `name`, `phase`, `contract`, `attempt`), `skill` (the built-in skill to
  invoke), `payload`, `argument` (the contract's template rendered from the payload, else the
  payload as one compact JSON string: pass it to the skill unchanged), `heartbeat` and `agent`
  (where the step runs, `routine`, `judgement` or `conversation`: `step-agents.md` beside this file).
- **`finished`**: `outcome` (`completed`, the outcome a step ended the run with, such as `held`, or
  `declined` after a no at a `confirm` stop), `recordedOutcome` (below), `results` (each finished
  step's result by contract),
  `continuedPastFailures` (`stepId`, `verdict`: non-blocking steps that failed, still shown failed),
  `openCheckpoints` (`stepId`, `gateId`: non-blocking checkpoints a person has not answered yet) and
  `skippedByCondition` (step ids whose condition was false). Say each list that is not empty.
- **`stopped`**: `kind`, `reason`, `stepId`; a stop that waits for a yes or no adds `confirm`
  (true); a stop of a merge that answered adds `mayHaveLanded` (true), its `attempt` and the
  `commit` it was handed.
- **`request-gate`**, **`parked`** and **`address-changes`**: an approval gate or a checkpoint (`step`,
  `kind`, `blocking`, the tool's `arguments`, `then`). **Read
  `${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/references/gates.md` in full before acting on one.**
- **`need-facts`**: a conditional step (`step`, `condition`) needs the facts named in `needs`.
  **Read `${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/references/conditions.md` in full before acting
  on one.**

Every answer also carries `runId`, and `say` when there is one line for the person ("History",
below); `start` adds the definition's hash. An answer
adds `decided` (`stepId`, `attempt`, `verdict`) when the runner answered steps itself from the
repository's `.claude/ds-config.json`, with no model turn: a built-in step whose contract's
`configSkip` rule matched (the config lacks the hook or block the step would read) is recorded done
with the verdict its skill gives in that case, its evidence line beginning "Decided from the
repository's config". A config that cannot be read decides nothing. A `run` answer for a repository step (its source is `repo`) has `skill: null` and `instructions` (the committed file's text, path, commit and hash). Follow `instructions.text` as that step's skill, then answer `done` with the verdict line its contract names.

## A step's answer

The first non-blank line is the verdict: the contract's label, a colon and a space, one listed
value (the longest that matches), then the detail where the value takes one. The catalog names
each detail (`detailName`): `<name>` must follow the value, `[<name>]` may. Write verdict lines
exactly as listed. The lines after it, up to the first fenced block tagged json, are evidence; that
block is the result, one JSON object of at most 16 KB in which `proof` and `links` sit beside the
result keys. Nothing after it is kept. A passing local check, for example:

````text
LOCAL CHECKS: PASS (2 ran)
unit: 12 passed
```json
{"commands": ["unit", "lint"], "results": [], "receipt": "<receipt>", "tree": "<tree>", "head": "<commit>",
 "skippedSuites": [], "proof": {"kind": "receipt", "tree": "<tree>", "head": "<commit>", "receipt": "<receipt>"}}
```
````

`${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/scripts/workflow-fixtures.json` (`outputs`) holds one
passing answer per contract. The value's class decides what happens:

| Class | The step | The run |
|---|---|---|
| `continue` | done, if its result and proof are accepted | goes on |
| `skipped` | skipped | goes on |
| `redo:self` | done | issues the same step again, after whatever went stale |
| `stop` | failed | stops, kind `failed` |
| `ask` | waiting | stops, kind `needs-person`; the detail is the question |
| `confirm` | waiting | stops, kind `needs-person`, with `confirm` true; the reason is the verdict line |
| `rewind:<contract>` | done | runs again, in order, the nearest earlier step of that contract and every step after it, then this one; what relied on them is asked again |
| `park` | parked (a gate, or a checkpoint the run waits for) or open (a checkpoint it does not), with its gate kept | is parked until a person answers the gate in the tracker; after an open checkpoint it goes on |
| `end:<outcome>` | done | ends with that outcome |

**A `confirm` stop is answered, never re-run.** Show the step's evidence and ask the person;
`resume` with their own words as `answer`. An answer whose first word is yes records the verdict
as accepted: the step is done as it answered, on the same attempt, its verdict gains `(accepted)`,
its result gains `answer` (the answer's whole text, which later steps read as
`result:<contract>.answer`), and the run goes on. One whose first word is no ends the run with the
outcome `declined`. Any other answer is refused (`confirm-answer`, nothing changed). A `resume`
with no answer issues the step again, for a cause that was fixed meanwhile. Never write a yes for
the person.

A missing, unlisted or malformed verdict is a stop of kind `no-verdict`; a `continue` verdict whose
result lacks a required key is a stop of kind `failed`. Neither is ever read as a pass. Result keys
the contract does not list are dropped. A `count` is a whole number of at least 0.

What is reported, and what is never reported: `workflow-contracts.md`.

## Waiting and parked

Two different things, with two names; neither is a stop.

| | Waiting | Parked |
|---|---|---|
| What it is | An issued step that waits inside itself (a queue, a deploy) | A run that waits for a person to answer a gate or a checkpoint in the tracker |
| How it starts | The `wait` command, on the issued step | The step's `REQUESTED` verdict (class `park`) |
| The step's row in `status` | `waiting` | `parked` (`open` for a checkpoint the run does not wait for) |
| The run's `state` | `running` | `parked`; no step is issued |
| Where it is | `position` is the issued step; `status` with `all` gives the reason as `waiting` | `position` is the gate; `parkedAt` names it (`stepId`, `id`, `since`), in `status` and in `status` with `all` |
| How it ends | The step's `done` | `next` with the `gateAnswer` (`gates.md`) |

Both reach the tracker as `waiting`, a parked one with `waitingOn: person`. A step that asked a
question (`ask`, `confirm`) is a stop, not either of these: its row says `waiting` (that mark too) and the run's
`state` is `stopped`. `wait` on a gate or a checkpoint is refused (`wait-not-a-step`), and a `next`
with a `gateAnswer` for a run that is not parked is refused (`not-parked`).

## Going back

A `rewind:<contract>` verdict runs again the nearest earlier step of that contract and every step
after it, up to the step that answered. The step it goes back to always runs and stops on failure
(`start` refuses any other, `rewind-not-always`). For each step in between:

| The step | After the rewind |
|---|---|
| Switched off | Stays off |
| Conditional | Its condition is decided again when the run reaches it, from the facts passed then; it may be skipped this time, or run although it was skipped before |
| Failed and carried on past (`onFail` `continue`) | Runs again; the old failure no longer counts and leaves `continuedPastFailures` unless it fails again |
| A gate, or a checkpoint the run waits for | Asked again as a new attempt, whatever was answered before: the approval was for what the rewind replaced |
| A checkpoint the run does not wait for | Left exactly as it is, open or answered; it is never asked twice |
| A step whose verdict recorded the run's outcome | Its record is dropped until it answers again |

## Counting a step's re-issues

One rule decides when a step that keeps coming back stops the run (`attempts-exhausted`). The limit
is the contract's `maxAutoRedo`, else five.

| Why the step is handed out again | Counted |
|---|---|
| The plain order, a person's `resume`, a person's `answer` | Never |
| Its proof went stale or did not match (the runner's own re-issue) | Yes |
| A rewind went back to it | Yes |
| Its own verdict asked for another go (`redo:self`) | Only where its contract sets `maxAutoRedo` |
| A person asked for changes at a gate (`CHANGES`) | Yes: changes asked on the fifth attempt stop the run |
| The story claim asked again for an adopted parked run | Never |

The count goes back to zero when the step's proof holds, when a gate is approved, and when a person
resumes the stop. A step is never handed out more than 50 times, whatever the cause.

## Stops

| Kind | What happened | What a person does |
|---|---|---|
| `failed` | The step answered with a stopping verdict, or its result was incomplete | Fix the cause, then `resume`; or do the step by hand and report it with `done` |
| `needs-person` | The step asked a question, or (`confirm`) waits for a yes or no | `resume` with the `answer` |
| `no-verdict` | The answer did not open with a verdict the contract lists | Run the step again (`resume`), or report its real verdict with `done` |
| `proof` | A proof was refused by a value or a named rule, or could not be checked | Fix what the reason names, then `resume` |
| `attempts-exhausted` | The same step came back up to its limit ("Counting a step's re-issues"), or it has run 50 times | Find why its proof never holds, then `resume`, which resets the re-issue count but never the 50 |

**A merge stop** (`mayHaveLanded`, any kind): the merge answered, so it may have landed before it
stopped. Check its `commit` with the landing test
(`${CLAUDE_PLUGIN_ROOT}/skills/merge-story/references/merge-paths.md`, "Already landed"), which has
three answers. Exactly that commit landed → report it with `done` on that attempt; never `resume`,
which reads the moved checkout as new work. It landed, but the check cannot prove how → a person
reads everything the base gained past it, merges included (`git log --oneline
<commit>..origin/<workingBase>`), for any later commit of this story and any merge commit made on
the story's branch. A hint, not decisive: a commit of `git rev-list <commit>..<story-ref>`
(`origin/<branch>` where it exists, else the local `<branch>`) that `git merge-base --is-ancestor
<that> origin/<workingBase>` finds on the base is one to look at; an upstream commit the story
branch merely contains (a rebase, a base merge) is not story work. Neither among it (a release or
other checked landings) → `done` naming that commit; either among it → `done` is not valid: `resume` with `"close": true`, and the person is told that work landed without this run's
checks and review; unsure → the stop stays
(`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/run-stops.md`). Nothing landed → `resume` with
`"landed": false`. Until then `resume` answers with the same stop (`merge-may-have-landed`).

## History

**The runner keeps the run's history and sends it itself; the driver forwards nothing.** One
event per change, numbered from 1 (`${CLAUDE_PLUGIN_ROOT}/schemas/run-events.schema.json`); a
refused command writes none. A command adds its events to an owner-only outbox beside the state,
writes the state, then makes one bounded try (seconds) at sending what DevStride lacks, oldest
first, with the machine's own key, then ended runs left unsent. A failed send keeps the outbox,
waits a minute and never stops a step; `say` is one line to say once per run.
`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/workflow-reports.md` is the authority for the
switch (`workflows`, `DEVSTRIDE_WORKFLOWS`) and those lines.

How a run's end is named to the tracker: `completed`, or the `recordsOutcome` (`landed`,
`handed-up` or `shipped`) of its latest finished step whose verdict carries one
(`COMPLETE: LANDED` → `landed`, `DONE` → `shipped`), when the workflow answer's `runOutcomes` lists
it; a dry run (`end:dry-run`) `ended-early`; one held, replaced or declined (a no at a `confirm`
stop) `interrupted`, never `landed` or `shipped`; any other stop `failed`. A `needs-person` stop
ends nothing: the run stays open and `resume` carries it on. A tracker listing no `runOutcomes` is
never told `landed`, `handed-up` or `shipped`. A step repaired by hand (`done` on the step a run
stopped on) shows in the tracker as a later attempt, because the tracker never changes an attempt
it holds as finished.
`judge` reads an item and the tracker's answer for that item's runs and says whether the newest
run did every step its definition requires: `complete`, `incomplete` (with the steps never
reported, failed or never finished), `running`, `unknown` (no stored definition) or
`not-reported`.

## Heartbeat and ship intent

A `run` answer's `heartbeat` holds `phase`, `stage` and `shipIntent`. Send `phase` as the story
claim's heartbeat phase exactly as `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/story-claims.md`
describes; null means no heartbeat. `shipIntent`, when not null, is the ready request for
`${CLAUDE_PLUGIN_ROOT}/skills/build-item/scripts/ship-intent.py record`
(`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/ship-intent.md`).

## Resuming

State is one owner-only file per session and item (for a run with no item, per session and run
id; one an earlier plugin wrote is carried on under its run id) under the user's cache folder
(`$XDG_CACHE_HOME`, else `~/.cache`), refused when that folder is under a `.git` folder or inside
the plugin, pruned after seven days. After a compaction: `status`, then `resume`. A cleared
conversation is a new session: `resume` with the item (or the run id) adopts the newest unfinished
run that another of this user's sessions left on this machine for this repository (the same
remote, or, with none, the same git folder; another repository's is refused,
`run-other-repository`), keeps its run id, re-binds it to the adopting checkout (`cwd`, default the
current directory) and names the old session and checkout in `adoptedFrom`; its history records the
takeover and carries on, with what the old session left unsent. A run parked at a gate asks its story claim step again
first. Both kinds of run are adopted the same way: one with an item by the item, one with no item
only by its run id (listed by `status` with `all` and `others`); a run with no item is never parked, because `start` refuses a gate or a
checkpoint in it (`gate-needs-item`). A finished run is never adopted, and an adoption that
would overwrite this session's own open run for that item (no item: of that workflow) is refused (`run-open`), unless a resume by run id says `beside` `true`, as a start may. **An adopted
run goes on only on its story branch** (the branch step's `branch`) until its merge has finished:
while the checkout is on any other branch, or none, every command that would hand out a step is
refused (`wrong-branch`, naming the branch; nothing changes, the adoption included), so check the
branch out and send the same request again: `git fetch origin
"+refs/heads/<branch>:refs/remotes/origin/<branch>"` (for a branch only here it fails,
harmlessly); then `git checkout <branch>` when it exists here, else `git checkout -b
<branch> origin/<branch> && git config branch.<branch>.remote origin && git config
branch.<branch>.merge refs/heads/<branch>` (so a bare `git push` works where the clone's
fetch rule misses the branch); `git rev-parse --abbrev-ref HEAD` printing it. The branch held by
another worktree (`git worktree list`), or absent here and on the remote → STOP, naming what a
person must do: free it there, or push it from the checkout that has it. Stops are still answered, and a merge handed back as it
was issued is exempt: it may have landed and deleted the branch, and its landing is checked first.
The runner cannot tell a live session's run from a dead one's: the driver checks the story's claim first. Two
sessions driving one run at once are not supported.

## Cited by

- `skills/run-workflow/SKILL.md` — the pointer before the loop ("Read … in full before the first
  command, and again after a compaction").
- `skills/build-item/SKILL.md` — The run ("Read … in full before the first command, and again
  after a compaction").
- `skills/run-workflow/references/workflow-contracts.md` — `merge-lands-what-was-checked` (the
  merge stop).
