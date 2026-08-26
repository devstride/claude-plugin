---
name: {{SKILL_NAME}}
description: "Write and publish a release note for a confirmed production release — invoked by the devstride plugin's release skill only when the owner passed --release-notes, or by hand. Modes: publish, draft, check."
---

Write a release note for a release that has ALREADY shipped and been confirmed live. The devstride
plugin hands this skill a delta payload with the merge commit filled in (the contract is
`${CLAUDE_PLUGIN_ROOT}/skills/release/references/docs-hooks.md`); WHERE notes live and HOW they
become visible is recorded here, in this repository.

Argument — a mode (`publish`, `draft` or `check`) and, for `publish`/`draft`, the payload as a
fenced JSON block: $ARGUMENTS

## Where release notes live

{{NOTES_LOCATION}}

## How a release note is published

{{NOTES_HOW}}

## Mode `check` — read-only health check

Confirm the location above exists and is usable and that publishing is possible (a checkout
present, clean and on the expected branch with a reachable remote; a directory present; a service
reachable). Print `PASS`/`FAIL` per fact with the fix, **write nothing**, and end with
`release-notes: PASS` or `release-notes: FAIL — <what to fix>`.

## Modes `publish` and `draft`

1. **Refuse an unconfirmed release.** The payload must carry `mergeCommit`, `mergedAt` and
   `live: true`; otherwise the release has not reached anyone and no note is written — say so and
   stop. A note that describes a release nobody can use is worse than no note.
2. **Prepare the location** as in the documentation skill: fetch and fast-forward a checkout; STOP
   on a dirty or missing one (a draft branch from step 5 is not dirt — the publishing branch stays
   clean by construction).
3. **Learn the existing notes' conventions from the newest one** — file naming, front matter, the
   date format, headings, tone — and match them exactly. A note that looks different from its
   neighbours reads as a mistake.
4. **Write the note for the people who use the product**: lead with what they can now do or what no
   longer goes wrong, one entry per `userFacing` item using its `summary`; group behaviour or
   migration `notes` under their own heading; leave out internal-only items and code identifiers.
   Link to the documentation pages the docs skill updated where that helps a reader.
5. **`draft`**: write it but do not publish — and do not leave the location dirty, or the next
   `publish` or documentation update will refuse to run over it. For a checkout, commit the note on
   a local `draft/release-note-<date>-pr<number>` branch (keyed by the release pull request, not
   the date alone — two same-day releases must not collide) and return to the publishing branch,
   unpushed; for a service, save unpublished. Say where the owner can read it.
   **`publish`**: if a draft for this release already exists (that branch, that unpublished item),
   it IS the note — promote it (fast-forward merge, then delete the branch; or mark it published)
   rather than writing a second one; otherwise write and publish fresh.
6. **Report** the note's location or URL and whether it is live or awaiting the owner.

IMPORTANT: this skill runs only when the owner asked for a note. It never decides on its own that a
release deserves one, and it writes only to the release-notes location declared above — which may
be inside this repository (a `CHANGELOG.md`, a `release-notes/` directory) — through the workflow
declared above. Never application code.
