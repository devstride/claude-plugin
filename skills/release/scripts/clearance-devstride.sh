#!/bin/bash
# skills/release/scripts/clearance-devstride.sh — the release clearance provider backed by DevStride.
#
# The same six verbs, exit codes, verdict lines, local record and `status --json` as
# clearance-github.sh (the contract: skills/release/references/clearance.md); only the store
# differs. The clearance is one DevStride claim — kind `release-tower`, keyed by the repository
# (owner/name) — won by exactly one holder and kept alive by heartbeats. Its expiry is
# staleMinutes, so a dead keeper's claim lapses at the stale threshold, and the whole clearance
# record rides in the claim's payload (with the holder as the server's digest, never the holder
# itself). Moves go through the DevStride MCP server's claim tools over HTTP.
#
# Credentials: DEVSTRIDE_API_KEY, DEVSTRIDE_API_SECRET, DEVSTRIDE_ORG_ID, and optionally
# DEVSTRIDE_ORG_SLUG and DEVSTRIDE_BASE_URL (default https://api.devstride.com), from the
# environment; any that are unset are read from the KEY=VALUE file release.clearance.credentialsFile
# names in .claude/ds-config.json (a relative path is from the repository root, "~/" is expanded).
# A file with any group or other permission is refused. The key, the secret and the holder are
# never printed. `gh` is still needed for pull-request facts and the user name (every verb but
# `identity`). Everything else (configuration, environment overrides, liveness, the keeper) is
# described in clearance-github.sh and clearance_core.py.
set -u
command -v python3 >/dev/null 2>&1 || { echo "clearance: python3 is required" >&2; exit 1; }
if [ "${1:-}" != identity ]; then
  command -v gh >/dev/null 2>&1 || { echo "clearance: gh is required (https://cli.github.com)" >&2; exit 1; }
fi
DIR="$(cd "$(dirname "$0")" && pwd)"
CLEARANCE_SELF="$DIR/$(basename "$0")"; export CLEARANCE_SELF
exec python3 "$DIR/clearance_core.py" devstride "$@"
