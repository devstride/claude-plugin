#!/bin/bash
# skills/release/scripts/clearance-github.sh — the built-in release clearance provider.
#
# One cleared release at a time, for every machine and account that releases this repository,
# with nothing but git and `gh`. The clearance is a custom git ref in the repository (default
# `refs/clearance/release`) pointing at an annotated tag object whose message is the clearance
# record as JSON. Every move of that ref is a compare-and-swap through `git push
# --force-with-lease=<ref>:<expected>`: a claim expects the ref to be ABSENT, a heartbeat, an
# adoption or a stale takeover expects the exact object it read, and the server rejects every
# caller whose expectation is stale — so there is no look-then-act anywhere, not even on the
# stale path. The ref is neither a branch nor a tag, so it triggers no workflow, appears in no
# branch or tag list, and no ruleset pattern matches it. The contract every command honours —
# exit codes, first lines, the local record — is skills/release/references/clearance.md, which a
# repository-supplied provider follows too.
#
#   claim     [--wait [--ignore-stuck]] [--purpose <text>]
#                                              0 CLEARED · 2 BUSY · 3 STALE (pull request open) ·
#                                              5 STUCK (--wait only) · 1 error
#   status    [--short] [--json]               0 when the ref was read (CLEAR or held) · 1 unreadable
#   heartbeat <phase> [--branch b] [--pr n]    0 · 4 NOT HOLDER
#   release   [--force] [--owed <item>]...     0 · 4 NOT HOLDER
#   adopt     --yes [--original-stopped]       0 ADOPTED · 2 not stale (or stuck and not confirmed stopped) · 4 nothing to adopt
#   owed      [--done <item>]... [--clear] [--release <name>] [--pr <n>]
#                                              0 — the close-out work still owed after a hand-back
#   identity                                   0 — prints this session's holder; 1 when it has none (needs no gh or git)
#   keeper    (internal)                       the detached heartbeat a claim starts; see below
#
# LIVENESS. A clearance is stale when its heartbeat is older than staleMinutes (default 20). A
# release skill's phases run far longer than that with nothing to say, so `claim` and `adopt`
# start a detached KEEPER that re-stamps the heartbeat every staleMinutes/3 for as long as the
# agent process that claimed (the first non-shell ancestor of the claiming command) is alive and
# the local record still names this holder; `release` stops it. A crashed or killed agent takes
# its keeper with it, and the clearance goes stale on schedule. The skill's own `heartbeat
# <phase>` calls record progress; they are not what keeps the clearance alive.
#
# PROGRESS. Alive is not the same as moving. A heartbeat that changes the phase stamps
# phaseStartedAt; a phase with a budget (release.clearance.phaseBudgetMinutes over the defaults
# below) that runs past it is STUCK — shown by status and in every BUSY line, never taken over:
# adopting a stuck clearance that is still alive needs --original-stopped, the owner's word that
# the original session has stopped. The provider cannot prove that, so it never decides it.
#
# CLOSE-OUT OWED. A release hands clearance back before the work nothing else waits on (its
# documentation, owed messages, local clean-up). `release --owed <item>` records that work in a
# local file beside the record (<record>.owed.json), status shows it, and `owed --done <item>`
# clears it, so a session that dies after the hand-back leaves a visible trace.
#
# Configuration comes from the nearest `.claude/ds-config.json` above the working directory:
# release.clearance.{ref, staleMinutes, waitMinutes, phaseBudgetMinutes}, release.productionBranch,
# release.releaseSource, release.releaseBranchPattern and releaseTower.hotfixPattern. Environment
# overrides exist for tests and for a wrapper: CLEARANCE_REF, CLEARANCE_STALE_MINUTES,
# CLEARANCE_WAIT_MINUTES, CLEARANCE_POLL_SECONDS (default 60), CLEARANCE_RECORD (the local record
# path), CLEARANCE_REPO (owner/name), CLEARANCE_REMOTE (default origin),
# CLEARANCE_PRODUCTION_BRANCH, CLEARANCE_RELEASE_PATTERN, CLEARANCE_HOTFIX_PATTERN, CLEARANCE_NOW
# (an ISO instant, tests only), CLEARANCE_NO_KEEPER=1, CLEARANCE_OWNER_PID, CLEARANCE_KEEPER_SECONDS,
# CLEARANCE_PHASE_BUDGETS (a JSON object over the configured budgets), CLEARANCE_OWED_RECORD.
#
# The verbs live in clearance_core.py, shared with clearance-devstride.sh; this file is the GitHub
# store (a custom git ref moved by compare-and-swap) and its prerequisites. Runs under macOS
# /bin/bash 3.2: bash only hands over to python3, the toolchain the plugin's hooks already assume.
# Needs a checkout with the remote (`origin`) that the repository's pushes use, and `gh` signed in
# (pull-request facts and the user name).
set -u
command -v python3 >/dev/null 2>&1 || { echo "clearance: python3 is required" >&2; exit 1; }
if [ "${1:-}" != identity ]; then
  command -v gh >/dev/null 2>&1 || { echo "clearance: gh is required (https://cli.github.com)" >&2; exit 1; }
  command -v git >/dev/null 2>&1 || { echo "clearance: git is required" >&2; exit 1; }
fi
DIR="$(cd "$(dirname "$0")" && pwd)"
CLEARANCE_SELF="$DIR/$(basename "$0")"; export CLEARANCE_SELF
exec python3 "$DIR/clearance_core.py" github "$@"
