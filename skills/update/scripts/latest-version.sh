#!/usr/bin/env bash
# Print the newest published DevStride tag. `--json` also includes its peeled commit.
set -u
exec python3 "$(dirname "$0")/update-plugin.py" latest "$@"
