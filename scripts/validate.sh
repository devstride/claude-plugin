#!/bin/bash
# scripts/validate.sh — everything RELEASING.md step 0 requires, in one command.
# Stops at the first failure and names the step. `--needles` also runs the
# rule-loss check from delivery-loop-invariants.md (informational, never a
# failure — a miss is a signal to READ, not proof of loss).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT" || exit 2
NEEDLES=0
case "${1:-}" in '') ;; --needles) NEEDLES=1 ;; *) echo "validate: unknown argument: $1 (only --needles is accepted)" >&2; exit 2 ;; esac
[ $# -le 1 ] || { echo "validate: too many arguments" >&2; exit 2; }
step() { printf '\n== %s ==\n' "$1"; }
fail() { printf '\nvalidate: FAILED at step %s\n' "$1" >&2; exit 1; }

step "1/7 marketplace manifest (claude plugin validate .)"
command -v claude >/dev/null 2>&1 || { echo "the claude CLI is not on PATH — install Claude Code, or run scripts/measure-cost.sh --check alone" >&2; fail 1; }
claude plugin validate . || fail 1

step "2/7 skill frontmatter (claude plugin validate ./skills)"
claude plugin validate ./skills || fail 2

step "3/7 plugin manifest (a copy without marketplace.json — the pass the root run skips)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
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

step "6/7 script tests (scripts/tests/run.sh)"
bash scripts/tests/run.sh || fail 6

step "7/7 skill-body budgets (scripts/measure-cost.sh --check)"
bash scripts/measure-cost.sh --check || fail 7

if [ "$NEEDLES" = 1 ]; then
  step "needles (informational): delivery-loop-invariants.md"
  BLOCK="$(awk '/^## How to actually run this checklist/{f=1} f&&/^```bash/{p=1;next} p&&/^```/{exit} p' skills/review/references/delivery-loop-invariants.md)"
  OUT="$(bash -c "$BLOCK" 2>&1)"; MISSING="$(printf '%s\n' "$OUT" | grep -c MISSING)"
  DEAD="$(printf '%s\n' "$OUT" | grep -c 'DEAD REFERENCE')"
  printf '%s\n' "$OUT" | grep -E 'MISSING|DEAD REFERENCE'
  echo "needles: $MISSING MISSING line(s)$( [ "$MISSING" -gt 0 ] && echo ' — go and read each one; a miss is not proof of loss' ), $DEAD dead reference(s)"
  [ "$DEAD" -gt 0 ] && fail needles-dead-reference
fi
printf '\nvalidate: all steps passed\n'
