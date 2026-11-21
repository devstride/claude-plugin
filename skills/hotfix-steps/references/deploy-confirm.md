---
load: contract
---
# Confirm production serves the merge

`hotfix-steps`' `deploy-confirm@1` step, shared by every workflow that merges to production.

- `release.deployVerification` set → run it with `RELEASE_COMMIT=<mergeSha>`; exit 0 →
  `CONFIRMED <sha>`; non-zero → retry every 60 seconds for up to 45 minutes, then `UNCONFIRMED`.
- Unset → `OWNER TO CONFIRM`: the person confirms, and on their confirmation in `answer` the re-run
  answers `CONFIRMED <sha>`. With `needed: false` in the payload → `NOT CONFIGURED`, saying the
  confirmation was skipped; `needed` defaults to true, so a hotfix always asks.

## Verdict

`DEPLOY: CONFIRMED <sha> | UNCONFIRMED | OWNER TO CONFIRM | NOT CONFIGURED`

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/hotfix-steps/SKILL.md`
