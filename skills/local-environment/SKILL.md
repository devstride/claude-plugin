---
name: local-environment
description: "Step: run one localEnvironment command (create, recreate, migrate, seed, teardown or name) with its placeholders filled, and print one verdict."
---

Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/step-skills.md` first: the rule every step skill follows.

Arguments: $ARGUMENTS — `<verb> [<name>] [--branch <b>] [--base <ref>]`; verbs `create`,
`recreate`, `migrate`, `seed`, `teardown`, and `name` (runs `localEnvironment.instanceName`).

## Verdict

`LOCAL ENVIRONMENT <verb>: DONE | NOT CONFIGURED | FAILED`

## Steps

1. Read the `localEnvironment` block. **An absent member is the shipped `null`** — read every
   missing member as `null`. Block absent, or the verb's command `null` → `NOT CONFIGURED`: no
   isolated instances, the current checkout is the only environment; never invent a command.
2. **Substitute every placeholder before running — never pass one through to a shell**
   (`<base>` unexpanded is input redirection and reads as a broken environment). `<base>` = the
   freshly fetched ref the caller names (a stale tracking ref rebuilds old code); `<branch>` = the
   caller's branch; `<name>` = the instance.
3. **Never guess an instance name.** For `recreate`, `<name>` follows
   `localEnvironment.recreateMode` — the ONLY thing that says what the command does, never inferred
   from its text: `newInstance` → the new name the caller gives; `inPlace` → the output of
   `localEnvironment.instanceName`. That command null or failing, or the mode absent while the
   command contains `<name>` → `FAILED`: stop and ask, explaining both values.
4. Run the one command from the repository root. Exit 0 → `DONE` (for `name`, the name on the
   next line); anything else → `FAILED` with its last output lines.

Which verbs run, in what order, and when to stop belong to the caller (`branch-hotfix`).
