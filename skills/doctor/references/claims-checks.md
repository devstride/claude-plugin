---
load: contract
---
# Doctor checks for claims, the agent connection and the DevStride clearance provider

All read-only. Never print a credential or a holder; say only whether it is present.

## Ready for agents (§3)

Run `python3 "${CLAUDE_PLUGIN_ROOT}/hooks/presence-report.py" check` (no network, never a value)
and report its `AGENT CONNECTION:` line and its `PRESENCE:` line (a `Fix:` line sits between them
when the connection is not ready).

- **`AGENT CONNECTION: READY (…)`** → PASS, naming where the key was found by those fixed words
  only (the environment; the devstride connection, this project; the devstride connection, user
  level).
- **`AGENT CONNECTION: NOT READY (no API key: …)`** → FAIL: "not ready for agents: this machine's
  DevStride connection carries no API key (browser sign-in only)". The skills still run under a
  browser sign-in, but the built-in reporter shows no session on the fleet view, and a script
  reaches DevStride only where something else supplies a key (a repository's own presence
  command, `release.clearance.credentialsFile`). Fix: `/devstride:setup connect`. A member whose role cannot create an API key asks an
  administrator for that permission; nothing else gives the machine a key.
- **`AGENT CONNECTION: NOT READY (Claude Code's configuration file cannot be read safely: …)`** →
  FAIL. Fix: `chmod 600` on Claude Code's configuration file (`$CLAUDE_CONFIG_DIR/.claude.json`,
  else `~/.claude.json`) for `mode too open`; a link is replaced by the file itself; `not yours`
  and `too large` (over 16 MiB) are the person's to put right. Never the key-creation step: the
  key may already be there.
- **The `PRESENCE:` line** (`ON (…)` or `OFF (<reason>)`) is reported as it reads: `repo-null`
  and `machine-off` are someone's choice, never a gap; `command-blank` is a WARN (a `presence`
  block whose `command` is blank runs nothing), and so is `config-unreadable` (the config file
  cannot be read, so nothing is reported from this repository until it is mended).
- **`AGENT CONNECTION: NOT READY (DEVSTRIDE_BASE_URL …)`** → FAIL, with the `Fix:` line it prints.
- **Never print the stored entry**: `claude mcp get` shows a key-based entry's header values, so
  doctor never runs it and never advises it for one. A `devstride` server kept under another name,
  or only in a project `.mcp.json`, is not found: the fix is the same step.
- **Workflows** are checked in the same section:
  `${CLAUDE_PLUGIN_ROOT}/skills/doctor/references/workflows-checks.md`.

## `claims`

- **Absent or null** → "claims: not configured" (N/A, not a gap).
- **`provider: devstride`** → the agent's own DevStride connection must offer `claim_work`: list the
  connected DevStride server's tools (ToolSearch for `claim_work`) and never call one. Missing →
  FAIL: the server has no claims yet, or the key's user lacks `MANAGE_AGENT_CLAIMS`; `build-item`
  then runs without claims and says so once.
- **`commands`** → each command's first token resolves (§4's rule); never run one.
- **`expiryMinutes`** values outside 1..1440 are the validator's WARN: the default stands.

## `release.clearance` with `provider: devstride`

- **Status** → run `${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/clearance-devstride.sh status`
  once and report its first line. A clear or held answer passes; `UNKNOWN` FAILs naming the cause
  it prints.
- **Credentials** → present in the environment, in `release.clearance.credentialsFile`, or in the
  connection's own key (Ready for agents, above). A named file
  must exist and not be readable by group or others (`stat`: mode 600 or stricter); looser → FAIL,
  Fix: `chmod 600 <file>`. Report presence only.
