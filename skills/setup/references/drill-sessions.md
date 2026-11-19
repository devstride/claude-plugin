---
load: contract
---
# Drill sessions — the sign-in token, made once per machine

Some repositories start throwaway test sessions on purpose: drills that kill, pause or clear a
session to check that the repository's agent tracking notices. Each such session must run in a
Claude Code folder of its own (`CLAUDE_CONFIG_DIR`), because every running session registers in
its own folder's session list, which the Claude Code app shows as the person's fleet: a drill run
in the person's own folder appears there beside their real work. A separate folder is not signed
in, so each one is signed in with a long-lived token the person makes once per machine
(`claude setup-token`) and keeps owner-only in a file. The repository says where with
`drillSessions.tokenFile`, an absolute or `~` path outside every repository (the script refuses
anything else, so the token can never be committed); absent or null, none of this applies: a full
setup run asks nothing and doctor reports `N/A`.

## The `drills` mode

After A1: with `drillSessions` absent or `null`, ask whether this repository starts throwaway drill sessions;
on a no, stop, writing nothing. On a yes, ask for the token file (default
`~/.devstride/drill-claude-token`) and write only `{ "drillSessions": { "tokenFile": <it> } }`
(create-with-just-that-key, or the Phase F merge). Then run the check below, and on `NOT READY` the
person's step after it. **The agent never writes the token file**: only the person's own `make`, in
their own terminal, does — it is outside setup's write boundary.

## The check

`python3 ${CLAUDE_PLUGIN_ROOT}/skills/setup/scripts/drill-token.py check` (from the repository root;
`--file <path>` names a file directly). One verdict line, quoted as printed:

- `DRILL TOKEN: N/A (drillSessions not set)` — nothing to do.
- `DRILL TOKEN: READY (<file>, signed in in a separate Claude Code folder)` — the file exists, is
  owner-only and not empty, and one tiny real request (Haiku, no tools, no settings, a one-line
  prompt, no saved session) succeeded in a fresh, empty folder that is removed afterwards, so it
  appears in no one's Claude Code. `claude auth status` is not a proof: it reports any token as
  signed in without asking the server.
- `DRILL TOKEN: NOT READY — <reason>`, then one of two fix lines:
  `Fix: /devstride:setup drills` — the file is missing, unsafe or malformed, or the server refused
  the token (HTTP 401 or 403): the person makes one, below.
  `Fix: run the check again later` — the request failed for another reason (a rate limit, an
  outage, a timeout): the token was not refused, so nobody makes a new one; report it and move on.

It never prints the token, never puts it on a command line and never writes the file.

## Doctor

§4 reports the check's lines as printed; `NOT READY` FAILs. It is never a doctor repair: making the
token is the person's own step below.

## Making it — the person's own step

The agent never makes, reads aloud or saves the token. On `NOT READY` with `Fix: /devstride:setup drills`
it gives the person this ONE command to run **in their own terminal**, with both paths filled in
as absolute, shell-quoted paths (the loaded plugin's real root, and the token file the check just
named), so it works from whatever folder a new terminal opens in:

```bash
python3 '<plugin root>/skills/setup/scripts/drill-token.py' make --file '<token file>'
```

and says why not in the agent's prompt: a command typed there (`! …`) prints its output into the
conversation, so the token would land in the transcript. `make` refuses without a terminal on both
ends for the same reason. It runs `claude setup-token` (a browser page opens), asks for the token
it printed with a hidden prompt, proves it before saving (a mistyped paste is refused and any
token already saved is kept), saves it owner-only (a new 0600 file beside it, then moved into
place; a missing folder is created 0700) and runs the check. The agent waits for the person's
"done", runs the check once more and reports its line; a second `NOT READY` is reported with its
reason, never retried in a loop.

The token is long-lived (about a year). When it expires or is revoked, the check says `NOT READY`
and the same step makes a new one.

## Cited by

- `setup` SKILL.md — the `drills` mode, and the full run's check after A1.
- `doctor` SKILL.md — §4, the `drillSessions` line (this file's "Doctor").
- `setup/references/config-defaults.md` — the `drillSessions` row.
