---
load: contract
---
# Ship intent — a session says what it is about to ship

**Goal:** every session, on every machine, and the owner can see what is being built, reviewed or
landed, where it is heading and roughly when it will be ready — before it lands. A declaration is
**information: never permission, never a lock.** Nothing refuses, delays or stops a build, a
landing or a release because one is missing, stale or held by someone else.

## When it applies

Only with a `claims` block and `release.coordination.enabled` not `false` (absent means on). Off →
declare nothing, say nothing. A session on an older plugin simply does not declare.

## The declaration

- **Kind `ship-intent`, key the unit**: the item number for a story or one-off, the release unit's
  number for its release; for a hotfix or a pull request with no item, its branch name.
- **Build it, never type it**: `python3 ${CLAUDE_PLUGIN_ROOT}/skills/build-item/scripts/ship-intent.py
  record` (stdin `{route, unit, branch, target, stage, class?, expiryMinutes?}`) prints the `kind`,
  `key`, `phase`, `expiryMinutes` and the seven-key `payload` (`route`, `unit`, `branch`, `target`,
  `class`, `stage`, `readyBy`) to send; it refuses any other key. `expiryMinutes` is the
  `ship-intent` entry of `claims.expiryMinutes` when it is a whole number from 1 to 1440, else
  left out (20). `class` is `light` or `full` only when
  the repository's own release classifier says so for this branch, else `unknown`. `readyBy` is an
  estimate from the stage and is always shown as one ("about").
- **Send it as a story claim is sent** (`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/story-claims.md`):
  the same provider, holder rule and `machine` / `sessionName` from `claim_record.py`, but the
  payload is `record`'s alone. Declare with the claim verb; move the stage with the heartbeat verb,
  sending the new `phase` and `payload`; finish with the release verb. A `commands` provider is
  handed the payload as `--payload '<json>'` on claim and heartbeat; one that refuses the option
  answers `ERROR`, which degrades.
- **Never decide by eye.** Pipe each answer to `ship-intent.py decide` (stdin `{mode: declare |
  update | release, unit, response, now, tz}`) and follow its `action`: `proceed`; `takeover`
  (declare again with its `takeoverDigest`); `declare` (declare again, plainly) — each at most
  ONCE per step, a second such answer being a carry-on; `carry-on` (say
  its `message`, declare nothing for this unit); `degrade` (say its `message` **once per session**
  and declare nothing more in it).

## Who declares what

| Where | Route | Target | Stages |
|---|---|---|---|
| `build-item` step 3 | `train` on the release train, `develop-pr` on the base branch, `epic-release` on an integration branch | the working base | `building` at step 3, `reviewing` at step 4, `verifying` at the local gate, `landing` at step 5; released at step 6, outcome `landed` |
| `build-item` step 8 | `epic-release`, unit the release unit | the release target | `reviewing` when the release pull request opens, `verifying`, `landing`; released when it merges |
| `branch-hotfix` | `hotfix` | the production branch | `building` once the branch is pushed |
| `pr`, run outside `build-item` | `hotfix` when the base is the production branch, else `develop-pr` | the pull request's base | `reviewing` when it opens, `verifying` at the pre-ship checks |

Only a declaration whose `target` is the release train, the base branch or the production branch
is heading for a release; a story on an integration branch never is.

**Keeping it listed.** Within a stage, renew the declaration beside each story heartbeat (the
heartbeat verb, no `phase` or `payload`), unless the repository's presence command renews it; run
`record` again only when the stage changes, since it restarts the estimate. A stop releases
nothing: the declaration lapses, or that presence command releases it when the session ends. No
step releases a hotfix's or a standalone pull request's declaration: it lapses, or presence ends it.

## Progress row

`Ship intent`: declared (stage), another session's, not configured, off, or degraded (reason).

## Cited by

- `skills/build-item/references/story-claims.md` (each claim, heartbeat and release)
- `skills/build-item/references/epic-release-steps.md` (the release pull request)
- `skills/branch-hotfix/SKILL.md`, `skills/pr/SKILL.md`
- `skills/setup/references/config-defaults.md` (`release.coordination.enabled`)
