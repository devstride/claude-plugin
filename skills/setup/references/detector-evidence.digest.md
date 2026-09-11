---
load: digest
---
# Why a detector returns `ambiguous` — the short answer

Why each detector declines to decide, and what would settle it. The named section of
`${CLAUDE_PLUGIN_ROOT}/skills/setup/references/detector-evidence.md` holds the full story.

**§A2 — ecosystem and package manager.** Two lockfiles usually mean a half-finished migration;
picking the loser writes commands that fail on every machine but one; a `packageManager` field
contradicting a lockfile is a disagreement, not a tie to break. *Settled by:* the owner naming the
manager the team runs, or the losing lockfile being deleted.

**§A4 — verify commands.** Several workspaces carry a test script, but the loop runs ONE test
command, and only the owner knows whether the root script fans out or one workspace is the real
suite; an unrun `&&` chain is an invention. *Settled by:* the owner naming the command they run
before pushing.

**§A5 — CI provider and the draft gate.** A workflow can be gated in part, or gated with a trigger
that cannot rerun it. For a mixed population neither answer is honest: `true` claims a hold part of
CI ignores, `false` discards the part that works. *Settled by:* every expensive job gated
(directly or through `needs`) and `types` naming `opened`, `synchronize`, `reopened`,
`ready_for_review`.

**§A7 — review engines.** A probe that missed proves nothing: the CLI may be a shell alias a
non-interactive shell never loads. On the cloud side the request mutation reports success even when
it registers nothing, and entitlement and org policy are invisible here. *Settled by:* the owner
confirming the command — and, for a cloud reviewer, a `review_requested` event on a real pull
request.

**§A9 — local environment.** A compose file proves a stack exists, not that `docker compose up` is
how this team starts it; nothing in a file distinguishes a command that rebuilds in place from one
that provisions a new instance, or says whether a second worktree gets its own data. *Settled by:*
the owner, which is why `recreateMode` and `instanceBoundTo` are never `detected`.

**§A10 — deployment stage.** Every candidate shape proves only that per-environment infrastructure
exists. None says how *this checkout* picks its stage — SST honours an environment variable over
its own marker file — nor which stage names mean production. *Settled by:* a cheap, quiet `resolve`
command the owner confirms, plus their `productionStages` list.

## Cited by

- `skills/setup/SKILL.md` — the Phase A pointer, on an `ambiguous` detector result.
