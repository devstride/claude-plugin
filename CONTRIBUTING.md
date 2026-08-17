# Contributing

Thanks for looking. Skill improvements are welcome here — this repo is where they live.

## Where skill changes land

**This repo is canonical for the shared-loop skills.** Skill text is developed here and released
from here; consumers — including DevStride's own monorepo, which installs the plugin like any other
customer — receive it through a versioned release.

- **Pull requests that improve the skills are welcome.** So are issues describing behaviour you hit
  and which skill produced it.
- Read [RELEASING.md](RELEASING.md) before proposing a change that alters what a skill *does*: skill
  names and `.claude/ds-config.json` keys are a published contract, and breaking one costs a MAJOR
  version.
- Keep skills repo-agnostic. Everything repo-specific belongs in the consuming repo's
  `.claude/ds-config.json`, which always wins over the defaults shipped here. A change that only
  makes sense for one repository belongs in that repository, as a local skill — the split this
  plugin exists to demonstrate.

## Conventions the skills must keep

These held the port together and still hold the plugin together:

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
  provider, or infrastructure as though it were universal. This is the single easiest rule to
  break by accident, and it breaks quietly — a sentence that reads as a plain statement of fact
  ("CI is the sharded backend suite", "the list is empty today") is one repo's configuration
  asserted as universal truth.
- Nothing internal to the upstream project ships: no private tracker numbers, no internal branch
  names, no incident write-ups, no repo-local operational tooling.

**Historical note, kept because the failure mode recurs.** While skills were developed elsewhere
and ported in, a re-port that copied changed files wholesale silently reverted every
generalization in them and re-published one project's internals. The lesson generalizes past
porting: whenever skill text moves between repos in any direction, move the *diff*, not the file,
and re-run the sanitization grep before committing — a clobbered generalization is
indistinguishable from an ordinary diff.

## Editing skills without losing rules

These four disciplines were learned the expensive way — each names a failure that has actually
happened to this text, and each fails silently, which is why they are written down rather than
assumed.

**Cut the WHY before the WHAT.** Keeping a rationale while dropping the imperative it explained is
*the* signature compression failure: the paragraph still reads sensibly, so nothing looks wrong,
but the instruction is gone. When tightening a skill, never let a surviving justification stand in
for the rule it was justifying.

**A rationale that travels without its mechanism becomes false.** A sentence explaining *why* a step
matters is usually true only in the sequence it was written for. Move the step somewhere else and
the explanation can survive intact while quietly becoming wrong — technically fluent, factually
untrue, and invisible to any grep.

**Walk the config keys, one by one.** "The file wins over the defaults" is not self-executing.
After any change that touches configuration, check that **every** key the skills cite actually
exists in a real config, and that every key in a real config still has an instruction honouring it.
An absent JSON key does not error — the agent simply reads nothing and improvises.

**Presence is not fidelity, and fidelity is not correctness.** Grepping for a rule proves only that
the words are there. It cannot tell you the rule is still *true* after the change around it. And
when checking a refactor, derive what to look for from the **diff**, not from memory of what
mattered — memory reproduces what you already thought about.

## Repo conventions

See [AGENTS.md](AGENTS.md) for public-repo hygiene, the release/versioning rule, and layout.
