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

## Conventions the skills must keep — body vs reference

- **Split rule.** A `SKILL.md` body carries every imperative, every config-key-honouring
  instruction, every step number another skill cites, and every scoped needle the invariants
  file pins to it. Rationale, worked examples, incident evidence and "observed live" anecdotes
  live in `skills/<owner>/references/<topic>.md`. Test for a paragraph: delete it and ask
  whether an agent would now do something different — if yes it is a rule and stays.
- **Pointer form.** Exactly one sentence, placed in the step it serves, path in the form the
  cache copy survives: **Read `${CLAUDE_PLUGIN_ROOT}/skills/<owner>/references/<topic>.md` when
  <step or condition>.** Two kinds are legal and both count as firing: a runtime pointer ("Read
  … when you declare a PRE-SHIP HOLD") and a maintenance pointer ("Read … before changing this
  rule") for pure rationale no runtime step needs. A reference with neither is dead text and
  fails the invariants file's dead-reference check.
- **Naming and placement.** kebab-case, one topic per file, named for what the reader is looking
  for (`progress-table.md`, `detector-evidence.md`), never `notes.md`/`misc.md`; flat under the
  owning skill's `references/`; addressed only by the `${CLAUDE_PLUGIN_ROOT}` path, never a
  relative `../`; a second skill that needs the same fact cites the owner's file rather than
  restating it. Every reference ends with a `## Cited by` list naming each pointer.
- **Body budget.** Every `skills/*/SKILL.md`, frontmatter included, has a committed row in
  `scripts/cost-budgets.json`, and `scripts/measure-cost.sh --check` — in the RELEASING.md
  step-0 checklist — fails the release on any body over its row. The rows are a ratchet with a
  destination: **8,000 tokens per body**. A row at or under 8,000 may never be raised past it;
  a row still above 8,000 (a body not yet compressed) only moves down.

### Moving prose out of a body

(a) derive candidates from the file, paragraph by paragraph, with the delete-test above; (b) for
each moved paragraph, leave the imperative it explained in the body, in its own sentence; (c)
re-read the moved paragraph in its new home for statements only true in the sequence it left,
and fix them there; (d) write the pointer at the step; (e) walk every config key the body cites
(``grep -o '`[A-Za-z]\+\(\.[A-Za-z]\+\)\+`' skills/<name>/SKILL.md | sort -u`` before and after —
the after-set must contain the before-set, or the removal is named in the PR; the dotted grep
misses TOP-LEVEL keys, so also check the body's backticked single words against the top-level
names in `skills/setup/references/config-defaults.md`); (f) run the
needle check under bash and the footprint measurement, and paste both outputs into the PR.

## Check that an edit did not grow a body past its budget

Every `skills/<name>/SKILL.md` has a token budget in `scripts/cost-budgets.json`, and
`bash scripts/measure-cost.sh --check` fails the moment a body exceeds it. **Run it whenever you
edit skill text.** The method is the `_method` field of `scripts/cost-budgets.json`, explained at
the top of `scripts/measure-cost.sh` — deliberately simple enough to cross-check with `wc -c`, with
a bias that is the same on both sides of every before/after table.

The budgets are a **ratchet**: lower one freely; raise one only in the same commit as the text
that needs it, and say so in the commit message — or, usually better, move the rationale into a
`references/` file with a "Read when …" pointer and keep only the rule in the body. A rule costs
what it costs; explanation is what the budget is for. `bash scripts/validate.sh` is the one
command that runs this together with every other pre-release check.

## Check that an edit did not drop a rule

`skills/review/references/delivery-loop-invariants.md` catalogues every hard-won fact these skills
encode — each one a rule that cost a real incident — and carries a runnable check for whether any of
them has gone missing.

**Run it whenever you edit skill text.** Compressing, re-wording, or moving a step is exactly when a
rule disappears along with the paragraph that carried it, and it disappears quietly: the prose still
reads well, so nothing looks wrong. That has happened to this text more than once, which is why the
file exists and why the four disciplines above are phrased as warnings rather than advice.

It is a maintenance instrument, not an operating rule — nothing at runtime reads it. Treat a missing
needle as a prompt to go and look, never as proof of loss: wording legitimately changes, and the
check cannot tell a rewrite from a deletion. The file is candid about the two further things it
cannot prove.

## Repo conventions

See [AGENTS.md](AGENTS.md) for public-repo hygiene, the release/versioning rule, and layout.
