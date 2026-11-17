---
load: contract
---
# Session presence — every running session reports its live status

A fleet view built from work claims shows only sessions that hold a claim. A session reviewing,
fixing, waiting on tests or waiting for its person has no row, so the view undercounts exactly
when someone is watching it. Presence closes that gap: the plugin's hooks report every session,
whatever it is doing, inside a repository or not. The hook is `hooks/presence.py`; its docstring
is the contract in full.

## Two reporters, and which one runs

Decided per session by `skills/build-item/scripts/presence_settings.py`, in this order:

1. **Off.** `DEVSTRIDE_PRESENCE` set to `0` (or `false`, `off`, `no`) switches a whole machine off,
   a repository's own command included. `"presence": null` in `.claude/ds-config.json` switches a
   repository off. Nothing runs and nothing is written. **These are the only two switches.** (A
   config file that is there but cannot be read switches nothing on: off until it is mended.)
2. **The repository's own command**, when its block names one:
   `"presence": { "command": "<the repository's own command>", "intervalMinutes"?: 5 }`. It always
   wins over the built-in reporter, and what a report means, where it is stored and when it expires
   are then the repository's, behind its command. A blank `command` runs nothing.
3. **Otherwise the built-in reporter**, `hooks/presence-report.py`: no block, an empty block, a
   block with only `intervalMinutes`, a repository with no config file, or a session outside any
   repository. It sends each report to DevStride (the tool `report_session_presence`) with the API
   key the machine's DevStride connection carries. **With no key nothing runs and no record is
   written**: the first session start on such a machine says so in one line, once per machine (an
   empty marker file beside the records remembers it), and nothing else is ever printed.

`intervalMinutes` (an integer, 1 to 60) is the keeper's beat: default 5 with a command, 1 for the
built-in reporter; one out of range reads as that default, and doctor warns.

## The one key

There is one DevStride credential per agentic machine: the API key its DevStride connection
carries. The built-in reporter and the DevStride release clearance provider find it in one place,
`skills/build-item/scripts/devstride_connection.py`, in one order: the environment
(`DEVSTRIDE_API_KEY`, `DEVSTRIDE_API_SECRET`, `DEVSTRIDE_ORG_ID`); for the clearance provider only,
the file `release.clearance.credentialsFile` names; then the server named `devstride` in Claude
Code's configuration file (`$CLAUDE_CONFIG_DIR/.claude.json`, else `~/.claude.json`), first the
session's own project entry (the repository's main checkout, then the checkout, then the session's
directory), then the user-level entry. An entry counts only when its address is a DevStride API
host followed by `/mcp` and it holds literal values for the key, the secret and the organization
id; the three and the address are taken together from that one entry. The file is read only when
it is a regular file the user (or root) owns, not a link, at most 16 MiB, with no group or other
permission bits.

The key goes only to an `https://api(-<stage>).devstride.(com|dev)` host, redirects are refused,
every call is bounded, and no hook prints or logs a key, puts one on a command line or adds one to
a child's environment. **The plugin creates no key, writes no key anywhere and never asks for one
in the chat.** A connection that only signs in through the browser carries no key: that machine is
**not ready for agents**, and nothing works around it (Claude Code's own sign-in token is never
read). A project `.mcp.json` is not read, nor a `devstride` server kept under another name.

## What the built-in reporter sends

`event`, `sessionId`, `state`, `machine`, `label` (the session's own name), `branch`, `checkout`
(the folder's base name, never a path; none outside a repository), `item`, `pluginVersion`,
`intervalMinutes`, `reportedAt`, `activeAt`, `busySince` and, on an end, `endReason`: the values of
the variables below, cleaned (control characters become spaces; cut to 500 characters for the
branch and checkout, 200 for the machine and label, 64 for the item, version and end reason). **Never session text, a
prompt, a file's content, a path or the machine's address.** Reports go to the organization the key
belongs to. Any member's agent reports its own sessions; who may read the fleet view is the
organization's to grant, so a member's sessions are visible to its administrators.

The server answers `recorded`, `ended`, `stale` (an older report than the one stored) or
`not-owner` (the session's row belongs to another user); all four are ordinary. **It fails open,
quietly:** one attempt, 15 seconds at most, never on a turn's clock, never a word printed. A server
with no such tool, or one that refuses the key (HTTP 401 or 403), quiets the session's reports for
30 minutes; an unreachable or failing server (a timeout, HTTP 429 or 5xx) for 2 minutes; the next
good answer clears it. An end that falls inside a quiet window is not sent: the row lapses by silence.

## Connecting this machine

The body of `/devstride:setup connect`: the one step, done once per machine, that makes the
DevStride connection key-based. It serves the agent's DevStride tools and live status alike.

1. Run `python3 "${CLAUDE_PLUGIN_ROOT}/hooks/presence-report.py" check` and read its first line.
2. `AGENT CONNECTION: READY (…)` → say where the key was found, in those fixed words only, and
   stop, offering the proof (step 4).
3. `AGENT CONNECTION: NOT READY (Claude Code's configuration file cannot be read safely: …)` →
   the key may already be there: give that file's fix (`chmod 600` for `mode too open`; a link
   replaced by the file itself), then run `check` again. Any other `NOT READY (…)` → say in plain words that this machine is connected by browser
   sign-in only (or not at all), and that such a connection is not ready for agents. Then give the
   one step, for the person to do **in their own terminal**: create a key in DevStride under
   Profile Settings, API Keys (a role that cannot is told to ask an administrator for the
   permission to create API keys); with the key, the secret and the organization id held in the
   three variables, run

   ```bash
   claude mcp add --transport http --scope user devstride https://api.devstride.com/mcp \
     --header "X-DevStride-Api-Key: $DEVSTRIDE_API_KEY" \
     --header "X-DevStride-Api-Secret: $DEVSTRIDE_API_SECRET" \
     --header "X-DevStride-Organization-Id: $DEVSTRIDE_ORG_ID"
   ```

   then `claude mcp logout plugin:devstride:devstride`, and restart Claude Code. The command writes
   the key into Claude Code's own user configuration, the single place the agent's tools and the
   reporter both read it from. The sign-out matters: two live DevStride connections expose the
   same tool names, and a call can reach the wrong organization.
4. When the person says it is done, run `check` again. **Only after a typed yes**, run
   `python3 "${CLAUDE_PLUGIN_ROOT}/hooks/presence-report.py" prove` (it sends a start and an end for
   a throwaway session) and report its one `PROOF:` line.

**Setup never asks for a key, a secret or an organization id in the chat, never runs that command
itself or through the `!` prefix (its output would join the conversation), never prints the stored
entry, and writes no file of its own.**

## When a report is sent

| When | `PRESENCE_EVENT` | `PRESENCE_STATE` |
| --- | --- | --- |
| Session start (new, resumed, after `/clear`; not after a compaction) | `start` | `starting` |
| A prompt, with no report yet in this session, or after an `end` | `start` | `working` |
| A prompt, a minute or more after the last report, or from another checkout | `beat` | `working` |
| A tool call starting or ending, or an MCP prompt answered, while `starting` or `waiting` (a turn with no prompt), except while a question is open | `beat` | `working` |
| A question or plan approval from the main conversation (`AskUserQuestion`, `ExitPlanMode`), or a permission or elicitation prompt unanswered for about 6 seconds | `beat` | `waiting` |
| A finished turn (Claude waits for its person); nothing after an `end` | `beat` | `waiting` |
| A finished turn that left its own background work running (a test run, a background helper; not a teammate) | `beat` | `working` |
| The idle prompt, about 60 seconds after a finished turn, unless background work runs or the turn ended on an API error | `beat` | `waiting` |
| An interrupted turn (Esc), which fires no hook: the keeper reads it from the end of the transcript while `working` | `beat` | `waiting` |
| The keeper, when the last report is `intervalMinutes` old, or a held change is 30 seconds old | `beat` | the latest |
| Session end (`PRESENCE_END_REASON`: `clear`, `logout`, …) | `end` | `ended` |
| The keeper finds the session's process gone (killed, crashed) | `end` (reason `gone`) | `ended` |

A state change within 30 seconds of the last report is held and carried by the next report.
Reports for one session run one at a time; each is numbered when queued, and one overtaken by a
newer report is dropped, so a late `end` never follows a resumed session's `start`. The keeper,
one detached process per session, checks every 10 seconds, keeps a long turn visible and exits
once the session ends, its record goes, reporting is switched off, the connection loses its key or
the session loads another plugin version, whose next hook event starts its own. A session that
moves to a place where reporting is off keeps reporting under the one it came from, and so does a
session its repository's command reports when it moves to a place that names no command (the
built-in reporter never takes it over); one outside a repository that walks into one beats from it.

## What a repository's command receives

Run from the repository root through the shell, at most 20 seconds, never on the hook's own
clock (the hook spawns it and returns). The built-in reporter is given the same variables (and no
arguments), from the repository root or the session's directory. Exported: `PRESENCE_EVENT`, `PRESENCE_STATE`,
`PRESENCE_SESSION_ID`, `PRESENCE_MACHINE` (the claim machine name),
`PRESENCE_CHECKOUT` (the checkout's root; empty outside a repository, as the branch and item then are), `PRESENCE_BRANCH`, `PRESENCE_ITEM` (an item number the branch name carries as its own
segment, such as `I20100` in `jane/03-14-26/I20100-attachment-storage`; else empty),
`PRESENCE_PLUGIN_VERSION` (the sender's), `PRESENCE_INTERVAL_MINUTES`, `PRESENCE_END_REASON` (on `end` only),
`PRESENCE_AT` (when queued, in epoch milliseconds, rising with each report, so an
older one can be dropped), `PRESENCE_ACTIVE_AT` (the last hook event or interrupt, epoch milliseconds, but never
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
  `waiting` is the person's turn and is never hung. An interrupt fires no hook, not even the idle
  prompt: the keeper reads Claude Code's interrupt entry at the end of the transcript and reports
  `waiting` (a transcript it cannot read changes nothing; a local command typed within ten seconds
  of the interrupt hides it until the idle prompt 60 seconds after that command). A background
  helper still running after the interrupt reports `working` again at its next tool call. One
  blind spot: no hook marks a permission approval, so an approved command that runs long reads
  `waiting` until it ends.
- **Fail fast and quietly.** A slow or failing command costs that one report, never a turn.
- **Quote every variable.** A branch name can hold shell syntax: pass `"$PRESENCE_BRANCH"`
  quoted, or read the variables from the environment in code.

## Cited by

- `skills/setup/references/config-defaults.md` — the Session presence section.
- `schemas/seam-registry.json` — `presence.command`'s contract.
- `hooks/presence.py` and `hooks/presence-report.py` — their docstrings.
- `skills/setup/SKILL.md` — the `connect` mode; `skills/doctor/SKILL.md` §3 and
  `skills/doctor/references/claims-checks.md` — "Ready for agents".
- `README.md` — "Connect to DevStride" and "Live status on the Fleet".
