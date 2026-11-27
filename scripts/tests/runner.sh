#!/bin/bash
# scripts/tests/runner.sh — the script-test runner, scripts/tests/run.sh: it runs the scripts in
# parallel, prints each one's whole output above its PASS or FAIL line in name order, gives each its
# own temporary directory, runs the SERIAL list alone, and keeps its exit status and last line.
# Every case runs a throwaway copy of run.sh beside stub scripts, so this test never starts the real
# test suite (which would run this test again).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; SRC="$ROOT/scripts/tests/run.sh"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)" || { echo "runner.sh: cannot create a temporary directory" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT
unset PLUGIN_TEST_JOBS

# A fresh directory holding the real run.sh; `stub <name> <body>` adds one test script to it.
T=""
fresh() { T="$WORK/$1"; mkdir -p "$T"; cp "$SRC" "$T/run.sh"; }
stub() { printf '#!/bin/bash\n%s\n' "$2" > "$T/$1"; }
run() { OUT="$(cd "$WORK" && env "$@" bash "$T/run.sh" 2>&1)"; RC=$?; LAST="$(printf '%s\n' "$OUT" | tail -n 1)"; }
# The line number of the first line equal to $1 in $OUT (0 when absent).
at() { printf '%s\n' "$OUT" | awk -v l="$1" '$0 == l { print NR; f = 1; exit } END { if (!f) print 0 }'; }

# (1) a failing script is named, its output printed whole above its FAIL line; non-zero exit
fresh one
stub a.sh 'echo "a says hi"'
stub b.sh 'echo "b line one"; echo "b line two" >&2; exit 3'
stub c.sh 'echo "c says hi"'
run PLUGIN_TEST_JOBS=4
B1="$(at 'b line one')"; B2="$(at 'b line two')"; BF="$(at 'FAIL b.sh')"
if [ "$RC" = 1 ] && [ "$LAST" = "tests: 3 ran, 1 failed" ] && [ "$B1" -gt 0 ] && [ "$B2" = $((B1 + 1)) ] && [ "$BF" = $((B2 + 1)) ] \
   && [ "$(at 'PASS a.sh')" -gt 0 ] && [ "$(at 'PASS c.sh')" -gt 0 ]; then
  ok "(1) a failing script is named after its whole output, and the run exits non-zero"
else bad "(1) rc=$RC: $OUT"; fi

# (2) every script passing: exit 0, and run.sh never runs itself
fresh two
stub a.sh 'exit 0'; stub b.sh 'exit 0'
run PLUGIN_TEST_JOBS=2
[ "$RC" = 0 ] && [ "$LAST" = "tests: 2 ran, 0 failed" ] && [ "$(at 'PASS run.sh')" = 0 ] \
  && ok "(2) all passing exits 0 with the closing count, run.sh not among them" || bad "(2) rc=$RC: $OUT"

# (3) name order, however the scripts finish: the first script finishes last
fresh three
stub a.sh 'sleep 1; echo "a done"'
stub b.sh 'echo "b done"'
stub c.sh 'echo "c done"'
run PLUGIN_TEST_JOBS=3
A="$(at 'PASS a.sh')"; B="$(at 'PASS b.sh')"; C="$(at 'PASS c.sh')"
[ "$RC" = 0 ] && [ "$(at 'a done')" -gt 0 ] && [ "$(at 'a done')" = $((A - 1)) ] && [ "$A" -lt "$B" ] && [ "$B" -lt "$C" ] \
  && ok "(3) output comes in name order, each above its own PASS line" || bad "(3) rc=$RC: $OUT"

# (4) the scripts really run at once: each waits for the other to have started
fresh four
stub a.sh ': > "'"$T"'/a.started"; i=0; while [ ! -f "'"$T"'/b.started" ] && [ $i -lt "${WAIT_TICKS:-100}" ]; do sleep 0.1; i=$((i + 1)); done; [ -f "'"$T"'/b.started" ]'
stub b.sh ': > "'"$T"'/b.started"; i=0; while [ ! -f "'"$T"'/a.started" ] && [ $i -lt "${WAIT_TICKS:-100}" ]; do sleep 0.1; i=$((i + 1)); done; [ -f "'"$T"'/a.started" ]'
run PLUGIN_TEST_JOBS=2
[ "$RC" = 0 ] && ok "(4) two scripts run at the same time" || bad "(4) rc=$RC: $OUT"

# (5) PLUGIN_TEST_JOBS=1 runs one at a time: the first of the pair waits for the second in vain
rm -f "$T/a.started" "$T/b.started"
run PLUGIN_TEST_JOBS=1 WAIT_TICKS=10
[ "$RC" = 1 ] && [ "$LAST" = "tests: 2 ran, 1 failed" ] && [ "$(at 'FAIL a.sh')" -gt 0 ] && ok "(5) PLUGIN_TEST_JOBS=1 runs them one at a time" || bad "(5) rc=$RC: $OUT"

# (6) each script has a temporary directory of its own, not the caller's (TMPDIR, which Python and
# every "${TMPDIR:-/tmp}" read honour; macOS's own mktemp ignores it, though each call is unique)
fresh six
stub a.sh 'echo "tmp=$TMPDIR"; [ "$(python3 -c "import tempfile; print(tempfile.gettempdir())")" = "$TMPDIR" ] && echo inside'
stub b.sh 'echo "tmp=$TMPDIR"'
mkdir -p "$WORK/caller"; run PLUGIN_TEST_JOBS=2 TMPDIR="$WORK/caller"
TA="$(printf '%s\n' "$OUT" | sed -n 's/^tmp=//p' | sed -n 1p)"; TB="$(printf '%s\n' "$OUT" | sed -n 's/^tmp=//p' | sed -n 2p)"
if [ "$RC" = 0 ] && [ -n "$TA" ] && [ -n "$TB" ] && [ "$TA" != "$TB" ] && [ "$(at inside)" -gt 0 ] \
   && case "$TA" in "$WORK/caller/"*) true ;; *) false ;; esac && [ -z "$(ls "$WORK/caller")" ]; then
  ok "(6) each script gets its own temporary directory, and nothing is left behind"
else bad "(6) rc=$RC a=$TA b=$TB left=$(ls "$WORK/caller"): $OUT"; fi

# (7) a SERIAL script runs alone, after the others have all ended, and is reported last
fresh seven
sed 's/^SERIAL=".*"$/SERIAL="s.sh"/' "$SRC" > "$T/run.sh"
grep -q '^SERIAL="s.sh"$' "$T/run.sh" || bad "(7) setup: run.sh has no SERIAL line to fill"
for n in a b c; do stub "$n.sh" ': > "'"$T"'/'"$n"'.running"; sleep 0.5; : > "'"$T"'/'"$n"'.ended"; rm -f "'"$T"'/'"$n"'.running"'; done
stub s.sh 'ls "'"$T"'" | grep -q "\.running$" && { echo "not alone"; exit 1; }; [ "$(ls "'"$T"'" | grep -c "\.ended$")" = 3 ] || { echo "too early"; exit 1; }; echo "alone"'
run PLUGIN_TEST_JOBS=4
S="$(at 'PASS s.sh')"; C="$(at 'PASS c.sh')"
[ "$RC" = 0 ] && [ "$(at alone)" = $((S - 1)) ] && [ "$S" -gt "$C" ] && [ "$LAST" = "tests: 4 ran, 0 failed" ] \
  && ok "(7) a script on the SERIAL list runs alone, after the others" || bad "(7) rc=$RC: $OUT"

# (8) a bad PLUGIN_TEST_JOBS is a usage error, and nothing runs
fresh eight
stub a.sh 'echo ran > "'"$T"'/ran"'
for v in 0 00 abc -2; do
  rm -f "$T/ran"; run PLUGIN_TEST_JOBS="$v"
  [ "$RC" = 2 ] && [ ! -f "$T/ran" ] && printf '%s' "$OUT" | grep -q 'PLUGIN_TEST_JOBS must be a whole number' \
    && ok "(8) PLUGIN_TEST_JOBS=$v is refused" || bad "(8) PLUGIN_TEST_JOBS=$v rc=$RC: $OUT"
done

# (10) a script that ends without a status is named as not finished, and a failing SERIAL script
# counts like any other
fresh ten
sed 's/^SERIAL=".*"$/SERIAL="z.sh"/' "$SRC" > "$T/run.sh"
stub k.sh 'echo "k before"; kill -9 $PPID'
stub z.sh 'echo "z says no"; exit 4'
run PLUGIN_TEST_JOBS=2
[ "$RC" = 1 ] && [ "$LAST" = "tests: 2 ran, 2 failed" ] && [ "$(at 'run.sh: k.sh did not finish')" -gt 0 ] \
  && [ "$(at 'FAIL k.sh')" -gt 0 ] && [ "$(at 'z says no')" = $(( $(at 'FAIL z.sh') - 1 )) ] \
  && ok "(10) a script with no status is named as not finished; a failing SERIAL script fails the run" || bad "(10) rc=$RC: $OUT"

# (11) a relative caller TMPDIR still gives each script an absolute one, so a script may change directory
fresh eleven
stub a.sh 'cd / && test -d "$TMPDIR" && echo "still there"; printf "no newline"; exit 2'
mkdir -p "$WORK/rel"; run PLUGIN_TEST_JOBS=1 TMPDIR=rel
[ "$RC" = 1 ] && [ "$(at 'still there')" -gt 0 ] && [ "$(at 'FAIL a.sh')" -gt 0 ] \
  && ok "(11) a relative TMPDIR is made absolute, and FAIL starts its own line after output with no newline" || bad "(11) rc=$RC: $OUT"

# (9) the real SERIAL list names only scripts that exist, each with its reason in a comment
LIST="$(sed -n 's/^SERIAL="\(.*\)"$/\1/p' "$SRC")"
MISSING=""; for n in $LIST; do
  [ -f "$ROOT/scripts/tests/$n" ] && grep -q "^#  *$n: ." "$SRC" || MISSING="$MISSING $n"
done
[ "$(grep -c '^SERIAL=' "$SRC")" = 1 ] && [ -z "$MISSING" ] && ok "(9) every SERIAL entry is a real script with its reason" || bad "(9) missing or unexplained:$MISSING"

exit "$FAIL"
