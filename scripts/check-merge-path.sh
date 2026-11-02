#!/bin/bash
# scripts/check-merge-path.sh — may this head branch open a pull request into this base?
#
# Why: a branch name is the only thing that tells an epic's release from a story or a hotfix
# before anyone reads the diff, and a stray branch (a typo, a personal experiment) must not reach
# `main` by accident. The rules live in `.claude/ds-config.json` → `mergePath`, matched with the
# plugin's own anchored rule (`skills/build-item/scripts/routing.py match`), so this repository
# enforces exactly the naming its loop produces.
#
# Rules:
#   1. A base not in `mergePath.guardedBases` is ALLOWED: only guarded bases have rules.
#   2. A head matching `mergePath.epicHeadPatterns` reaches a guarded base only as a release:
#      ALLOWED with `--bumps-version yes`, BLOCKED otherwise.
#   3. Any other head is ALLOWED when it matches `mergePath.allowedHeadPatterns`. A story or
#      one-off head is admitted by its shape; the version-bump check is its gate.
#   4. A head nothing admits is ALLOWED only when the pull request carries the label named by
#      `mergePath.overrideLabel`, and the line says so.
#
# Usage: check-merge-path.sh --head <branch> --base <branch> [--labels a,b]
#                            [--bumps-version yes|no] [--config <path>]
# First line: `ALLOWED <head> -> <base>: <why>` or `BLOCKED <head> -> <base>: <reason>`.
# Exit 0 allowed, 1 blocked, 2 usage or an unreadable config (never a fallback to defaults).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HEAD_BRANCH=""; BASE_BRANCH=""; LABELS=""; BUMPS="no"; CONFIG="$ROOT/.claude/ds-config.json"
usage() { echo "check-merge-path: $1" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --head) [ $# -ge 2 ] || usage "--head needs a value"; HEAD_BRANCH="$2"; shift 2 ;;
    --base) [ $# -ge 2 ] || usage "--base needs a value"; BASE_BRANCH="$2"; shift 2 ;;
    --labels) [ $# -ge 2 ] || usage "--labels needs a value"; LABELS="$2"; shift 2 ;;
    --bumps-version) [ $# -ge 2 ] || usage "--bumps-version needs yes or no"; BUMPS="$2"; shift 2 ;;
    --config) [ $# -ge 2 ] || usage "--config needs a path"; CONFIG="$2"; shift 2 ;;
    -h|--help) awk 'NR>1 && !/^#/{exit} NR>1{print}' "$0"; exit 0 ;;
    *) usage "unknown argument: $1" ;;
  esac
done
[ -n "$HEAD_BRANCH" ] || usage "--head <branch> is required"
[ -n "$BASE_BRANCH" ] || usage "--base <branch> is required"
case "$BUMPS" in yes|no) ;; *) usage "--bumps-version must be yes or no" ;; esac
command -v python3 >/dev/null 2>&1 || usage "python3 is required"
ROUTING="$ROOT/skills/build-item/scripts/routing.py"
[ -f "$ROUTING" ] || usage "missing $ROUTING"
MP_HEAD="$HEAD_BRANCH" MP_BASE="$BASE_BRANCH" MP_LABELS="$LABELS" MP_BUMPS="$BUMPS" \
MP_CONFIG="$CONFIG" MP_ROUTING="$ROUTING" python3 - <<'PY'
import json, os, subprocess, sys
head, base = os.environ["MP_HEAD"], os.environ["MP_BASE"]
labels = [l.strip() for l in os.environ["MP_LABELS"].split(",") if l.strip()]
bumps = os.environ["MP_BUMPS"] == "yes"
def usage(msg):
    print("check-merge-path: " + msg, file=sys.stderr); sys.exit(2)
try:
    with open(os.environ["MP_CONFIG"], encoding="utf-8") as f:
        config = json.load(f)
except (OSError, ValueError) as error:
    usage("cannot read %s (%s)" % (os.environ["MP_CONFIG"], error))
rules = config.get("mergePath") if isinstance(config, dict) else None
if not isinstance(rules, dict):
    usage("%s has no mergePath object" % os.environ["MP_CONFIG"])
def strings(key):
    value = rules.get(key)
    if not isinstance(value, list) or not all(isinstance(x, str) and x for x in value):
        usage("mergePath.%s must be a list of non-empty strings" % key)
    return value
guarded, epic, allowed = strings("guardedBases"), strings("epicHeadPatterns"), strings("allowedHeadPatterns")
override = rules.get("overrideLabel")
if not isinstance(override, str) or not override:
    usage("mergePath.overrideLabel must be a non-empty string")
def match(name, patterns):
    run = subprocess.run([sys.executable, os.environ["MP_ROUTING"], "match"], text=True,
                         input=json.dumps({"name": name, "patterns": patterns}), capture_output=True)
    if run.returncode != 0:
        usage("the routing helper refused: " + (run.stderr.strip() or "exit %d" % run.returncode))
    return json.loads(run.stdout).get("pattern")
line = lambda verdict, why: print("%s %s -> %s: %s" % (verdict, head, base, why))
if base not in guarded:
    line("ALLOWED", "%s is not a guarded base" % base); sys.exit(0)
verdict = None
hit = match(head, epic)
if hit:
    if bumps:
        line("ALLOWED", "%s (an epic's release, with a version bump)" % hit); sys.exit(0)
    verdict = "an epic branch reaches %s only as a release, and this change does not bump the version" % base
else:
    hit = match(head, allowed)
    if hit:
        line("ALLOWED", hit); sys.exit(0)
    verdict = "no admitted branch shape matches (%s)" % ", ".join(allowed)
if override in labels:
    line("ALLOWED", "the %s label overrides: %s" % (override, verdict)); sys.exit(0)
line("BLOCKED", verdict); sys.exit(1)
PY
