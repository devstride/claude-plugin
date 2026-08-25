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
    "gateJobName": null
  }
}
```

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

## Lessons store

```json
{ "lessonsDoc": ".claude/ds-lessons.md" }
```

**Write the key and stop.** The store has a single writer — the review skill, at settle time — and
its absence is a valid state for every reader and for that writer, which creates it when it has a
first lesson worth keeping. There is no setup prerequisite, so a file created here would be a second
writer producing a store with nothing in it. The format is review's to own and document; setup only
says where the file goes.
