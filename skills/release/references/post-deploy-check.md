---
load: contract
---
# Post-deploy health check — the contract between `release` and a repository's local check skill

The plugin does not know what "healthy" means for any production system — alarms, dead-letter
queues, error rates, a synthetic transaction, a dashboard — so, exactly as with documentation
(`${CLAUDE_PLUGIN_ROOT}/skills/release/references/docs-hooks.md`), it holds ONE fact: the name of
a LOCAL skill that knows. Everything about what is checked, with which credentials, and against
which thresholds lives in that skill. This file is the authority for the contract; `release`,
`doctor` and the config defaults cite it rather than restating it.

## Config key

```json
{
  "release": {
    "postDeployCheckSkill": null
  }
}
```

| Key | Meaning |
|---|---|
| `release.postDeployCheckSkill` | Name of the local skill (a directory under `.claude/skills/`) that checks production health after a deploy. `null` or absent: no check is registered; the release close-out reports **post-deploy health: not configured**. `setup` does not write it — a repository adds it by hand once such a skill exists. |

## When it runs

`release` invokes it with `check` once, **after the production deploy is confirmed** (step 5a —
the merge commit is known and `release.deployVerification` or the owner has confirmed the deploy)
and **before** the hand-back (5b), the documentation update (5c) and the release notes (5e). A
health check before the deploy is confirmed measures the previous release; one after the docs are
published cannot stop them. The release still holds its clearance while `check` runs, so `check`
does only what the next release depends on (health, and anything it must publish first).

## Invocation

The Skill tool, by the configured name, with arguments = the word `check` followed by a fenced
JSON payload:

```json
{
  "productionBranch": "<name>",
  "mergeCommit": "<sha>",
  "deployConfirmedAt": "<ISO-8601>"
}
```

## What the skill returns

Its FIRST line is exactly one of:

```text
POST-DEPLOY HEALTH: PASS
POST-DEPLOY HEALTH: FAIL
POST-DEPLOY HEALTH: NOT RUN
```

followed by evidence lines, each naming the command that produced it — an alarm state, a queue
depth, a probe result. The skill never narrates a verdict it did not measure: `NOT RUN` is for a
check that could not be performed (missing credentials, an unreachable endpoint), never a
substitute for `FAIL`.

## Work that waits until after the hand-back (optional `close-out` mode)

Work nothing else waits on — messages owed to customers once the release is live, removing local
resources the release prepared — does NOT run inside `check`: it would hold the clearance for it.
Instead, after its evidence, `check` prints one line `CLOSE-OUT OWED: <short list>`. `release`
records it as owed at the hand-back (5b) and, once documentation (5c) has finished, invokes the
skill again with the word `close-out`, the same payload, and `"docs": "published" | "nothing to
change" | "skipped" | "failed"` added. It does that work once and returns `POST-DEPLOY CLOSE-OUT:
DONE` or `POST-DEPLOY CLOSE-OUT: PARTIAL` with the evidence and what is left; PARTIAL keeps the
item owed and is reported to the owner. A skill that prints no such line is never invoked with
`close-out`.

## What `release` does with it

| First line | `release` |
|---|---|
| `PASS` | Continue to 5b. Carry the evidence, and any `CLOSE-OUT OWED` line, into the close-out. |
| `FAIL` | **STOP.** Surface the evidence and ask the owner for a rollback decision. Never continue to documentation, release notes or the close-out on your own — public text about a release that is being rolled back is the failure this gate exists to prevent. |
| `NOT RUN` | Report it as this-run degradation ("post-deploy health: not run — <reason>") and ask the owner whether to proceed. Not a pass, not a failure. |
| Key absent | No invocation. The close-out says **post-deploy health: not configured**. |

The four states are reported with the words above, never collapsed: **not run** and **not
configured** are different facts, and a `PASS` a human did not see the evidence for is a claim.

## Cited by

- `skills/release/SKILL.md` — steps 5a and 5d.
- `skills/doctor/SKILL.md` — section 7 (documentation hooks and the post-deploy check).
- `skills/setup/references/config-defaults.md` — the key's default.
