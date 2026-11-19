---
load: contract
---
# The step runner — one step at a time, with the proof each step leaves

`${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/scripts/workflow.py` walks a workflow definition
(`${CLAUDE_PLUGIN_ROOT}/schemas/workflow.schema.json`) against the step contract catalog
(`${CLAUDE_PLUGIN_ROOT}/schemas/step-contracts.json`). **It decides and records; it never acts**: no
network, no tracker call, no skill run, and git only to read. Whoever drives it runs the steps.
This file is what a driver needs: the commands, the answers, the stops, reporting and resuming.
**Read `${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/references/workflow-contracts.md` in full before
writing or changing a definition or a contract, or when a stop names a refused proof and you need
why**: what `start` refuses, payloads, proofs and their bindings, the named rules, and what is
reported.

## Commands

`python3 -B workflow.py <command>`: one JSON object on stdin, one on stdout. Exit 0 is an answer.
Exit 2 is a refusal: exactly one `workflow: <code>: <message>` line on stderr, nothing on stdout,
nothing changed. Exit 1 is anything else, also one line: the runner or its install is broken, so
say the line and stop; never retry it. Every request may carry `session` (else the agent's own
session id) and names its run by `item`, by `runId`, or by being the session's only open run.

| Command | Request | What it does |
|---|---|---|
| `start` | `definition` or `definitionFile` (a file of at most 256 KB), `context`, `replace`? | Validates everything before writing anything, then issues the first step. An open run for the same session and item is refused (`run-open`) unless `replace` is true, which ends the old run as interrupted |
| `next` | | The next action. Asked again before `done`, it hands back the issued step and attempt as they were: the step may already have acted, so only its `done` moves the run on |
| `done` | `stepId`, `attempt`, `output` (the step's whole final answer, as text) | Records the issued step's answer and returns the next action plus `recorded`. Any other step or attempt is refused (`not-current-step`), except the step a stopped run stopped on, repaired by hand |
| `status` | `includeDefinition`? | Read-only: `state` (running, stopped or finished), `position`, one row per step and a ready Markdown `table`. With `includeDefinition`, one report object carrying the definition |
| `resume` | `answer`?, `cwd`?, `landed`?, `close`? | Continues after a restart or a stop: an issued step comes back as it was, otherwise as `next`. `answer`, a person's reply to a question, reaches that step's payload for that attempt only. A merge stop comes back as the stop until `landed` is `false`. `close` `true` ends the run as interrupted |

The context: `item` (an item number or null), `goal`, `profile` (`name` and `source`),
`workingBase`, `oneOff`, `route` (`train`, `develop-pr` or `epic-release`), `releaseUnit`,
`reviewMoment`, `branchSlug`, `mode` (the story claim's mode:
`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/story-claims.md`), `cwd` (default: the current
directory). The runner adds `repository`. A start is refused (`context-missing`) unless the context
holds every key a step's payload reads without a `?`: for the shipped contracts, all of them.

An action is one of:

- **`run`**: `step` (`id`, `name`, `phase`, `contract`, `attempt`), `skill` (the built-in skill to
  invoke), `payload`, `argument` (the contract's template rendered from the payload, else the
  payload as one compact JSON string: pass it to the skill unchanged) and `heartbeat`.
- **`finished`**: `outcome` (`completed`, or the outcome a step ended the run with, such as `held`)
  and `results`, each finished step's result by contract.
- **`stopped`**: `kind`, `reason`, `stepId`; a stop of a merge that answered adds `mayHaveLanded`
  (true), its `attempt` and the `commit` it was handed.

Every answer also carries `runId` and `reports`; `start` adds the definition's hash.

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
| `end:<outcome>` | done | ends with that outcome |

A missing, unlisted or malformed verdict is a stop of kind `no-verdict`; a `continue` verdict whose
result lacks a required key is a stop of kind `failed`. Neither is ever read as a pass. Result keys
the contract does not list are dropped. A `count` is a whole number of at least 0.

What is reported, and what is never reported: `workflow-contracts.md`.

## Stops

| Kind | What happened | What a person does |
|---|---|---|
| `failed` | The step answered with a stopping verdict, or its result was incomplete | Fix the cause, then `resume`; or do the step by hand and report it with `done` |
| `needs-person` | The step asked a question | `resume` with the `answer` |
| `no-verdict` | The answer did not open with a verdict the contract lists | Run the step again (`resume`), or report its real verdict with `done` |
| `proof` | A proof was refused by a value or a named rule, or could not be checked | Fix what the reason names, then `resume` |
| `attempts-exhausted` | The same step was re-issued until the limit, or has run 50 times | Find why its proof never holds, then `resume`, which resets the re-issue count but never the 50 |

**A merge stop** (`mayHaveLanded`, any kind): the merge answered, so it may have landed before it
stopped. Check its `commit` with the landing test
(`${CLAUDE_PLUGIN_ROOT}/skills/merge-story/references/merge-paths.md`, "Already landed"), which has
three answers. Exactly that commit landed → report it with `done` on that attempt; never `resume`,
which reads the moved checkout as new work. It landed, but the check cannot prove how → a person
reads every commit the base gained past it (`git log --no-merges --oneline
<commit>..origin/<workingBase>`; while the story branch exists, a commit of `git rev-list
<commit>..origin/<branch>` that `git merge-base --is-ancestor <that> origin/<workingBase>` finds on
the base is a later story commit): no later commit of this story's branch among it (a release or
other checked landings) → `done` naming that commit; a later story commit among it → `done` is not
valid: `resume` with `"close": true`, and the person is told that work landed without this run's
checks and review; unsure → the stop stays
(`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/run-stops.md`). Nothing landed → `resume` with
`"landed": false`. Until then `resume` answers with the same stop (`merge-may-have-landed`).

## Reporting

Every answer's `reports` is a list of ready argument objects for the tracker's step-recording tool:
a running report when a step is issued, a finished one when it ends, at most four per object, the
definition in a run's first object (and again after an adoption), the run's end in its last. A run
that finishes is reported `completed`; one held, replaced or waiting for a person `interrupted`;
any other stop `failed`. **The runner never sends them.**
`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/workflow-reports.md` is the authority for
sending: its gate (the `workflows` key and `DEVSTRIDE_WORKFLOWS`) decides whether anything is sent
and through which provider or command, and its fail-open rule holds as written: send nothing more
for the run after the first failure, never retry, never stop or slow a step, and never say anything
about reporting to the person. When the tracker asks for the definition, the refused object is sent
again with the `definition` from `status` with `includeDefinition` added, as that file says.

## Heartbeat and ship intent

A `run` answer's `heartbeat` holds `phase`, `stage` and `shipIntent`. Send `phase` as the story
claim's heartbeat phase exactly as `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/story-claims.md`
describes; null means no heartbeat. `shipIntent`, when not null, is the ready request for
`${CLAUDE_PLUGIN_ROOT}/skills/build-item/scripts/ship-intent.py record`
(`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/ship-intent.md`).

## Resuming

State is one owner-only file per session and item under the user's cache folder
(`$XDG_CACHE_HOME`, else `~/.cache`), refused when that folder is under a `.git` folder or inside
the plugin, pruned after seven days. After a compaction: `status`, then `resume`. A cleared
conversation is a new session: `resume` with the item (or the run id) adopts the newest unfinished
run that another of this user's sessions left on this machine for this repository (the same
remote, or, with none, the same git folder; another repository's is refused,
`run-other-repository`), keeps its run id, re-binds it to the adopting checkout (`cwd`, default the
current directory) and names the old session and checkout in `adoptedFrom`; the next report carries
the definition again under the new session. A finished run is never adopted, and an adoption that
would overwrite this session's own open run for that item is refused (`run-open`). **An adopted
run goes on only on its story branch** (the branch step's `branch`) until its merge has finished:
while the checkout is on any other branch, or none, every command that would hand out a step is
refused (`wrong-branch`, naming the branch; nothing changes, the adoption included), so check the
branch out and send the same request again. Stops are still answered, and a merge handed back as it
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
