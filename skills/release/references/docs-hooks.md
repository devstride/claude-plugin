---
load: contract
---
# Documentation hooks — the contract between the plugin and a repository's local docs skills

The plugin does not know how any repository documents itself. Documentation systems differ in every
way that matters — a sibling repository, a `docs/` directory, a wiki, a hosted service; pushed
straight to a branch that publishes, or merged through a pull request; a `release-notes/` directory,
a `CHANGELOG.md`, a mailing, or nothing at all. So the plugin holds exactly two facts about
documentation, both naming LOCAL skills in the consuming repository, and everything else lives in
those skills. This file is the authority for that contract; every skill that touches documentation
cites it rather than restating it.

## Config keys

```json
{
  "docs": {
    "updateSkill": null,
    "releaseNotesSkill": null,
    "updateOnEpicRelease": false,
    "knowledgeBaseSyncSkill": null
  },
  "release": {
    "deployApproval": null,
    "deployVerification": null
  }
}
```

| Key | Meaning |
|---|---|
| `docs.updateSkill` | Name of the local skill (a directory under `.claude/skills/`) that brings the repository's core documentation in line with a shipped delta. `null` or absent: no documentation system is registered; every docs phase of the loop is skipped and says so. |
| `docs.releaseNotesSkill` | Name of the local skill that writes and publishes a release note. `null` or absent: release notes cannot be requested; `--release-notes` on `release` reports itself unavailable rather than improvising. |
| `docs.updateOnEpicRelease` | `false` by default. `true` makes `build-item` step 8 invoke `docs.updateSkill` after a release-unit (epic) release pull request merges, so documentation moves with each release unit rather than only at the production cut. |
| `release.deployApproval` | Optional command approving a waiting deploy after the merge, on the owner's yes (`RELEASE_COMMIT`): 0 = approved and read back, 2 = not waiting yet, else STOP. |
| `release.devDeployVerification` | Optional shell command, given `RELEASE_COMMIT` (the head the release pull request merges from the source: the cut `<sourceHead>` with a release branch, else `<reviewedHead>`): exit 0 the development environment serves it, 2 not deployed yet, 1 the development deploy failed. `release` runs it at step 4, after the owner's yes and before the production merge, only when the release delta touches a `release.releaseBranchFixExclusions` path. Poll every 60 s on exit 2 for at most 45 minutes, then STOP; on exit 1 STOP and never merge production over a failed development deploy. The run recap names the wait. Unset: no wait. |
| `release.deployVerification` | Optional shell command that exits 0 only when production is actually serving the merge commit, given as the `RELEASE_COMMIT` environment variable. `release` runs it to prove the deploy is live before release notes are written. `null`: the owner confirms the deploy by hand instead. |

`release.docsRepo` is the pre-1.0 shape — a sibling docs checkout the plugin operated on directly.
It is **deprecated**, and its presence is reported **whenever it exists**, whether or not a `docs`
block exists beside it: `setup` migrates it into a scaffolded local skill and removes it, `doctor`
and setup validation flag it, and `release` never acts on it — it says the shape is deprecated,
names the migration, and continues with whatever the `docs` block registers (nothing, if there is
none).

## Who decides what — the rule

- **Core documentation is updated by default whenever `docs.updateSkill` is set** — after the
  production merge is confirmed and the deploy verified, never before. The owner suppresses it per
  run with `no docs`.
- **Release notes are written only when the owner asks** — `--release-notes true|draft` on
  `release`, per invocation — and only after the production deploy is confirmed live. If a release
  seems to deserve one, say so in step 4's recap.
- **No skill in this plugin decides on its own that a delta "warrants" a note, is "large", or is
  "user-facing enough".** Those are the owner's words to say, never adjectives for the loop to
  interpret: a loop that judges a release note-worthy will eventually publish one the owner did
  not want, in public, where it cannot be quietly withdrawn.

## The delta payload

The plugin computes what shipped and hands it over as structured data, so a local skill never
re-derives the delta and cannot disagree with the release about it. Pass it as a fenced JSON block
in the invocation:

```json
{
  "kind": "production-release",
  "repo": "<owner>/<repo>",
  "source": "<release source branch>",
  "target": "<production branch — or the base branch for an epic release>",
  "pullRequest": { "number": 0, "url": "..." },
  "mergeCommit": null,
  "mergedAt": null,
  "live": false,
  "items": [
    {
      "number": "I0000",
      "title": "...",
      "summary": "<one plain-English sentence: what changed for someone using the product>",
      "userFacing": true
    }
  ],
  "constituentPullRequests": [{ "number": 0, "title": "...", "url": "..." }],
  "notes": ["<a migration, permission, or behaviour change worth a sentence in the docs>"]
}
```

- `kind` is `production-release` (from `release`) or `epic-release` (from `build-item` step 8).
- `items[].summary` is written by the caller from the merged pull requests and item titles — plain
  English, no code identifiers — because it is the sentence a docs page or a release note will
  reuse. `userFacing` is the caller's judgement of whether someone reading the documentation can
  observe the change; the local skill uses it to decide which items touch documentation at all.
- **`live` is the publish gate, and only the production release sets it `true`** — after the
  merge is confirmed and the deploy verified. A skill publishes only when `live` is `true`; for
  anything else it STAGES the change (a local branch, an unpublished draft) and reports where it
  is. An epic release (`kind: "epic-release"`) always carries `live: false`: its code has reached
  the base branch, not production, so its documentation is staged for the production release that
  will carry it. A hand-run preview leaves `live` false too. Documentation is public, and the
  plugin never publishes text about functionality that has not reached the people who read it.
- `mergeCommit` and `mergedAt` are filled whenever the payload describes a merge that exists
  (production or epic); `null` only for a preview of an unmerged delta.

## What a local skill must accept

A registered docs skill is invoked by name with a `mode` and, for every mode except `check`, the
payload above. Only the production release invokes a skill with the deploy confirmed (`live:
true`); an epic release invokes `update` right after its merge to the base branch with `live:
false`, and a hand run may carry `mergeCommit: null` — the skill reads `live`, never the caller,
to decide whether it may publish.

| Mode | Skill | What it does |
|---|---|---|
| `update` | `docs.updateSkill` | Bring core documentation in line with the payload: correct what is now stale, document what is new, prune what is gone. With `live: true`, commit, push or open a pull request per the repository's own rules; with `live: false`, stage the edits (a local branch, an unpublished draft) and publish nothing. Report the pages changed and where they went — branch, pull request, or live URL. |
| `publish` | `docs.releaseNotesSkill` | Write a release note for the payload in the repository's own location and voice, and publish it the way the repository publishes notes. Requires `live: true` — refuse, and say so, otherwise. If a draft for the same release already exists, promote it rather than writing a second note. Report the note's location or URL. |
| `draft` | `docs.releaseNotesSkill` | Write the note but leave it unpublished — on a local branch keyed by the release (never leaving the publishing location dirty, which would block the next `update` or `publish`), or as an unpublished item in a service — and report where the owner can read it. |
| `check` | both | Read-only health check, run by `setup` (validation) and `doctor`: the documentation location exists and is reachable (a checkout present, clean and on the expected branch; a directory present; a service reachable), and whatever publishing needs is available. Print `PASS` or `FAIL` with the fix. Never writes anything. |

Anything else — where documentation lives, how it is edited, link conventions, how the site routes
pages, what "publish" means here — is the skill's own business, written into it by `setup` from the
owner's answers, or by hand.

## The knowledge-base sync (`docs.knowledgeBaseSyncSkill`)

Optional, `null` by default: the name of a local skill that brings a knowledge base (a help centre,
a search index, an assistant's source set) in line with documentation that was just published.
Its step is `sync-knowledge-base`, which `release` calls right after 5c.

- **It runs only after documentation was published live.** Mode `sync` with `{ "docsOutcome":
  "published", "live": true }`. Any other outcome, or `live` false, is `NOT RUN` without invoking
  it: a knowledge base never runs ahead of the documentation it mirrors.
- **Mode `check`**, with no payload (also what a bare `/devstride:sync-knowledge-base` runs): the
  skill checks its own preconditions, read-only. A re-run of the sync names the mode:
  `/devstride:sync-knowledge-base sync {"docsOutcome": "published", "live": true}`.
- **First line**: `KNOWLEDGE BASE SYNC: DONE`, `CURRENT` (nothing to change) or `FAILED`, then
  evidence. A `FAILED` never undoes or reverts the documentation push; the step adds the line
  `re-run: /devstride:sync-knowledge-base sync {"docsOutcome": "published", "live": true}`, then
  (with a clearance provider that records owed work) the settlement to run once that re-run
  prints `DONE` or `CURRENT`: `then, on DONE or CURRENT: <the provider's owed command> --done
  knowledge-base`. `release` keeps `knowledge-base` owed until then.
- **`no docs`** on a release also skips the sync, and the recap names the catch-up commands.

## What `release` does with each docs verdict

**Step 3 — the documentation plan, before anything is owed.** For each hook this release would
run (`docs.updateSkill`; `docs.knowledgeBaseSyncSkill`; `docs.releaseNotesSkill` when
`--release-notes` asked), check that `.claude/skills/<name>/SKILL.md` exists:

- **Resolves** → it joins the plan in the step-4 recap and is owed at 5b (`docs`,
  `knowledge-base`, `release-notes`), unless `no docs` suppresses the first two. **The
  knowledge-base sync joins only beside a `docs.updateSkill` that resolves**: with no valid docs
  hook the docs can never publish, so a configured sync would sit owed forever — it is left out
  and the plan says why.
- **Set but dangling** → report it now with its fix (`/devstride:setup docs`) and leave it out of
  the plan. It is never owed, so it can never sit in "close-out owed" for good.
- **Unset** → `docs.updateSkill`: "none registered"; `docs.knowledgeBaseSyncSkill`: say
  nothing — the release prints no line for a knowledge base it does not have.
- **`release.docsRepo` present** → report the deprecation and its migration whatever else is
  set; a valid `docs.updateSkill` still runs.

**Steps 5c–5e — owed accounting and the close-out's `docs` value.** Each owed item is settled with
`owed --done <item>` only on a successful or genuinely current result:

| `update-docs` | `docs` owed | `knowledge-base` owed | close-out `docs` |
|---|---|---|---|
| `PUBLISHED` | settled | run `sync-knowledge-base sync`: `DONE`/`CURRENT` settles; `FAILED` stays owed with its re-run line | `published` |
| `CURRENT` | settled | settled: nothing new to mirror | `nothing to change` |
| `STAGED` | settled; the recap names the owner action (a draft to look at, a pull request to merge) | stays owed; catch-up once the docs are live | `skipped` |
| `FAILED` | stays owed | stays owed | `failed` |
| `NOT CONFIGURED` | never owed (step 3 left it out) | never owed | `skipped` |
| `no docs` | never owed | never owed | `skipped` |

`write-release-notes`: `PUBLISHED` or `DRAFTED` settles `release-notes`; `FAILED` keeps it owed.

**The catch-up after `no docs`** is printed whole, because a bare `/devstride:update-docs update`
refuses without a payload: `/devstride:update-docs update` followed by this release's completed
payload as a fenced JSON block (`live: true`), then, when `docs.knowledgeBaseSyncSkill` is set,
`/devstride:sync-knowledge-base sync {"docsOutcome": "published", "live": true}` once the docs are
live. Any catch-up for an item still owed ends with its settlement, `<the provider's owed command>
--done <item>`, to run once the catch-up succeeds
(`${CLAUDE_PLUGIN_ROOT}/skills/release/references/clearance.md`).

## Templates

`setup` scaffolds both skills from
`${CLAUDE_PLUGIN_ROOT}/skills/setup/references/docs-skill-templates/`. A scaffolded skill is a
starting point the repository owns from that moment on: `setup` never overwrites one that exists.
