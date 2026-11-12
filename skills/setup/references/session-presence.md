---
load: contract
---
# Session presence — every running session reports itself

A fleet view built from work claims shows only sessions that hold a claim. A session reviewing,
fixing, waiting on tests or waiting for its person has no row, so the view undercounts exactly
when someone is watching it. Presence closes that gap: the plugin's hooks report every session,
whatever it is doing, through ONE command the repository names. The hook is
`hooks/presence.py`; its docstring is the contract in full.

## The block (`.claude/ds-config.json`)

`presence`: `{ "command": "<the repository's own command>", "intervalMinutes"?: 5 }`.
**An absent or null block, or a blank `command`, runs nothing and writes nothing.** The plugin
never contacts a tracker for presence: what a report means, where it is stored and when it
expires are the repository's, behind its command. `intervalMinutes` (an integer, 1 to 60; one out
of range reads as 5, and doctor warns) is the keeper's beat.

## When the command runs

| When | `PRESENCE_EVENT` | `PRESENCE_STATE` |
| --- | --- | --- |
| Session start (new, resumed, after `/clear`; not after a compaction) | `start` | `starting` |
| A prompt, with no report yet in this session, or after an `end` | `start` | `working` |
| A prompt, a minute or more after the last report, or from another checkout | `beat` | `working` |
| A tool call starting or ending, or an MCP prompt answered, while `starting` or `waiting` (a turn with no prompt), except while a question is open | `beat` | `working` |
| A question or plan approval from the main conversation (`AskUserQuestion`, `ExitPlanMode`), or a permission or elicitation prompt unanswered for about 6 seconds | `beat` | `waiting` |
| A finished turn (Claude waits for its person); nothing after an `end` | `beat` | `waiting` |
| A finished turn that left its own background work running (a test run, a background helper; not a teammate) | `beat` | `working` |
| The idle prompt, about 60 seconds after a finished turn or an interrupt, unless background work runs or the turn ended on an API error | `beat` | `waiting` |
| The keeper, when the last report is `intervalMinutes` old, or a held change is 30 seconds old | `beat` | the latest |
| Session end (`PRESENCE_END_REASON`: `clear`, `logout`, …) | `end` | `ended` |
| The keeper finds the session's process gone (killed, crashed) | `end` (reason `gone`) | `ended` |

A state change within 30 seconds of the last report is held and carried by the next report.
Reports for one session run one at a time; each is numbered when queued, and one overtaken by a
newer report is dropped, so a late `end` never follows a resumed session's `start`. The keeper,
one detached process per session, checks every 10 seconds, keeps a long turn visible and exits
once the session ends, its record goes or the block is removed. A session that moves to a
checkout without the block keeps reporting under the one it came from.

## What the command receives

Run from the repository root through the shell, at most 20 seconds, never on the hook's own
clock (the hook spawns it and returns). Exported: `PRESENCE_EVENT`, `PRESENCE_STATE`,
`PRESENCE_SESSION_ID`, `PRESENCE_MACHINE` (the claim machine name),
`PRESENCE_CHECKOUT` (the checkout's root), `PRESENCE_BRANCH`, `PRESENCE_ITEM` (an item number the branch name carries as its own
segment, such as `I20100` in `jane/03-14-26/I20100-attachment-storage`; else empty),
`PRESENCE_PLUGIN_VERSION`, `PRESENCE_INTERVAL_MINUTES`, `PRESENCE_END_REASON` (on `end` only),
`PRESENCE_AT` (when queued, in epoch milliseconds, rising with each report, so an
older one can be dropped), `PRESENCE_ACTIVE_AT` (the last hook event, epoch milliseconds, but never
`end`, a turn ended on an API error or an idle prompt the state ignores; may be empty), `PRESENCE_BUSY_SINCE` (epoch milliseconds, digits only:
the earliest start of a tool call still open, or when a finished turn left background work running;
empty when neither, and on `end`), and `CLAUDE_CODE_SESSION_ID` and `CLAUDE_PID`, so the repository can resolve the session's own
name. Its exit code is kept in the session's local record; nothing reads it as a verdict.

## Rules a repository's implementation should keep

- **Display only.** Presence never decides who acts; claims do. It may renew or release claims
  its own session holds.
- **Expire on the server.** A report not renewed within a few intervals means the session is gone:
  a machine that sleeps or loses power sends no `end`.
- **Alive is not active.** A hung turn still beats. Activity is stamped before and after each tool
  call (a refused call closes when its batch ends), so `working` with an old `PRESENCE_ACTIVE_AT` and no `PRESENCE_BUSY_SINCE` is hung (or
  stopped by a usage limit, which stamps nothing); `working` with a `PRESENCE_BUSY_SINCE` is inside
  one long step or waiting on its own background work, and deserves a longer allowance, not none.
  `waiting` is the person's turn and is never hung. Two blind spots: no hook marks a permission
  approval, so an approved command that runs long reads `waiting` until it ends; and no hook fires
  on an interrupt, so it reads `working` until the idle prompt about 60 seconds later.
- **Fail fast and quietly.** A slow or failing command costs that one report, never a turn.
- **Quote every variable.** A branch name can hold shell syntax: pass `"$PRESENCE_BRANCH"`
  quoted, or read the variables from the environment in code.

## Cited by

- `skills/setup/references/config-defaults.md` — the Session presence section.
- `schemas/seam-registry.json` — `presence.command`'s contract.
- `hooks/presence.py` — its docstring.
