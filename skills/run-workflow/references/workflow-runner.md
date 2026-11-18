---
load: contract
---
# The step runner — one step at a time, with the proof each step leaves

`${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/scripts/workflow.py` walks a workflow definition
(`${CLAUDE_PLUGIN_ROOT}/schemas/workflow.schema.json`) against the step contract catalog
(`${CLAUDE_PLUGIN_ROOT}/schemas/step-contracts.json`). **It decides and records; it never acts**: no
network, no tracker call, no skill run, and git only to read (the tree of HEAD, a patch id, the
remote's name). Whoever drives it (a person, another agent, a loop) runs the steps.

## Commands

`python3 -B workflow.py <command>`: one JSON object on stdin, one on stdout. Exit 0 is an answer.
Exit 2 is a refusal: exactly one `workflow: <code>: <message>` line on stderr, nothing on stdout,
nothing changed. Exit 1 is anything else, also one line. Every request may carry `session` (else
the agent's own session id) and names its run by `item`, by `runId`, or by being the session's only
open run.

| Command | Request | What it does |
|---|---|---|
| `start` | `definition` or `definitionFile` (a file of at most 256 KB), `context`, `replace`? | Validates everything before writing anything, then issues the first step. An open run for the same session and item is refused (`run-open`) unless `replace` is true, which ends the old run as interrupted |
| `next` | | The next action. Asked twice before `done`, it returns the same step and the same attempt |
| `done` | `stepId`, `attempt`, `output` (the step's whole final answer, as text) | Records the issued step's answer and returns the next action plus `recorded`. Any other step or attempt is refused (`not-current-step`), except the step a stopped run stopped on, repaired by hand |
| `status` | `includeDefinition`? | Read-only: `state` (running, stopped or finished), `position`, one row per step and a ready Markdown `table`. With `includeDefinition`, one report object carrying the definition |
| `resume` | `answer`? | Re-issues the step after a restart or a stop. `answer` is a person's reply to a question and reaches that step's payload for that attempt only |

The context: `item` (an item number or null), `goal`, `profile` (`name` and `source`),
`workingBase`, `oneOff`, `route` (`train`, `develop-pr` or `epic-release`), `releaseUnit`,
`reviewMoment`, `branchSlug`, `mode`, `cwd` (default: the current directory). The runner adds
`repository`. A step whose payload needs a context key that is absent refuses the start
(`context-missing`).

An action is one of:

- **`run`**: `step` (`id`, `name`, `phase`, `contract`, `attempt`), `skill` (the built-in skill to
  invoke), `payload`, `argument` (the contract's template rendered from the payload, else the
  payload as one compact JSON string: pass it to the skill unchanged) and `heartbeat`.
- **`finished`**: `outcome` (`completed`, or the outcome a step ended the run with, such as `held`)
  and `results`, each finished step's result by contract.
- **`stopped`**: `kind`, `reason`, `stepId`.

Every answer also carries `runId` and `reports`; `start` adds the definition's hash.

## What `start` refuses

`bad-schema`, `duplicate-step-id`, `plugin-too-old` (the definition needs a newer plugin),
`unknown-contract`, `unknown-contract-major`, `requires-missing` and `requires-not-earlier` (a
contract's required step is absent, or only later), `required-not-always`, `required-not-stop` and
`required-off` (the step that provides a required contract must always run, must stop the run when
it fails and cannot be switched off), `unsupported-gate`, `unsupported-when`, `unsupported-source`
and `unsupported-on-fail` (features this plugin does not run: a gate, a conditional or manual step,
a library or repository skill, a step that carries on after a failure), `skill-missing` (a step
names a skill this plugin does not have) and `repository-required` (a contract bound to the tree or
the patch, outside a git work tree). Required steps come only from each contract's `requires` list
in the catalog, so a renamed or re-sourced step is covered whatever skill runs it: a workflow can
replace a required step, never drop, weaken or move it.

## A step's answer

The first non-blank line is the verdict: the contract's label, a colon and a space, one listed
value (the longest that matches), then the detail where the value takes one. Verdict lines are
written exactly as the catalog lists them. The lines after it, up to the first fenced block tagged
json, are evidence; that block is the result, one JSON object of at most 16 KB. Nothing after it is
kept. The value's class decides what happens:

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
the contract does not list are dropped.

**Kept, and reported:** the verdict line (200 characters), the evidence (the reporting helper's
caps) and https links (`pullRequest`, `commit`, `comment`) plus the branch name from the result's
`links`. An evidence line that holds a credential marker (a bearer token, a version-control or chat
token prefix, a private key header, a claim holder, or a password, token or secret assignment) is
dropped whole, and a verdict detail that holds one is replaced by `[withheld]`. Raw session text is
never kept.

## Payloads

Each contract maps payload keys to paths: a context path (`context.` and a key), an earlier step's
result (`result:`, a contract, optionally a key), or one of two step paths: the step's own answer
from a person, and the proof of its previous attempt. A trailing `?` makes a path optional (null
when missing). The runner then adds two reserved keys, `step` (the issued step's id) and
`contract` (its contract), so one skill that serves several steps can tell them apart.

## Proofs

A step's proof is the `proof` object inside its result. Its contract binds it:

- **tree**: the proof's `tree` must be the tree of HEAD when the step answers, and stays valid
  only while it is.
- **patch**: the proof's `patchId` must be the stable patch id of everything on HEAD since the
  proof's `base`. A base that moved under an unchanged patch keeps the proof.
- **none**: nothing in the repository binds it.

Whatever the binding, a proof is void once a step it requires is completed again after it
(supersession): a second build voids the risk check, the local checks and the review that came from
the first. One exception keeps the patch binding meaningful: a step issued again only to refresh
its own stale proof does not void the steps that rely on it.

A finished step is re-examined only while a later step that requires it has not finished, so
nothing before a finished merge is re-opened. `next` issues the first step, in order, that is not
finished with a valid proof: a stale proof re-issues the step that produced it before anything that
relies on it. A proof that does not match the repository when the step answers counts as a failed
attempt and the step is issued again. The runner counts its own re-issues per step and stops at the
fifth (kind `attempts-exhausted`).

Two named rules, a closed list:

- `risk-triggers-need-verifiers`: a risk-check proof that names triggers and ran no verifier is
  refused.
- `none-configured-needs-pull-request-route`: local checks that found nothing configured are
  accepted by a merge only when the review ran on a pull request, where CI is the gate.

## satisfiedBy — one step standing in for another's proof

A catalog entry may carry `satisfiedBy`: a list of other catalog contracts, no duplicates, never
itself. Wherever a `requires` list names contract X, the nearest earlier step carrying X **or a
contract in X's list** meets it. It is honoured in three places: start validation (a stand-in that
is absent, later, conditional, non-stopping or switched off is refused exactly as the original
would be), payload paths (a result path naming X reads the stand-in's result, so a stand-in must
always give every key a dependent reads without a `?`), and supersession. A server that checks
workflows reads the same field. Only a release that adds a contract meant to stand in appends to a
list; nothing redefines the rule. No shipped contract carries the field yet.

## Stops

| Kind | What happened | What a person does |
|---|---|---|
| `failed` | The step answered with a stopping verdict, or its result was incomplete | Fix the cause, then `resume`; or do the step by hand and report it with `done` |
| `needs-person` | The step asked a question | `resume` with the `answer` |
| `no-verdict` | The answer did not open with a verdict the contract lists | Run the step again (`resume`), or report its real verdict with `done` |
| `proof` | A proof was refused by a named rule, or could not be checked | Fix what the reason names, then `resume` |
| `attempts-exhausted` | The same step was re-issued until the limit | Find why its proof never holds, then `resume` (which resets the count) |

## Reporting

Every answer's `reports` is a list of ready argument objects for the tracker's step-recording tool
(`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/workflow-reports.md`): a running report when a
step is issued, a finished one when it ends, at most four per object, the definition in a run's
first object (and again after an adoption), the run's end in its last. A run that finishes is
reported `completed`; one held, replaced or waiting for a person `interrupted`; any other stop
`failed`. **The runner never sends them.** The caller forwards each object, in order, through the
`workflows` seam and fails open: once the tool is absent, refused or unreachable it says one plain
line, sends nothing more for that run, never retries and never stops the run. When the tracker asks
for the definition, send the object `status` returns with `includeDefinition`.

## Heartbeat and ship intent

A `run` answer's `heartbeat` holds `phase`, `stage` and `shipIntent`. Send `phase` as the story
claim's heartbeat phase exactly as `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/story-claims.md`
describes; null means no heartbeat. `shipIntent`, when not null, is the ready request for
`${CLAUDE_PLUGIN_ROOT}/skills/build-item/scripts/ship-intent.py record`
(`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/ship-intent.md`).

## Resuming

State is one owner-only file per session and item under the user's cache folder, never inside a
repository or the plugin, pruned after seven days. After a compaction: `status`, then `resume`. A
cleared conversation is a new session: `resume` with the item adopts the newest unfinished run for
that item that another of this user's sessions left on this machine, keeps its run id, and the next
report carries the definition again under the new session. A finished run is never adopted. Two
sessions driving one run at once are not supported.

## Cited by

- `skills/run-workflow/SKILL.md` — the pointer before the loop ("Read … in full before the first
  command, and again after a compaction").
