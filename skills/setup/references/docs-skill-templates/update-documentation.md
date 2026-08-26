---
name: {{SKILL_NAME}}
description: "Bring this repository's documentation in line with a merged delta — invoked by the devstride plugin's release skill (after the production deploy is confirmed, live: true) and build-item (after an epic merge, live: false, staged only), or by hand. Modes: update, check."
---

Update the documentation for a merged delta. The devstride plugin hands this skill a delta
payload (the contract is `${CLAUDE_PLUGIN_ROOT}/skills/release/references/docs-hooks.md` —
read it once). **`live` is the publish gate**: the plugin sets it `true` only for a production
release whose merge is confirmed and deploy verified — publish then. Any payload with `live: false`
(an epic release that reached the base branch, a hand-run preview) is STAGED — a local branch, an
unsaved draft — never published, and the report says where the staged change waits;
everything about WHERE documentation lives and HOW it is published is recorded here, in this
repository, because it is this repository's business and nobody else's.

Argument — a mode (`update` or `check`) and, for `update`, the payload as a fenced JSON block:
$ARGUMENTS

## Where documentation lives

{{DOCS_LOCATION}}

## How documentation is published

{{DOCS_HOW}}

## Mode `check` — read-only health check

Confirm the location above exists and is usable, and print one line per fact with `PASS` or
`FAIL` and the fix. For a checkout: it is present, clean (`git status --porcelain` empty), on the
expected branch, and its remote is reachable (`git ls-remote`). For a directory: it is present. For
a service: it answers. **Write nothing** — `setup` and `doctor` run this mode and rely on it being
safe. End with a single verdict line: `docs: PASS` or `docs: FAIL — <what to fix>`.

## Mode `update`

1. **Prepare the location.** A checkout: fetch and fast-forward the branch named above; if it is
   dirty or missing, STOP and say so rather than editing over someone's work.
2. **Learn the structure from the documentation itself** — do not assume it. Read the navigation
   or config and the directory layout to find the section each change belongs under. Before
   writing any internal link, check how the site builds its routes: derive the link form from an
   existing page's real URL rather than composing one, because a shortened form that happens to
   work for an old page (via a redirect) will 404 for a new one.
3. **Work through `items` where `userFacing` is true.** For each, find the affected page or pages
   and update what is now stale or missing — new behaviour documented, changed behaviour corrected,
   removed things pruned. Keep edits tight; match the surrounding voice. Do not invent pages for
   internal-only changes, and do not write a release note here — that is the release-notes skill's
   job, and only when the owner asked for one.
4. **Publish exactly as described above — only when `live` is `true`** — a direct push, a pull
   request, a hand-off. A conventional commit message (`docs: <what> — <why>`) if a commit is
   involved. With `live: false`, stage instead (for a checkout: commit on a local
   `docs/pending-<pr-number>` branch and return to the publishing branch, unpushed) and report
   where it waits; a later `live: true` payload for the same delta promotes that staged change
   (rebase, fast-forward, publish) rather than redoing the work.
5. **Report** the pages changed and where they went (branch, pull request URL, live URL), and
   anything left for the owner (a pull request to merge, a page that needs a screenshot).

IMPORTANT: this skill edits documentation only — the locations declared above, which may be
inside this repository (a `docs/` directory, a `CHANGELOG.md`) or outside it — through the
publishing workflow declared above and no other. It never edits application code, never writes
release notes, and never publishes anything the section above does not describe.
