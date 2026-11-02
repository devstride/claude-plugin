---
load: contract
---
# Step skills — one seam each, runnable by name

A step skill runs exactly ONE seam (a hook a repository registers in `.claude/ds-config.json`) and
nothing else. The orchestrators (`release`, `build-item`, `pr`, `branch-hotfix`) call the step by
name instead of carrying its logic, and a person or agent can run the same step alone with
`/devstride:<name>` — for example to re-run one that failed. This file is the rule every step
skill follows; each step's own `SKILL.md` adds only what is particular to its seam.

## The rule

- **One seam, nothing else.** A step never chooses what runs next, never asks the owner a flow
  question the orchestrator owns (a rollback, a retry of the whole release), and never starts a
  subagent. Two steps of one run never run in parallel.
- **The verdict comes first.** The FIRST output line is the step's fixed verdict, exactly as its
  `## Verdict` section spells it (and as `schemas/seam-registry.json` records it as `stepVerdict`);
  every line after it is evidence that names the command that produced it.
- **Config wins.** Read `.claude/ds-config.json` first; a value there beats every default here or
  in the step. Arguments the caller passes (a payload, a member, a mode) beat both.
- **Safe to re-run.** A step does its work once per call and reports what it found; running it
  again after a failure is the supported recovery, never a second copy of earlier work.
- **Unset or null seam:** print the step's `NOT CONFIGURED` verdict (or the default verdict the
  step states), name the generic default that applies instead, and return. The caller continues.
- **A seam named but missing** (a skill name with no `.claude/skills/<name>/SKILL.md`, a command
  whose first word does not resolve): `NOT CONFIGURED` for an ordinary step, naming the setting and
  the fix (`/devstride:setup` scaffolds the documentation skills); for a safety step, the stricter
  path below.
- **Safety steps** (`pre-ship`, `post-deploy`, `classify-release`, `pre-merge-check`): a seam that
  is configured but missing, failing, or returning a first line that is none of its verdicts takes
  the STRICTER path, and is never read as a pass or as "nothing needed".
- **An orchestrator never inlines a step's logic.** It calls the step, reads the first line and
  decides what happens next; the step's evidence goes into its recap unchanged.

## The ten steps

| Step | Seam | Unset | Configured but broken |
|---|---|---|---|
| `update-docs` | `docs.updateSkill` | NOT CONFIGURED; no docs phase runs | FAILED, with the skill's output |
| `sync-knowledge-base` | `docs.knowledgeBaseSyncSkill` | NOT CONFIGURED | FAILED, with the re-run command; the docs push stands |
| `write-release-notes` | `docs.releaseNotesSkill` | NOT CONFIGURED; never improvised | FAILED |
| `pre-ship` | `preShipChecks` | NOTHING TO RUN | FAIL (stricter) |
| `post-deploy` | `release.postDeployCheckSkill` | NOT CONFIGURED | NOT RUN, the owner asked (stricter) |
| `local-environment` | `localEnvironment.*` | NOT CONFIGURED; the checkout is the only environment | FAILED |
| `lease-checkout` | `pool.checkout` | NOT CONFIGURED; no lease is taken | ERROR |
| `return-checkout` | `pool.checkin` | NOT CONFIGURED; nothing to hand back | ERROR |
| `classify-release` | `release.classifySkill` | FULL (stricter) | FULL (stricter) |
| `pre-merge-check` | `release.preMergeSkill` | NOT CONFIGURED, said at the go-ahead | NOT RUN, the owner asked (stricter) |

## Cited by

- `skills/update-docs/SKILL.md`, `skills/sync-knowledge-base/SKILL.md`,
  `skills/write-release-notes/SKILL.md`, `skills/pre-ship/SKILL.md`, `skills/post-deploy/SKILL.md`,
  `skills/local-environment/SKILL.md`, `skills/lease-checkout/SKILL.md`,
  `skills/return-checkout/SKILL.md`, `skills/classify-release/SKILL.md`,
  `skills/pre-merge-check/SKILL.md` — each opens with a pointer here.
- `skills/release/SKILL.md`, `skills/build-item/SKILL.md`, `skills/pr/SKILL.md`,
  `skills/branch-hotfix/SKILL.md` — the orchestrators that call the steps.
