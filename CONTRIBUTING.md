# Contributing

Thanks for looking. Please read the sync-direction note first — it decides where a change should
land, and right now that is usually **not this repo**.

## Sync direction during the transition

The skills in `skills/` are **ported** from the repository where they are developed and used daily.
That repository is currently the single source of truth: this repo **receives skill text, it does
not originate it**.

Practically:

- **Pull requests that edit skill prose directly will be declined during the transition**, however
  good the change. Not because it is unwelcome — because a fix applied only here is silently
  overwritten by the next port, and the loop's own delivery skills keep running against the
  upstream copy, which would still have the bug.
- **Bug reports and design feedback are very welcome** — open an issue. Describe the behavior you
  hit and which skill produced it. Fixes land upstream and arrive here in the next port, with a
  version bump.
- Changes to things this repo genuinely owns — the plugin manifest, the marketplace entry, README,
  this file, packaging and validation — are normal PRs and are reviewed here.

This note will be replaced when the upstream repository switches to consuming the published plugin
instead of its local copy. At that point this repo becomes canonical and skill PRs open up.

## If you are porting

A port is mechanical and should stay that way:

- Skill directories use the bare verb name (`plan`, `build-item`, …). The plugin namespace supplies
  the `devstride:` prefix, so skills surface as `/devstride:plan`.
- Each `SKILL.md`'s frontmatter `name` must equal its directory name.
- Cross-skill invocations use bare names; slash-command examples use the namespaced
  `/devstride:<name>` form.
- Reference docs belong to the skill that owns them (`skills/<name>/references/`) and are addressed
  as `${CLAUDE_PLUGIN_ROOT}/skills/<name>/references/<file>.md`. **Relative `../` paths are
  forbidden** — they do not survive the plugin cache copy.
- Skills read the *consuming* repo's `.claude/ds-config.json` and fall back to inline defaults.
  Never ship a particular repo's config, and never hardcode one repo's branch names, deploy
  provider, or infrastructure as though it were universal.
- Nothing internal to the upstream project ships: no private tracker numbers, no internal branch
  names, no incident write-ups, no repo-local operational tooling.

**Port a CHANGE as a patch, not a file copy.** The first port also *generalized* the text —
replacing one project's branch names, deploy provider, CI job names and directory layout with the
config keys that govern them. Those generalizations exist only here; upstream still carries the
concrete values, because upstream is one specific repo. So copying a changed file wholesale
silently reverts every generalization in it and re-publishes internal specifics. Instead, take the
upstream diff for the change, rewrite skill names and paths in the *patch*, and apply it — hunks
that fail because they landed in generalized context get applied by hand. Then re-run the
sanitization grep before committing; a clobbered generalization looks exactly like a normal diff.

## Repo conventions

See [AGENTS.md](AGENTS.md) for public-repo hygiene, the release/versioning rule, and layout.
