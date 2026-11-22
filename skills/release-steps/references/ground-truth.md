---
load: contract
---
# Read ground truth — what really is on both branches

`release-steps`' `ground-truth@1` step. It reads only. The procedure is
`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/ground-truth-at-start.md` "The procedure",
cited, not copied.

1. **Config wins.** Load `.claude/ds-config.json`: `release.releaseSource` (shipped default
   `develop`), `release.productionBranch` (`master`), `needsYou.label`.
2. `git fetch origin <productionBranch> <releaseSource>`. A fetch that fails → `FAILED`, naming the
   command: nothing later may trust a stale ref.
3. Read what OTHER authors landed on both branches since this session last looked, and verify
   every remembered fact (an open pull request, a branch, a merge) against `origin` and `gh`
   before repeating it.
4. **`needsYou.label` set** → read
   `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/needs-you.md` now and read the stale
   notices it describes; say what is waiting.
5. Another session looks active on this release (fresh commits by another author on a release or
   train branch, an open release or train pull request this session did not open, a held tower)
   → `ANOTHER SESSION ACTIVE`, saying what was seen. The run carries on: the claims decide who
   proceeds, this step only says it out loud. Otherwise `READ`.

## Verdict

`GROUND TRUTH: READ | ANOTHER SESSION ACTIVE <what> | FAILED <reason>`

## Result

`state`: `read`, `another-session-active` or `failed`.

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/SKILL.md`
