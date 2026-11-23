#!/bin/bash
# scripts/check-source.sh — every check the plugin's source must pass, in one command.
#
# Why: the same list of checks runs wherever a change to the plugin is judged (on the author's
# machine before the change lands, on a pull request, and again before a version is published),
# so the list lives in one script instead of being repeated and drifting.
#
# Modes:
#   local   for a machine with the claude CLI: neutrality, the generated config schema, the
#           config-key scan, the maximal example config, the public-hygiene scan, the workflow
#           registry, the version-bump rule, then validate.sh --needles (the three `claude plugin validate` passes, the
#           marketplace invariant, bash -n, the train-name check, the workflow definitions,
#           tests/run.sh, the load budgets and the rule-loss needles).
#   cloud   the same checks without the steps that need the claude CLI: bash -n, neutrality, the
#           load budgets, the schema, the config-key scan, the workflow definitions, the example
#           config, the hygiene scan, the workflow registry, the version-bump rule, then
#           tests/run.sh.
#
# Order: the checks that take seconds run first and the script tests last (they take minutes), so
# a broken tree is named by the check that owns the fault. The tests also run several of these
# checks against the tree, and would otherwise report the same fault first, as a failed test.
#
# `--base <ref>` (default origin/master) is what was last published: the schema check and the
# version-bump rule compare against it, and the hygiene scan reads its allow list from it (from the
# newest `plugin import` commit while the base does not hold the plugin yet), never this change's
# own, so a new allow line is published in a change of its own first and no change can wave its own
# finding through. `--head <ref>` (default HEAD) is the commit the version-bump
# rule reads, which reads commits, not the working tree: a caller that has edited the tree without
# committing (ds-plugin-release prepare) passes a commit of that tree. `--in-flight <ref>`
# (repeatable) reaches only the version-bump rule: a branch whose version is already on its way to
# release, which this change's version must be above (see check-version-bump.sh). `--list` prints
# the mode's steps, one `<name><TAB><command>` line each, and runs nothing.
#
# Each step prints its name before it runs. The run stops at the first step that fails, and the
# last line printed is always exactly one of
#   PLUGIN SOURCE: CLEAN
#   PLUGIN SOURCE: FAILED at <step>
#
# Usage: check-source.sh --mode local|cloud [--base <ref>] [--head <ref>] [--in-flight <ref>]... [--list]
# Exit 0 clean, 1 a step failed, 2 usage.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE=""; BASE="origin/master"; HEAD_REF=""; LIST=0; IN_FLIGHT=()
usage() { echo "check-source: $1 (usage: --mode local|cloud [--base <ref>] [--head <ref>] [--in-flight <ref>]... [--list])" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) [ $# -ge 2 ] || usage "--mode needs a value"; MODE="$2"; shift 2 ;;
    --base) [ $# -ge 2 ] || usage "--base needs a value"; BASE="$2"; shift 2 ;;
    --head) [ $# -ge 2 ] && [ -n "$2" ] || usage "--head needs a value"; HEAD_REF="$2"; shift 2 ;;
    --in-flight) [ $# -ge 2 ] && [ -n "$2" ] || usage "--in-flight needs a value"; IN_FLIGHT+=(--in-flight "$2"); shift 2 ;;
    --list) LIST=1; shift ;;
    -h|--help) awk 'NR>1 && !/^#/{exit} NR>1{print}' "$0"; exit 0 ;;
    *) usage "unknown argument: $1" ;;
  esac
done
case "$MODE" in
  local|cloud) ;;
  '') usage "--mode is required" ;;
  *) usage "unknown mode: $MODE" ;;
esac
[ -n "$BASE" ] || usage "--base needs a value"
cd "$ROOT" || usage "cannot enter $ROOT"

# bash -n over every shipped and maintenance script, under the interpreter the shebangs name
# (/bin/bash, which is 3.2 on macOS).
bash_n_every_script() {
  local sh=/bin/bash f
  [ -x "$sh" ] || sh=bash
  for f in hooks/*.sh scripts/*.sh scripts/tests/*.sh skills/*/scripts/*.sh; do
    [ -f "$f" ] || continue
    "$sh" -n "$f" || { echo "syntax error in $f" >&2; return 1; }
  done
  echo "bash -n: ok"
}

# One step: its name, then the command. With --list it is printed and not run.
step() {
  local name="$1"; shift
  if [ "$LIST" = 1 ]; then printf '%s\t%s\n' "$name" "$*"; return 0; fi
  printf '\n== %s: %s ==\n' "$name" "$*"
  "$@" && return 0
  printf '\nPLUGIN SOURCE: FAILED at %s\n' "$name"
  exit 1
}

# Steps both modes share.
neutrality()        { step neutrality bash scripts/check-neutrality.sh; }
schema()            { step schema python3 scripts/build-config-schema.py --check --release --base "$BASE"; }
config_keys()       { step config-keys python3 scripts/check-config-keys.py; }
config_validation() { step config-validation python3 skills/doctor/scripts/validate-config.py scripts/tests/fixtures/config/plugin-repo.json --schema schemas/ds-config.schema.json; }
# The published allow list (see --base above) written to $1: the base's copy, else the newest
# `plugin import` commit's. Neither holding one fails the step: there is nothing to scan against.
published_allow() {
  local from=""
  if git cat-file -e "$BASE:./scripts/public-hygiene.allow" 2>/dev/null; then
    from="$BASE"
  else
    # --grep matches any line of a message, so the subject is tested again, anchored.
    from="$(git log --format='%H %s' --grep='^plugin import' HEAD 2>/dev/null | awk '$2 == "plugin" && $3 ~ /^import/ { print $1; exit }')"
    if [ -z "$from" ] || ! git cat-file -e "$from:./scripts/public-hygiene.allow" 2>/dev/null; then
      echo "hygiene: neither $BASE nor a 'plugin import' commit holds scripts/public-hygiene.allow: no published allow list to scan against" >&2
      return 1
    fi
  fi
  git show "$from:./scripts/public-hygiene.allow" > "$1" || return 1
  echo "allow list: scripts/public-hygiene.allow at $from (the published one, not this change's)"
}
# Against both lists: the published one, so a change cannot excuse itself, and the change's own,
# which the publisher scans the export with, so withdrawing an exception that is still needed is
# caught here, not after the deploy.
hygiene_scan() {
  published_allow "$1" && bash scripts/check-public-hygiene.sh --tree . --allow "$1" \
    && bash scripts/check-public-hygiene.sh --tree . --allow scripts/public-hygiene.allow
}
hygiene() {
  if [ "$LIST" = 1 ]; then step hygiene hygiene_scan "<scripts/public-hygiene.allow at $BASE>"; return 0; fi
  local allow
  allow="$(mktemp "${TMPDIR:-/tmp}/check-source-allow.XXXXXX")" || { echo "hygiene: cannot create a temporary file" >&2; printf '\nPLUGIN SOURCE: FAILED at hygiene\n'; exit 1; }
  # shellcheck disable=SC2064
  trap "rm -f '$allow'" EXIT
  step hygiene hygiene_scan "$allow"
}
# The append-only version record of every built-in workflow and step contract, against the base
# this branch started from (workflow-registry.py finds it), and its generated history page.
registry()          { step registry python3 scripts/workflow-registry.py check; }
version_bump() {
  local args=(--base "$BASE")
  [ -n "$HEAD_REF" ] && args+=(--head "$HEAD_REF")
  # ${arr[@]+...}: bash 3.2 under `set -u` treats an empty array as unset
  step version-bump bash scripts/check-version-bump.sh "${args[@]}" ${IN_FLIGHT[@]+"${IN_FLIGHT[@]}"}
}

if [ "$MODE" = local ]; then
  neutrality
  schema
  config_keys
  config_validation
  hygiene
  registry
  version_bump
  step validate bash scripts/validate.sh --needles
else
  step shell-syntax bash_n_every_script
  neutrality
  step budgets bash scripts/measure-cost.sh --check
  schema
  config_keys
  step workflows python3 scripts/check-workflows.py
  config_validation
  hygiene
  registry
  version_bump
  step tests bash scripts/tests/run.sh
fi
[ "$LIST" = 1 ] && exit 0
printf '\nPLUGIN SOURCE: CLEAN\n'
