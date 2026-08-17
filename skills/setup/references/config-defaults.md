# Shipped config defaults — the exact values `setup` writes

The values `setup` writes for keys that detection and the interview cannot produce. **Copy them
verbatim.** They are not illustrations, and they are not to be paraphrased, re-worded or
"improved" at write time: the delivery skills read these keys as literal strings, and a value
reworded into something equivalent-looking is a value that no longer matches.

Where a key's value comes from somewhere else — detection, an interview answer, the work-type
mapping — that source wins and nothing here applies. This file covers the remainder.

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
      "enabled": true,
      "requireLocalVerifyGreen": true,
      "epicReleaseIsFirstCloudPass": true
    },
    "autoRelease": false,
    "deleteBranchAfterRelease": true
  }
}
```

Two of these are decisions, not defaults, and both are deliberately set to the cautious side:

- **`autoRelease: false`** — a release unit merging to the base branch without a human saying so is
  something an owner should switch on after watching the loop run, not inherit on day one.
- **`fastStoryMerges.enabled`** — write `true` **only** when at least one local review engine is on
  the roster *and* `verify.test` and `verify.typecheck` are both set. Under fast merges an item gets
  no pull request and no CI of its own, so those local suites are the only gate it receives.
  Otherwise write `false` and say which precondition was missing.

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

The sections are rendered in array order. A repository with its own pull-request template should
have these replaced by its headings — worth asking about if one exists at
`.github/pull_request_template.md`.

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

## Lessons store

```json
{ "lessonsDoc": ".claude/ds-lessons.md" }
```

The key is always written, whether or not the file is created — the review skill creates the file
when it has its first lesson to record.

If the user accepts an initialized store, write **exactly** this, and nothing more:

```markdown
# Lessons — distilled review findings

<!-- Written ONLY by devstride:review at settle time. Read-only everywhere else.
     Format + curation rules: the devstride:review skill's references/lessons-format.md -->

Next-ID: 1
```

**A zero-byte file is not an empty store.** `Next-ID` is the ID authority — it only ever increments,
so that IDs cannot be reused after an eviction — and a file with no header has no counter to read.
The review skill knows how to create the file from nothing; what it does not expect is a file that
exists and is malformed. So: write the template above, or leave the path absent. Never touch it
again after this — everything downstream of setup treats the store as review's to write.
