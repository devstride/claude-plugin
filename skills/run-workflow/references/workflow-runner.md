---
load: contract
---
# The step runner — one step at a time, with the proof each step leaves

`${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/scripts/workflow.py` walks a workflow definition
(`${CLAUDE_PLUGIN_ROOT}/schemas/workflow.schema.json`) against the step contract catalog
(`${CLAUDE_PLUGIN_ROOT}/schemas/step-contracts.json`). **It decides and records; it never acts**: no
network, no tracker call, no skill run, and git only to read (HEAD and its tree, a patch id, the
remote's name). Whoever drives it (a person, another agent, a loop) runs the steps.

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
| `resume` | `answer`? | Continues after a restart or a stop: an issued step comes back as it was, otherwise as `next`. `answer`, a person's reply to a question, reaches that step's payload for that attempt only |

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
- **`stopped`**: `kind`, `reason`, `stepId`.

Every answer also carries `runId` and `reports`; `start` adds the definition's hash.

## What `start` refuses

`bad-schema` (a field the definition schema requires is missing, of the wrong type or past its
limit: at most 12 phases, 40 steps in a phase, 100 in all), `credential-in-definition` (a string
that looks like a credential, anywhere in it, named by where it is, never echoed),
`duplicate-step-id`, `plugin-too-old` (the definition needs a newer plugin), `unknown-contract`,
`unknown-contract-major`, `requires-missing` and `requires-not-earlier` (a contract's required step
is absent, or only later, or a second step providing it comes after a step that requires it, whose
changes then nothing would check), `required-not-always`, `required-not-stop` and `required-off`
(the step that provides a required contract must always run, must stop the run when it fails and
cannot be switched off), `unsupported-gate`, `unsupported-when`, `unsupported-source` and
`unsupported-on-fail` (features this plugin does not run: a gate, a conditional or manual step, a
library or repository skill, a step that carries on after a failure), `skill-missing` (a step names
a skill this plugin does not have) and `repository-required` (a contract bound to the tree or the
patch, outside a git work tree). Required steps come only from each contract's `requires` list in
the catalog, so a renamed or re-sourced step is covered whatever skill runs it: a workflow can
replace a required step, never drop, weaken or move it.

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

**Reported:** the verdict line (200 characters), the evidence (the reporting helper's caps), https
links (`pullRequest`, `commit`, `comment`) and the branch name from `links`, the skill that ran,
and the definition. What is shaped like a credential (an Authorization, Bearer or Basic value of 16
characters or more, an `x-api-key` header, a web token, a URL with a password, a known token prefix,
a private key, a claim holder, or one word naming a secret, token, password or API, access or
private key, assigned, or a `--password`/`--token`/`client_secret` flag, followed by 7 or more
characters, not all digits) is never reported: the evidence
line or link is dropped, the verdict detail becomes `[withheld]`, the definition is refused (also for such a key holding such a
string), and a refusal line says it is not shown. **Not scrubbed:** the result and the proof, kept as given in the
owner-only state file and handed to later payloads and to `finished`, never reported.

## Payloads

Each contract maps payload keys to paths: a context path (`context.` and a key), an earlier step's
result (`result:`, a contract, optionally a key), or a step path: the step's own answer from a
person, the proof of its previous attempt, or the commit it was issued on (`head`). A trailing `?`
makes a path optional (null when missing). The runner then adds two reserved keys, `step` (the
issued step's id) and `contract` (its contract), so one skill that serves several steps can tell
them apart.

## Proofs

A step's proof is the `proof` object inside its result. A proof key the catalog lists `values` for
takes only those, and a verdict value that pins one (its `proof`) needs exactly it:
`LOCAL CHECKS: NOT CONFIGURED` carries kind `none-configured`, a pass `receipt`. Its contract binds
it:

Each command reads HEAD once, as a full commit id, and checks every proof against that commit.

- **tree**: the proof's `tree` must be that commit's tree when the step answers, and stays valid
  only while it is.
- **patch**: the proof's `patchId` must be the verbatim patch id of everything on that commit since
  the proof's `base`, every byte counted, white space too:
  `git diff --no-color --no-ext-diff --no-textconv --no-relative --src-prefix=a/ --dst-prefix=b/ --ignore-submodules=none --unified=3 --no-renames --diff-algorithm=myers <base>...<commit> -- | git patch-id --verbatim`.
  A git without `--verbatim` stops the run (kind `proof`). A base that moved under a byte-identical
  patch keeps the proof.
- **none**: nothing in the repository binds it.

Whatever the binding, a proof is void once a step it requires is completed again after it
(supersession): a second build voids the risk check, the local checks and the review that came from
the first. One exception keeps the patch binding meaningful: a step issued again only to refresh
its own stale proof does not void the steps that rely on it. In this catalog those are the review,
bound to its own patch and re-checked against it, and the merge, which has not run yet.

A finished step is re-examined only while a later step that requires it has not finished, so
nothing before a finished merge is re-opened. `next` issues the first step, in order, that is not
finished with a valid proof: a stale proof re-issues the step that produced it before anything that
relies on it. A proof that does not match the
repository when the step answers counts as a failed attempt and the step is issued again. The
runner counts its own re-issues per step (not a step's own `redo:self`), starts again from 0 when
the step finishes with a proof that holds, and stops at the fifth in a row (kind
`attempts-exhausted`). A local-checks pass names at least one command and carries a receipt.

Three named rules, a closed list:

- `risk-triggers-need-verifiers`: a risk-check proof that names triggers and ran no verifier is
  refused.
- `none-configured-needs-pull-request-route`: local checks that found nothing configured are
  accepted by a merge only when the review ran on a pull request (path `pull-request`), where CI is
  the gate.
- `merge-lands-what-was-checked`: the merge is handed `commit`, the full id the local checks' tree
  and the review's patch were just found to hold for. A merge skill merges exactly that commit
  (for a pull request, `--match-head-commit <commit>`) and answers `MERGE: REFRESHED` when HEAD is
  no longer it. Reported landed (also by hand, after a stop), its proof's `head` names that id;
  another commit, or none, stops the run (kind `proof`), and `resume` checks the new commit first.

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
| `proof` | A proof was refused by a value or a named rule, or could not be checked | Fix what the reason names, then `resume` |
| `attempts-exhausted` | The same step was re-issued until the limit, or has run 50 times | Find why its proof never holds, then `resume`, which resets the re-issue count but never the 50 |

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
about reporting to the person. When the tracker asks for the definition, send the object `status`
returns with `includeDefinition`.

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
run that another of this user's sessions left on this machine, keeps its run id, and the next
report carries the definition again under the new session. A finished run is never adopted, and an
adoption that would overwrite this session's own open run for that item is refused (`run-open`).
Two sessions driving one run at once are not supported.

## Cited by

- `skills/run-workflow/SKILL.md` — the pointer before the loop ("Read … in full before the first
  command, and again after a compaction").
