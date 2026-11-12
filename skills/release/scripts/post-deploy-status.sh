#!/bin/bash
# skills/release/scripts/post-deploy-status.sh <sha> <pending|success|failure|error> <description>
# Posts the `release/post-deploy` commit status on the production merge commit — only under
# release.clearance.scope "cut-to-deploy" or "merge-and-deploy"; otherwise prints SKIPPED and posts nothing.
# Contract: post_deploy_gate.py and references/clearance.md ("Scope cut-to-deploy").
exec python3 "$(cd "$(dirname "$0")" && pwd)/post_deploy_gate.py" status "$@"
