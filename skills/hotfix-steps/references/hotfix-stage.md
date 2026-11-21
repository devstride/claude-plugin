---
load: contract
---
# Name the stage — before any environment command

`hotfix-steps`' `hotfix-stage@1` step.

**Name the stage first**, when the repo has a `stage` block: run `stage.resolve` and say "this
checkout deploys to `<stage>`" (`NAMED <stage>`). A result in `stage.productionStages` →
`PRODUCTION <stage>`: **STOP and ask before any environment command** — a `recreate` aimed at
production is the worst outcome here and no config value pre-authorizes it. The person says go ahead
→ `NAMED <stage>`; the person says not to touch it → `DECLINED <stage>`, which ends the run. No block
or an empty result → `NONE`, one warning line (a warning, never a new gate).

## Verdict

`HOTFIX STAGE: NAMED <stage> | NONE | PRODUCTION <stage> | DECLINED <stage>`

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/hotfix-steps/SKILL.md`
