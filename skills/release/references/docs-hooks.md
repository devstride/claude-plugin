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
    "updateOnEpicRelease": false
  },
  "release": {
    "deployVerification": null
  }
}
```

| Key | Meaning |
|---|---|
| `docs.updateSkill` | Name of the local skill (a directory under `.claude/skills/`) that brings the repository's core documentation in line with a shipped delta. `null` or absent: no documentation system is registered; every docs phase of the loop is skipped and says so. |
| `docs.releaseNotesSkill` | Name of the local skill that writes and publishes a release note. `null` or absent: release notes cannot be requested; `--release-notes` on `release` reports itself unavailable rather than improvising. |
| `docs.updateOnEpicRelease` | `false` by default. `true` makes `build-item` step 8 invoke `docs.updateSkill` after a release-unit (epic) release pull request merges, so documentation moves with each release unit rather than only at the production cut. |
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
  `release`, per invocation — and only after the production deploy is confirmed live.
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

## Templates

`setup` scaffolds both skills from
`${CLAUDE_PLUGIN_ROOT}/skills/setup/references/docs-skill-templates/`. A scaffolded skill is a
starting point the repository owns from that moment on: `setup` never overwrites one that exists.
