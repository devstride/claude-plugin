---
load: contract
---
# The local environment — a BACKWARD transition

`hotfix-steps`' `hotfix-environment@1` step, run after the stage is named.

The production branch is OLDER than what the instance has been running. `migrate` and `seed` only go
forward, so running them leaves the instance schema-AHEAD of the code — the hotfix then validates
against a schema production does not have. **An ABSENT `localEnvironment` member is the shipped
`null`** (every config written before `recreate` existed omits it) — read every missing member as
`null` throughout. Each command runs through the **`local-environment`** step, one verb per call
(`${CLAUDE_PLUGIN_ROOT}/skills/release/references/step-skills.md`); which verbs run, and when to stop, is decided
here. Three cases:

1. **`recreate` set** → `local-environment recreate`, with every placeholder substituted — **never
   pass one through to a shell** (`<base>` unexpanded is input redirection). `<base>` = the fetched
   `hotfixBaseBranch` ref (a stale tracking ref rebuilds old production); `<branch>` = the new
   hotfix branch; **`<name>` per `localEnvironment.recreateMode`, the ONLY thing that says what the
   command does — never inferred from the command text** (a wrapper is opaque, and both wrong
   guesses do damage):
   - `"newInstance"` → a NEW name; then move the session into the instance it creates;
   - `"inPlace"` → the instance the session is ALREADY in, named by `local-environment name`
     (`localEnvironment.instanceName`); null or failing → **STOP and ask** (`NEEDS ANSWER`; a
     directory-name guess silently resets someone else's instance);
   - mode absent/`null` while `recreate` contains `<name>` → **STOP and ask** (`NEEDS ANSWER`),
     explaining both values; never pick. (No `<name>` → no mode needed.)

   The session must end in a WORKING instance — never in a directory whose instance was torn down,
   or on a detached HEAD the rebuilt instance no longer belongs to. Done → `RECREATED`.
2. **`recreate` absent/`null` and you can say WHY the schema has not diverged** (the instance stayed
   on the production line, or there is no schema) → `local-environment migrate`, then `seed`, in
   that order (a seed against a stale schema fails or lies) → `MIGRATED`.
3. **`recreate` absent/`null` and the schema HAS diverged or you cannot tell** → **STOP and ask**
   (`NEEDS ANSWER`). Never migrate forward and carry on. Name the missing
   `localEnvironment.recreate`, offer the manual route (a fresh instance from the hotfix base), and
   continue only once the user confirms a rebuild or says to proceed anyway.

**Say which case you took and why** — "the environment was reset" reads the same for all three and
only two are sound. Then restart the dev server you asked the user to stop (`restartDevServer`).
Block absent, or every command `null` → the procedure is repo-specific: say so and ask (`NEEDS
ANSWER`); never invent a reset command. `UNCHANGED` only when the person said to go on without a
rebuild (case 3's proceed anyway, or no block and they said go on), its `why` saying so.

## Verdict

`HOTFIX ENVIRONMENT: RECREATED | MIGRATED | UNCHANGED | NEEDS ANSWER <why> | FAILED <why>`

## Cited by

- `${CLAUDE_PLUGIN_ROOT}/skills/hotfix-steps/SKILL.md`
