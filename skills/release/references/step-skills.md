---
load: contract
---
# Step skills — one seam each, runnable by name

A step skill runs exactly ONE seam (a hook `.claude/ds-config.json` registers). The orchestrators
(`release`, `build-item`, `pr`, `branch-hotfix`) call it by name instead of carrying its logic,
and anyone can run it alone as `/devstride:<name>` — for example to re-run one that failed.

## The rule

- **One seam, nothing else.** A step never decides what runs next, never asks a flow question the
  orchestrator owns (a rollback, whether to continue), never starts a subagent; two steps of one
  run never run in parallel.
- **Verdict first.** The FIRST output line is the fixed verdict its `## Verdict` section spells
  (recorded as `stepVerdict` in `schemas/seam-registry.json`); each later line is evidence naming
  the command that produced it.
- **Config wins** over every default; arguments the caller passes (payload, member, mode) win over
  both. **Safe to re-run**: re-running after a failure is the supported recovery.
- **Unset or null seam:** the `NOT CONFIGURED` verdict (or the step's stated default), naming the
  generic default that applies instead; the caller continues.
- **Named but missing** (no `.claude/skills/<name>/SKILL.md`, or a command that does not
  resolve): `NOT CONFIGURED` with the setting and its fix — except a safety step.
- **Safety steps** (`pre-ship`, `post-deploy`, `classify-release`, `pre-merge-check`): configured
  but missing, failing or answering with no verdict → the STRICTER path, never a pass and never
  "nothing needed".
- **An orchestrator never inlines a step's logic.** It reads the first line, decides, and carries
  the evidence into its recap unchanged.

## The ten steps

| Step | Seam | Unset | Configured but broken |
|---|---|---|---|
| `update-docs` | `docs.updateSkill` | NOT CONFIGURED | FAILED |
| `sync-knowledge-base` | `docs.knowledgeBaseSyncSkill` | NOT CONFIGURED | FAILED, re-run line; docs push stands |
| `write-release-notes` | `docs.releaseNotesSkill` | NOT CONFIGURED, never improvised | FAILED |
| `pre-ship` | `preShipChecks` | NOTHING TO RUN | FAIL |
| `post-deploy` | `release.postDeployCheckSkill` | NOT CONFIGURED | NOT RUN, owner asked |
| `local-environment` | `localEnvironment.*` | NOT CONFIGURED | FAILED |
| `lease-checkout` | `pool.checkout` | NOT CONFIGURED, no lease | ERROR |
| `return-checkout` | `pool.checkin` | NOT CONFIGURED | ERROR |
| `classify-release` | `release.classifySkill` | FULL | FULL |
| `pre-merge-check` | `release.preMergeSkill` | NOT CONFIGURED, said at the go-ahead | NOT RUN, owner asked |

## Cited by

- Each of the ten `skills/<step>/SKILL.md` files — its opening pointer.
- `skills/release/SKILL.md`, `skills/branch-hotfix/SKILL.md` — the step-skill floor and the
  environment section; `build-item` and `pr` call the steps by name.
