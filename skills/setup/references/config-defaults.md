# Shipped config defaults — the exact values `setup` writes

The values `setup` writes for keys that detection and the interview cannot produce. **Copy them
verbatim.** They are not illustrations, and they are not to be paraphrased, re-worded or
"improved" at write time: the delivery skills read these keys as literal strings, and a value
reworded into something equivalent-looking is a value that no longer matches.

**This is not one blob to paste, though.** A few values marked below are *decisions*, computed per
repository from what the run actually found — they appear here for their shape and their reasoning,
not as a value to copy. Each one says so where it appears.

Where a key's value comes from somewhere else — detection, an interview answer, the work-type
mapping — that source wins and nothing here applies. This file covers the remainder.

## Delivery profile

```json
{ "profile": "standard" }
```

The one interview answer that moves several keys at once. What each profile means, every knob it
sets, the floors no profile removes, and the rule that a key present in the file beats the profile's
default all live in the contract,
`${CLAUDE_PLUGIN_ROOT}/skills/plan/references/delivery-profiles.md` — read it before asking the
question, and cite it rather than restating it. This file records only what setup writes: the word
itself, and the profile's values for the three knobs that also exist as their own config keys. All
three rows are copied from the contract's table; the fast-merge row's rule is spelled out in the
next section:

| Key | `prototype` | `standard` | `enterprise` |
|---|---|---|---|
| `epicIntegrationBranches.autoRelease` | `true` | `false` | `false` |
| `epicIntegrationBranches.fastStoryMerges.enabled` | `true` whenever `verify.typecheck` is set — Claude's build-time pass is the local engine | the existing rule, below | the existing rule, below |
| `review.pollTimeoutMinutes` | `5` | `10` | `20` |

Under every profile `fastStoryMerges.enabled` still turns on the repository's own commands and
roster — the profile decides which precondition applies, never whether one does.
`profile` is written on every run, `standard` included — an absent key reads as `standard` too, but a
re-run cannot tell a chosen default from a question never asked, and the doctor cannot report a
source for a value that is not there.

`profileOverrides` is optional and **omitted by default** — setup never writes it. It is the
operator's hand-edit for pinning one knob under a profile, and its vocabulary is the contract's.

## Branch naming

```json
{
  "branchNaming": {
    "pattern": "<prefix>/<MM-DD-YY>/<slug>",
    "prefixSource": "git user.name first name, lowercased; ask if empty or ambiguous",
    "dateFormat": "MM-DD-YY"
  }
}
```

`prefixSource` is prose the branch skills read and act on, not a format string — which is why it
must be copied rather than summarized.

## Integration branches

```json
{
  "integrationBranch": null,
  "epicIntegrationBranches": {
    "enabled": true,
    "pattern": "<prefix>/<MM-DD-YY>/<epic-number>-<epic-title-slug>",
    "slugRule": "epic title kebab-cased, lowercased, [a-z0-9-] only, execution-order bracket prefix stripped, truncated to ~6 words",
    "releaseTarget": "baseBranch",
    "fastStoryMerges": {
      "enabled": "DECIDED PER REPOSITORY — see below; never copied from here",
      "requireLocalVerifyGreen": true,
      "epicReleaseIsFirstCloudPass": true
    },
    "autoRelease": false,
    "deleteBranchAfterRelease": true
  }
}
```

Two of these come from the profile rather than from this block. **`fastStoryMerges.enabled` above is
deliberately not a copyable value** — writing `true` from this file would enable fast merges on a
repository that cannot safely use them — and `autoRelease` is the profile's, shown here at its
`standard` value:

- **`autoRelease: false`** under `standard` and `enterprise` — a release unit merging to the base
  branch without a human saying so is something an owner should switch on after watching the loop
  run, not inherit on day one. **`prototype` writes `true`**, and setup says so out loud at the
  write, naming the base branch: where that branch is production, or is promoted to it without a
  gate, this is a release with nobody's hand on it, and the owner must hear that from setup rather
  than discover it from a deploy.
- **`fastStoryMerges.enabled`** — the precondition depends on the profile. Under `standard` and
  `enterprise`, write `true` **only** when a local CLI review engine is configured
  (`review.localCommand` non-null) *and* `verify.test` and `verify.typecheck` are both set. Under
  `prototype`, write `true` whenever `verify.typecheck` is set: Claude's build-time adversarial pass
  is the local engine there — it meets the contract's floor on its own — and the profile's story
  gate is type-checks plus the touched suites, so `verify.test` is not required. Under fast merges
  an item gets no pull request and no CI of its own, so the local engines and those local suites
  are the only gate it receives. Otherwise write `false` and say which precondition was missing —
  a `false` under `prototype` contradicts the profile, and the doctor will report it as such.

## Commit conventions

```json
{
  "commitConventions": {
    "messageFormat": "<type>(<scope>): <summary> <itemTag>",
    "reviewFixFormat": "fix(<scope>): <summary> [<itemNumber> review]",
    "epicMergeFormat": "merge: <itemNumber> [<N>] <short scope> into <epic-slug> integration"
  },
  "itemTagFormat": "[I#####]"
}
```

`itemTagFormat` is the shape of the work-item tag in a commit subject. A repository whose tracker
numbers items differently says so here — the interview should ask if the organization's item
numbers visibly do not match this shape.

## Pull-request body

```json
{
  "prBodyTemplate": {
    "sections": [
      {
        "heading": "## Simple Description",
        "guidance": "Plain-language, non-technical: what this does and why, understandable without knowing the codebase."
      },
      {
        "heading": "## Technical Description",
        "guidance": "The approach; the modules, services and components touched; notable design choices."
      },
      {
        "heading": "## Notable Changes to System Architecture or Behavior",
        "guidance": "Architecture, data flow, public contracts, migrations, permissions, user-visible behavior. 'None' explicitly if none."
      },
      {
        "heading": "## Testing Steps",
        "guidance": "Concrete steps to exercise it, plus which automated tests cover it."
      }
    ],
    "noAiAttribution": true
  }
}
```

The sections are rendered in array order, and each is filled from its `guidance` — so an entry needs
both fields to be usable. **A repository with its own pull-request template should have these
replaced by that template's sections**, carried across complete with the text under each heading;
A8 covers where those templates live and how to capture them.

## CI

```json
{
  "ci": {
    "workflowGlobs": [".github/workflows/*.yaml", ".github/workflows/*.yml"],
    "draftGateCondition": "github.event.pull_request.draft == false",
    "gateJobName": null,
    "freezeBaseWhileReleasePrReady": true,
    "expectedRunsPerPullRequest": 1
  }
}
```

`freezeBaseWhileReleasePrReady` is the loop rule behind run-once at the release: while a release
pull request is ready, `build-item` does not merge anything into the base branch and `release`
refuses to flip while another pull request into the release source is mergeable — every merge
beneath a ready release pull request re-runs its merge preview and stales the reviewed diff.
`expectedRunsPerPullRequest` is the number `review` step 8 reports against: `1` per workflow
under `ci.workflowGlobs` on the pull request it settled — several workflows executing once each
is the design; a SECOND executed run of the same workflow is named with its cause. The workflow mechanics
these pair with (concurrency, the tree-identical production skip, the draft gate, the
draft-convention check) are in `ci-cost-patterns.md`, applied by `setup ci`.

`gateJobName` names the job the loop watches to confirm the ready-flip released CI. It is left
`null` because nothing can guess it; the loop falls back to detecting a new run, which works and is
merely slower to be sure of. On a repository with no CI at all, still write the block — the keys
being present and inert is what makes them findable later.

## Lists a repository fills in for itself

```json
{
  "preShipChecks": [],
  "preCommitWiringChecks": [],
  "verify": { "skipDuringStoryBuilds": [] }
}
```

All three start empty, and empty is a real answer rather than a placeholder:

- **`preShipChecks`** — slow suites that must run at the ship boundary. Adding one is a considered
  decision about cost and coverage; setup cannot make it, and guessing produces either a gate that
  runs nothing or one that runs for half an hour uninvited.
- **`preCommitWiringChecks`** — repository-specific wiring assertions, named by that repository.
- **`verify.skipDuringStoryBuilds`** — slow *cloud* suites deferred during story builds. **An entry
  here is a promise that a matching CI job exists.** Listing a suite whose job does not exist makes
  the loop wait for a check that will never run, so this stays empty until someone adds both halves
  together.

## Plugin updates

```json
{
  "plugin": {
    "updateCheck": true,
    "autoUpdate": false,
    "pin": null
  }
}
```

The session-start version check (`hooks/version-check.sh`) reads this block from the repository
it starts in. `updateCheck: true` — it runs, silent when current or offline, and speaks only when
a newer release exists: one line with the exact update commands. `autoUpdate: true` — it applies
the update on disk at session start (the only safe moment; applying mid-loop would change skill
behaviour between the steps of a build) and asks for a restart; the running session is unchanged.
`pin` — a version this repository is deliberately holding at (an incident, a known-good
baseline): the check reports "pinned at X, newest is Y" once and never nags. Setting the
environment variable `DEVSTRIDE_PLUGIN_UPDATE_CHECK=0` disables the check regardless, for CI and
headless runs. The recipe and the record it writes are in
`skills/doctor/references/version-currency.md`.

## Local environment

```json
{
  "localEnvironment": {
    "create": null,
    "recreate": null,
    "recreateMode": null,
    "instanceName": null,
    "seed": null,
    "migrate": null,
    "teardown": null,
    "instanceBoundTo": "none"
  }
}
```

The shipped default says: this repository has not described an isolated local environment.
`branch-hotfix` then asks before touching a database, and `build-item` treats the current checkout
as the only environment there is. A repository whose tooling gives each checkout its own instance
fills the commands in and sets `instanceBoundTo` to what that tooling actually keys on —
`directory` (a second worktree gets its own database, tables and ports, and checking out another
branch inside it keeps them) or `branch`. Commands may carry `<name>` (the instance), `<base>` (the ref to
branch from) and `<branch>` (the new branch, in the repository's own naming convention — a
tool that defaults the branch to the instance name mints a nonconforming one) where the
tooling needs them. This block tells the loop what exists; it never makes the loop
concurrent — the serial-execution rule in `build-item` stands, because a per-checkout instance
isolates dev servers and app data, not shared test infrastructure.

**`recreate` exists because `migrate` and `seed` usually only go FORWARD.** Migrations do not
un-apply and a seed rewrites rows, not schema — so an instance living on development-branch schema
cannot be brought back to a production-branch base by running them. It stays schema-AHEAD of the
code it is now running, and a hotfix can then validate against a schema production does not have.
`recreate` is the tooling's way back: whatever genuinely returns an instance to `<base>`'s schema.
Two shapes qualify, and a repository should pick whichever its tooling actually supports. An
**in-place rebuild** — drop the schema and re-run the checked-out code's migrations, then seed —
is usually simplest, and it keeps the session in a working directory. A **second instance** stood
up from `<base>` also works, but check it can be built at all: a tool that reuses an existing
branch cannot take one that is already checked out somewhere, which is exactly the state
`branch-hotfix` leaves behind. Whichever shape, the rule is that the session must still be in a
working instance afterwards — never a torn-down directory or a detached HEAD, because no config
command can move the caller.

**`recreateMode` says which of the two shapes `recreate` is** — `"inPlace"` or `"newInstance"`.
It exists because the command text does not tell you: a wrapper script is opaque, and each wrong
guess fails in its own way (an in-place command treated as second-instance leaves the session on
the old database; the reverse resets an instance in use). Required whenever `recreate` carries
`<name>`; `branch-hotfix` stops and asks when it is missing.

**`instanceName` exists for the in-place shape.** It is a command whose output is the name of the
instance THIS checkout belongs to — usually a line read out of a file the tooling writes when it
creates one. Without it, a `<name>` in an in-place `recreate` cannot be resolved: nothing else in
this block identifies the current instance, and a guess from the directory name resets a
different one. Leave it `null` where `recreate` needs no `<name>`, or where there are no
instances; `branch-hotfix` stops and asks rather than guessing. A repository whose environment genuinely has no schema (a stateless dev server) leaves it
`null`, and nothing is lost.

## Known cloud reviewers

An `automatedReviewers` entry is requested by the review flow **per its `how`**, and a
`requested_reviewer` bot is requested by node id — so an entry carrying only a display name is
malformed, and the failure is silent: the request creates nothing and the flow waits for a review
that was never asked for. Write complete entries or none.

GitHub's Copilot code reviewer:

```json
{
  "name": "Copilot",
  "how": "requested_reviewer",
  "bot": "copilot-pull-request-reviewer[bot]",
  "value": "copilot-pull-request-reviewer[bot]",
  "graphqlBotId": "BOT_kgDOCnlnWA"
}
```

Two traps worth carrying into the config rather than rediscovering:

- **One reviewer, several spellings.** The login that requests the review and the one the reviews
  endpoint reports is `copilot-pull-request-reviewer[bot]`; the inline-comments endpoint says
  `Copilot`; review threads say `copilot-pull-request-reviewer` with no suffix. Anything filtering
  comments by login therefore drops real findings and looks exactly like "the reviewer left none".
- **The review bot is not the coding agent.** They are different bots with different node ids, and
  requesting the coding agent is accepted while creating no review request at all.

Any other cloud reviewer must be described the same way — a name the user recognizes, a `how` the
review flow understands, and whatever identifier that `how` needs. If the user names a reviewer that
is not in this catalog, ask for those fields rather than inventing them.

## Review engine options

```json
{ "review": { "adaptiveReviewerWait": true } }
```

`adaptiveReviewerWait` — absent means `true`: `review` step 2 stops waiting on a registered
cloud reviewer once its wait exceeds that reviewer's learned p95 latency plus slack (bounded
below by `reviewerRegistrationWindowMinutes`, above by `pollTimeoutMinutes`, and the full
`pollTimeoutMinutes` while the machine's cache is cold — see
`${CLAUDE_PLUGIN_ROOT}/skills/review/references/reviewer-latency.md`). `false` pins the fixed
bound of earlier releases; the backoff cadence and the script still apply, and latency is still
learned so switching it on later starts warm. Like `profileOverrides`, `setup` never writes this
key — it is an operator hand-edit.

`localCommand` placeholders: `<base>` (required — the ref the engine diffs against; round 1 gets
`origin/<baseBranch>`, a delta-scoped round 2 gets the round-1 head SHA) and `<context>`
(optional — round 2 replaces it with `-` and feeds a distilled account of round 1 on stdin,
dropping the `--base` pair because the CLI refuses both together). A template without
`<context>` still gets a delta-scoped round 2, minus the context, and the report says so. A CLI
that rejects `-` fails its launch — reported as this-run degradation; remove the placeholder.

`localReReviewScope` — absent means `"delta"`: round 2 reviews `<round-1 head>...HEAD` unless
`rereview-scope.sh` decides `full` (a new file, more than half the lines rewritten, or a rebase).
`"full"` pins the whole-diff re-review of earlier releases. `setup` never writes it — an
operator hand-edit. Reasoning and the verified CLI facts:
`${CLAUDE_PLUGIN_ROOT}/skills/review/references/delta-re-review.md`.

## Documentation hooks

```json
{
  "docs": {
    "updateSkill": null,
    "releaseNotesSkill": null,
    "updateOnEpicRelease": false
  },
  "release": {
    "deployVerification": null
  }
}
```

The plugin never updates documentation or writes release notes itself. `docs.updateSkill` and
`docs.releaseNotesSkill` name LOCAL skills in the consuming repository — scaffolded by `setup` from
its templates and owned by the repository from then on — and `null` means "no documentation system
here", which every docs phase reports as skipped. Core documentation is updated by default when a
skill is registered; **release notes are written only when the owner passes `--release-notes` to
the release skill**, and only after `release.deployVerification` (or the owner) confirms the deploy
is live. There is deliberately no "when a note is warranted" key: the loop does not interpret one.
`release.docsRepo` is the pre-1.0 shape and is migrated, not written. The contract is
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/docs-hooks.md`.

## Lessons store

```json
{ "lessonsDoc": ".claude/ds-lessons.md" }
```

**Write the key and stop.** The store has a single writer — the review skill, at settle time — and
its absence is a valid state for every reader and for that writer, which creates it when it has a
first lesson worth keeping. There is no setup prerequisite, so a file created here would be a second
writer producing a store with nothing in it. The format is review's to own and document; setup only
says where the file goes.
