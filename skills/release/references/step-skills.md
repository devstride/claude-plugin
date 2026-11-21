---
load: contract
---
# Step skills — one seam each, runnable by name

A step skill runs exactly ONE seam (a hook `.claude/ds-config.json` registers). The orchestrators
(`release`, `build-item`, `pr`, and the hotfix's `hotfix-steps`) call it by name instead of carrying its logic,
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
- **Unset or null seam:** the `NOT CONFIGURED` verdict (or the step's stated default); the caller
  continues. The generic default that applies instead goes on the evidence line below it, never on
  the verdict line: a verdict whose contract takes no detail (`LOCAL CHECKS: NOT CONFIGURED`) is
  refused as no verdict when anything follows it.
- **Named but missing** (no `.claude/skills/<name>/SKILL.md`, or a command that does not
  resolve): `NOT CONFIGURED` with the setting and its fix — except a safety step.
- **Safety steps** (`pre-ship`, `post-deploy`, `classify-release`, `pre-merge-check`): configured
  but missing, failing or answering with no verdict → the STRICTER path, never a pass and never
  "nothing needed".
- **An orchestrator never inlines a step's logic.** It reads the first line, decides, and carries
  the evidence into its recap unchanged.

## Several steps in one skill

A step skill may carry several steps of ONE workflow, one per invocation, chosen by the payload's
reserved `contract` key (never the step id). Each step has its own verdict line under `## Verdict`
and its own reference file, read in full only when that step runs. "One seam, nothing else" is read
per invocation. A payload naming a contract the skill does not carry gets no verdict line, only a
sentence saying which steps it carries; the runner then stops with `no-verdict`. A step may run a
seam step this file documents by name, one verb per call (the hotfix environment step runs
`local-environment`); it still starts no subagent and decides no flow.

## The Build workflow's steps

The steps `${CLAUDE_PLUGIN_ROOT}/workflows/build.json` runs (`claim-story`, `story-lifecycle`,
`branch-feature`, `risk-check`, `local-checks`, `review-story`, `merge-story`, `capture-findings`,
`sync-base`) keep the rule above with three differences. Each answers its contract in
`${CLAUDE_PLUGIN_ROOT}/schemas/step-contracts.json`, not a seam's `stepVerdict`: the verdict line
written exactly as listed, the evidence, then one fenced `json` block holding the contract's result
keys, its `proof` and any `links` (the https addresses the step holds). Its arguments are that
contract's payload. And a step that IS a check or a review runs the verifiers or review engines it
consists of (`risk-check`'s focused verifiers; `review-story` through `review` or `pr`;
`merge-story` through `review` for a red check or an open thread); it starts no other subagent. The
build step, `ultracode-build`, is an engine with floors of its own, not a step skill.

## The ten steps

| Step | Seam | Unset | Configured but broken |
|---|---|---|---|
| `update-docs` | `docs.updateSkill` | NOT CONFIGURED | FAILED |
| `sync-knowledge-base` | `docs.knowledgeBaseSyncSkill` | NOT CONFIGURED | FAILED, a `sync` re-run line; docs push stands |
| `write-release-notes` | `docs.releaseNotesSkill` | NOT CONFIGURED, never improvised | FAILED |
| `pre-ship` | `preShipChecks` | NOTHING TO RUN | FAIL, naming every failed entry |
| `post-deploy` | `release.postDeployCheckSkill` | NOT CONFIGURED | NOT RUN, owner asked |
| `local-environment` | `localEnvironment.*` | NOT CONFIGURED | FAILED |
| `lease-checkout` | `pool.checkout` | NOT CONFIGURED: the repository's own lease protocol applies when its conventions declare a pool; otherwise there is no pool and no lease | ERROR |
| `return-checkout` | `pool.checkin` | NOT CONFIGURED | ERROR |
| `classify-release` | `release.classifySkill` | FULL | FULL |
| `pre-merge-check` | `release.preMergeSkill` | NOT CONFIGURED, said at the go-ahead | NOT RUN, owner asked |

## Cited by

- Each of the ten `skills/<step>/SKILL.md` files — its opening pointer.
- `skills/release/SKILL.md`, `skills/hotfix-steps/references/hotfix-environment.md` — the step-skill floor and the
  environment section; `build-item` and `pr` call the steps by name.
- `skills/claim-story/SKILL.md`, `skills/story-lifecycle/SKILL.md`, `skills/branch-feature/SKILL.md`,
  `skills/risk-check/SKILL.md`, `skills/local-checks/SKILL.md`, `skills/review-story/SKILL.md`,
  `skills/merge-story/SKILL.md`, `skills/capture-findings/SKILL.md`, `skills/sync-base/SKILL.md` —
  each one's opening pointer (the Build workflow's steps).
