---
name: hotfix-steps
description: "Step: one step of the Hotfix workflow, chosen by the payload's contract."
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/step-skills.md` first: the rule every step skill follows.

Arguments: $ARGUMENTS — one JSON object, the step's payload
(`${CLAUDE_PLUGIN_ROOT}/schemas/step-contracts.json`); its reserved `contract` key names the step
(the Hotfix's, and two shared deploy steps).

## Verdict

- `HOTFIX PREFLIGHT: READY <branch> | DIRTY | NEEDS INPUT <what> | FAILED <why>`
- `HOTFIX BRANCH: CUT <branch> | FAILED <step>`
- `HOTFIX STAGE: NAMED <stage> | NONE | PRODUCTION <stage> | DECLINED <stage>`
- `HOTFIX ENVIRONMENT: RECREATED | MIGRATED | UNCHANGED | NEEDS ANSWER <why> | FAILED <why>`
- `HOTFIX CUT: DONE <branch>`
- `HOTFIX FIX: COMMITTED <sha> | NEEDS DIRECTION <what> | ABANDONED`
- `HOTFIX MERGE: MERGED <sha> | WAITING FOR YES | REFUSED <reason> | ERROR <reason>`
- `DEPLOY APPROVAL: APPROVED | WAITING FOR YES | RETRY | NOT CONFIGURED | STOPPED <why>`
- `DEPLOY: CONFIRMED <sha> | UNCONFIRMED | OWNER TO CONFIRM | NOT CONFIGURED`
- `HOTFIX CLOSED: CLOSED <sha> | OPEN RELEASE <branch>`

## Steps

1. Dispatch on the payload's `contract`:
   - `hotfix-preflight@1` → **read `${CLAUDE_PLUGIN_ROOT}/skills/hotfix-steps/references/hotfix-preflight.md` in full**.
   - `hotfix-branch@1` → **read `${CLAUDE_PLUGIN_ROOT}/skills/hotfix-steps/references/hotfix-branch.md` in full**.
   - `hotfix-stage@1` → **read `${CLAUDE_PLUGIN_ROOT}/skills/hotfix-steps/references/hotfix-stage.md` in full**.
   - `hotfix-environment@1` → **read `${CLAUDE_PLUGIN_ROOT}/skills/hotfix-steps/references/hotfix-environment.md` in full**.
   - `hotfix-report@1` → **read `${CLAUDE_PLUGIN_ROOT}/skills/hotfix-steps/references/hotfix-report.md` in full**.
   - `hotfix-fix@1` → **read `${CLAUDE_PLUGIN_ROOT}/skills/hotfix-steps/references/hotfix-fix.md` in full**.
   - `hotfix-merge@1` → **read `${CLAUDE_PLUGIN_ROOT}/skills/hotfix-steps/references/hotfix-merge.md` in full**.
   - `deploy-approval@1` → **read `${CLAUDE_PLUGIN_ROOT}/skills/hotfix-steps/references/deploy-approval.md` in full**.
   - `deploy-confirm@1` → **read `${CLAUDE_PLUGIN_ROOT}/skills/hotfix-steps/references/deploy-confirm.md` in full**.
   - `hotfix-close@1` → **read `${CLAUDE_PLUGIN_ROOT}/skills/hotfix-steps/references/hotfix-close.md` in full**.
   - Any other contract, or none → no verdict line: say so, and stop.

**Floors.** Never wait on another release; never set `DEVSTRIDE_MERGE_GUARD=0`; a
yes is read from the payload's `answer` (a release: `deploy-approval.md`)
and never carried over to a newer merge.

## Result

After the verdict and its evidence, one fenced `json` block. hotfix-preflight: `branch`, `base`, `prefix`, `date`, `dateFormat`, `configSource`. hotfix-branch: `branch`, `base`, `baseSha`, `pushed`, `shipIntent`. hotfix-stage: `stage`, `production`. hotfix-environment: `case`, `mode`, `why`, `restartDevServer`. hotfix-report: `branch`, `case`. hotfix-fix: `commit`, `deferrals`, `deviations`, `untrackedDeferrals`, `dismissed`, `scopeLine`, `head`. hotfix-merge: `sha`, `pullRequest`. deploy-approval: `mergeSha`, `approved`. deploy-confirm: `mergeCommit`, `confirmedAt`. hotfix-close: `mergeSha`, `openRelease`.

**Step rules.** Each call: verdict first; safe to re-run; config wins; it never starts a subagent and never decides what runs next.
