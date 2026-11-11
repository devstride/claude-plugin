---
load: contract
---
# Session models — the model and effort a skill expects its session to run — CANONICAL

The single authoritative rule for comparing the session a skill runs in with the model and effort
its repository expects. The citing skills apply it by citation, once per top-level run, before
their own first step, and restate nothing. It only ever reports: nothing but the person can change
a session's model or effort.

## Roles and settings

| Role | Skills | Expected model | Expected effort |
|---|---|---|---|
| `planning` | `plan`, `insert-story`, `insert-defect`, `rebalance` | `sessionModels.planning.model`, default `fable` | `sessionModels.planning.effort`, default `high` |
| `runner` | `build-item`, `ultracode-build` | `sessionModels.runner.model`, default `opus` | `sessionModels.runner.effort`, default `high` |

The keys live in the consuming repository's `.claude/ds-config.json`; an absent key means its
default. `sessionModels.check: false` switches the whole check off. A model is an alias (`default`,
`best`, `fable`, `opus`, `sonnet`, `haiku`, `opusplan`, optionally with a `[1m]` suffix) or a full
`claude-…` id; an effort is `low`, `medium`, `high`, `xhigh` or `max`.

## The check

Run once, with the citing skill's role:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/hooks/session-runtime.py" models --role <planning|runner>
```

It prints one JSON line, `{role, expected: {model, effort}, running: {model, effort}, verdict}`,
and always exits 0. `running` is what the plugin last saw this session running. Follow `verdict`:

| Verdict | Meaning | Do |
|---|---|---|
| `match` | model and effort are the expected ones | say nothing, carry on |
| `unknown` | no record, a value not seen yet, or a name that cannot be compared (`default`, `best`, `opusplan`) | say nothing, carry on; never treat it as a mismatch |
| `off` | the repository switched the check off | say nothing, carry on |
| `mismatch` | the model or the effort differs | the one line below, then the question or the unattended rule |

An alias matches a running id by family (`fable` matches `claude-fable-5-2`); a full id matches
the same model however it is reached (a `[1m]` suffix, a provider prefix or version and a release
date are ignored, unless both name different dates). Any error is `unknown`.

## On a mismatch

**The one line**, naming only what the command printed:

> Session model: this session runs `<running.model>` at `<running.effort>` effort; this repository
> expects `<expected.model>` at `<expected.effort>` for `<role>` work.

**Then ask ONCE: switch, or carry on?** Never ask again in the same run, whatever follows.

- **Switch** → tell the person to type `/model <expected.model>` and then
  `/effort <expected.effort>` themselves (only the one that differs when the other already
  matches); no skill, hook or setting can do it for them. Wait for their reply, re-run the check
  once, say its result in one line, and carry on whatever it says.
- **Carry on** → proceed as the session is.
- **A model the account does not offer** (the person says so, or `/model` refuses it) → say so in
  one line and carry on.

## Driven and unattended runs — never ask

A run is driven or unattended when another skill invoked this one, when it started from a loop or
scheduled prompt, or when nobody is there to answer. Then **never ask and never wait**: carry on,
and put one line in the run's final report:

> Session model: ran on `<running.model>` at `<running.effort>`; this repository expects
> `<expected.model>` at `<expected.effort>`.

A skill invoked by another citing skill (`ultracode-build` by `build-item`) does not run the check
again: its caller already has. An unattended loop is never stalled by this file.

## What this does not change

- **Helpers keep their own routing.** Agents a skill starts are sized by task
  (`${CLAUDE_PLUGIN_ROOT}/skills/ultracode-build/references/engineering-economy.md`); never force
  one to the session's expected model.
- **The delivery profile.** The `planning` role expects the `extended` profile. When the profile the
  skill resolved differs, add to the same one line: `The delivery profile here is <name>; planning
  expects extended.` Never ask about it: the `profile` key and its resolution order
  (`${CLAUDE_PLUGIN_ROOT}/skills/plan/references/delivery-profiles.md`) stay the authority. With
  no model or effort mismatch, say that sentence alone, once, and carry on. Never say it when the
  verdict is `off`, nor in `rebalance`, whose job is to change the profile.

## Cited by

- `plan`, `insert-story`, `insert-defect` and `rebalance` SKILL.md opening (role `planning`)
- `build-item` and `ultracode-build` SKILL.md opening (role `runner`)
- `doctor` SKILL.md §4 (the settings report)
