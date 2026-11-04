#!/bin/bash
# skills/release/scripts/previous-release-gate.sh [--wait]
# Reads the previous release merge's `release/post-deploy` status: 0 success or none (or not
# gated) · 1 failed · 2 pending · 3 no status · 4 unreadable. --wait polls a pending one.
# Contract: post_deploy_gate.py and references/clearance.md ("Scope cut-to-deploy").
exec python3 "$(cd "$(dirname "$0")" && pwd)/post_deploy_gate.py" gate "$@"
