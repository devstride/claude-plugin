---
load: contract
---
# Workflow contracts — what a definition may hold, and the proof each step leaves

The rules `${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/scripts/workflow.py` holds a definition and
each step's answer to, for whoever writes or changes a definition
(`${CLAUDE_PLUGIN_ROOT}/schemas/workflow.schema.json`) or a contract of the catalog
(`${CLAUDE_PLUGIN_ROOT}/schemas/step-contracts.json`). Driving a run is
`${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/references/workflow-runner.md`.

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
a skill this plugin does not have) and `repository-required` (a contract bound to the tree, the patch or the
story, outside a git work tree). Required steps come only from each contract's `requires` list in
the catalog, so a renamed or re-sourced step is covered whatever skill runs it: a workflow can
replace a required step, never drop, weaken or move it.

## What is reported

The verdict line (200 characters), the evidence (the reporting helper's caps), https
links (`pullRequest`, `commit`, `comment`) and the branch name from `links`, the skill that ran,
and the definition. What is shaped like a credential (any Authorization value, Bearer or Basic
value of 16 characters or more, an `x-api-key` header, a two-part web token, a URL with a
password, a known token prefix, a private key, a claim holder, or a key whose last dotted part names
a secret, token, password or API, access or private key, assigned, or a `--password`/`--token`/
`client_secret` flag, followed by 7 or more characters, not all digits; read in overlapping
windows) is never reported: the evidence line or link is dropped, the verdict detail becomes
`[withheld]`, the definition is refused (also a key holding such a string), and a refusal
line says it is not shown. **Not scrubbed:** the result and the proof, kept as given in the
owner-only state file and handed to later payloads and to `finished`, never reported.

## Payloads

Each contract maps payload keys to paths: a context path (`context.` and a key), an earlier step's
result (`result:`, a contract, optionally a key), an earlier step's proof (`proof:`, the same
shape), or a step path: the step's own answer from a
person, the proof of its previous attempt (`proof`, whatever its verdict), the proof and result of
its last accepted pass (`passedProof`, `passedResult`: null until one; a `passedProof` whose `head`
this checkout cannot read is handed as null, with `passedUnreadable` true, never as a baseline), or
the commit it was issued on (`head`). A trailing `?`
makes a path optional (null when missing). The runner then adds two reserved keys, `step` (the
issued step's id) and `contract` (its contract).

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
  `git diff --no-color --no-ext-diff --no-textconv --no-relative --src-prefix=a/ --dst-prefix=b/ --ignore-submodules=none --unified=3 --no-renames --diff-algorithm=myers --inter-hunk-context=0 <base>...<commit> -- | git patch-id --verbatim`.
  The flags override git's settings for colour, prefixes, paths, submodules, context, hunk joining,
  renames and the algorithm; its suppressBlankEmpty and quotePath settings are not covered, and fail closed
  (the proof reads as stale). A git without `--verbatim` stops the run (kind `proof`). A base
  that moved under a byte-identical patch keeps the proof.
- **story**: the story's patch since the proof's `base`, computed as for `patch`, must be the same
  at the proof's `head` as at that commit. Any later commit that changes the story (a gate fix, a
  review fix) voids it; a base merged into the story or a rebase does not, because the `base` is
  the moving `origin/<workingBase>` ref: a risk-check proof naming any other base, or one this
  checkout cannot read, is refused (kind `proof`). A `head` that cannot be read voids it too. The risk check is bound this way: what it screened is
  the story as it then stood.
- **none**: nothing in the repository binds it.

Whatever the binding, a proof is void once a step it requires is completed again after it
(supersession): a second build voids the risk check, the local checks and the review that came from
the first. One exception keeps the patch binding meaningful: a step issued again only to refresh
its own stale proof does not void the steps that rely on it (a risk check re-issued after a later
commit leaves the local checks and the review to their own proofs).

A finished step is re-examined only while a later step that requires it has not finished, so
nothing before a finished merge is re-opened. `next` issues the first step, in order, that is not
finished with a valid proof: a stale proof re-issues the step that produced it before anything that
relies on it. A proof that does not match the
repository when the step answers counts as a failed attempt and the step is issued again. The
runner counts its own re-issues per step (not a step's own `redo:self`), starts again from 0 when
the step finishes with a proof that holds, and stops at the fifth in a row (kind
`attempts-exhausted`). A local-checks pass names at least one command and carries a receipt.

Five named rules, a closed list:

- `risk-triggers-need-verifiers`: a risk-check proof that names triggers and ran no verifier is
  refused.
- `risk-check-accumulates`: a risk check accepted after an earlier accepted one reports only the
  delta, and its result is added to the earlier. An entry's id is its `id` when it is an object
  carrying a non-empty string one, else the whole entry as canonical JSON. Each of
  `untrackedDeferrals`, `dismissed`, `deferrals` and `deviations` keeps every earlier entry the new
  result does not name in `resolved` (the ids a later screen fixed or overtook) and gains the new
  ones whose id it lacks; the `counts` are summed, less one `deferred` (or `dismissed`) per earlier
  deferral (or dismissal) resolved; `resolved` gathers every id resolved so far; the `ledger` is
  appended to (unless the new one already starts with it), so it keeps the whole history; and the
  `report` is the new one. Later steps receive only the entries still open. A refused attempt is
  never accumulated, and never handed on.
- `none-configured-needs-pull-request-route`: local checks that found nothing configured are
  accepted by a merge only when the review ran on a pull request (path `pull-request`), where CI is
  the gate.
- `review-names-one-path`: a review whose result `path` and proof `path` differ is refused, so the
  merge and the rule above read the same path.
- `merge-lands-what-was-checked`: the merge is handed `commit`, the full id the local checks' tree
  and the review's patch were just found to hold for. A merge skill merges exactly that commit
  (for a pull request, `--match-head-commit <commit>`) and answers `MERGE: REFRESHED` when HEAD is
  no longer it. Reported landed (also by hand, after a stop), its proof's `head` names that id;
  another commit, or none, stops the run (kind `proof`). After a merge stop, first check whether
  exactly that commit landed: if it did, report it with `done` on the stopped merge, its proof's
  `head` naming that commit, and never `resume` (a checkout left on the base reads as a new
  commit); if another commit landed carrying it, a person decides
  (`workflow-runner.md`, "A merge stop").

## satisfiedBy — one step standing in for another's proof

A catalog entry may carry `satisfiedBy`: a list of other catalog contracts, no duplicates, never
itself. Wherever a `requires` list names contract X, the nearest earlier step carrying X **or a
contract in X's list** meets it. It is honoured in three places: start validation (a stand-in that
is absent, later, conditional, non-stopping or switched off is refused exactly as the original
would be), payload paths (a result path naming X reads the stand-in's result, so a stand-in must
always give every key a dependent reads without a `?`), and supersession. Only a release adding a
stand-in contract appends to a list. No shipped contract carries the field yet.

## Cited by

- `skills/run-workflow/references/workflow-runner.md` — the pointer for definitions and proofs.
- `skills/run-workflow/SKILL.md` — the pointer before a definition is written or changed.
- `skills/review-story/references/review-routes.md` — the patch id command (Proofs).
