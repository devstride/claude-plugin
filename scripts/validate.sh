#!/bin/bash
# scripts/validate.sh — everything a release must pass before it is prepared (RELEASING.md), in one command.
# Stops at the first failure and names the step. `--needles` also runs the
# rule-loss check from delivery-loop-invariants.md (needle misses advisory — a miss is a
# signal to READ, not proof of loss; a DEAD REFERENCE blocks).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT" || exit 2
NEEDLES=0
case "${1:-}" in '') ;; --needles) NEEDLES=1 ;; *) echo "validate: unknown argument: $1 (only --needles is accepted)" >&2; exit 2 ;; esac
[ $# -le 1 ] || { echo "validate: too many arguments" >&2; exit 2; }
step() { printf '\n== %s ==\n' "$1"; }
fail() { printf '\nvalidate: FAILED at step %s\n' "$1" >&2; exit 1; }
TMP=""; NEEDLES_OUT=""; NEEDLES_PID=""
# The rule-loss check is stopped only while it still runs: once it has ended its number may be reused.
cleanup() {
  [ -n "$NEEDLES_PID" ] && jobs -pr | grep -qx "$NEEDLES_PID" && kill "$NEEDLES_PID" 2>/dev/null
  rm -rf ${TMP:+"$TMP"} ${NEEDLES_OUT:+"$NEEDLES_OUT"}
}
trap cleanup EXIT

# The rule-loss check only reads files and takes about half a minute, so with --needles it starts
# now, beside the steps below, and its result is read and reported last, as before.
if [ "$NEEDLES" = 1 ]; then
  NEEDLES_OUT="$(mktemp)" || { echo "validate: cannot create a temporary file" >&2; exit 2; }
  BLOCK="$(awk '/^## How to actually run this checklist/{f=1} f&&/^```bash/{p=1;next} p&&/^```/{exit} p' skills/review/references/delivery-loop-invariants.md)"
  bash -c "$BLOCK" > "$NEEDLES_OUT" 2>&1 & NEEDLES_PID=$!
fi

step "1/7 marketplace manifest (claude plugin validate .)"
command -v claude >/dev/null 2>&1 || { echo "the claude CLI is not on PATH — install Claude Code, or run scripts/measure-cost.sh --check alone" >&2; fail 1; }
claude plugin validate . || fail 1

step "2/7 skill frontmatter (claude plugin validate ./skills)"
claude plugin validate ./skills || fail 2

step "3/7 plugin manifest (a copy without marketplace.json — the pass the root run skips)"
TMP="$(mktemp -d)"
mkdir "$TMP/plugin" && ( set -o pipefail; tar --exclude=.git -cf - -C "$ROOT" . | tar -xf - -C "$TMP/plugin" ) && rm -f "$TMP/plugin/.claude-plugin/marketplace.json" || fail 3
( cd "$TMP/plugin" && claude plugin validate . ) || fail 3

step "4/7 marketplace invariant (one source, no version on any entry)"
python3 -c "import json;p=json.load(open('.claude-plugin/marketplace.json'))['plugins'];assert len({e['source'] for e in p})==1 and not [e for e in p if 'version' in e]; print('ok')" || fail 4

step "5/7 shell syntax (bash -n under the interpreter the shebangs name — /bin/bash, 3.2 on macOS)"
SH=/bin/bash; [ -x "$SH" ] || SH=bash
for f in hooks/*.sh scripts/*.sh scripts/tests/*.sh skills/*/scripts/*.sh; do
  [ -f "$f" ] || continue
  "$SH" -n "$f" && echo "ok $f" || fail 5
done

step "5b the old config name supportTrain stays out of skill text (scripts/check-train-name.sh)"
bash scripts/check-train-name.sh || fail 5b

step "5c workflow definitions (scripts/check-workflows.py)"
python3 scripts/check-workflows.py || fail 5c

step "5d the release definitions match their source (scripts/build-release-workflows.py --check)"
python3 scripts/build-release-workflows.py --check || fail 5d

step "6/7 script tests (scripts/tests/run.sh)"
bash scripts/tests/run.sh || fail 6

step "7/7 skill-body budgets (scripts/measure-cost.sh --check)"
bash scripts/measure-cost.sh --check || fail 7

if [ "$NEEDLES" = 1 ]; then
  step "needles (misses advisory, dead references blocking): delivery-loop-invariants.md"
  wait "$NEEDLES_PID"; NRC=$?; NEEDLES_PID=""
  OUT="$(cat "$NEEDLES_OUT")" || fail needles-output
  # The check ends with status 0 whatever it finds, so any other status means it broke: say so, never 0 found.
  [ "$NRC" = 0 ] || { printf '%s\n' "$OUT"; echo "needles: the rule-loss check itself failed (status $NRC)"; fail needles-crashed; }
  MISSING="$(printf '%s\n' "$OUT" | grep -c MISSING)"
  DEAD="$(printf '%s\n' "$OUT" | grep -c 'DEAD REFERENCE')"
  printf '%s\n' "$OUT" | grep -E 'MISSING|DEAD REFERENCE'
  echo "needles: $MISSING MISSING line(s)$( [ "$MISSING" -gt 0 ] && echo ' — go and read each one; a miss is not proof of loss' ), $DEAD dead reference(s)"
  [ "$DEAD" -gt 0 ] && fail needles-dead-reference
fi
printf '\nvalidate: all steps passed\n'
