---
load: contract
---
# Doctor checks for claims and the DevStride clearance provider

All read-only. Never print a credential or a holder; say only whether it is present.

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
- **Credentials** → present in the environment or in `release.clearance.credentialsFile`. The file
  must exist and not be readable by group or others (`stat`: mode 600 or stricter); looser → FAIL,
  Fix: `chmod 600 <file>`. Report presence only.
