#!/bin/bash
# scripts/tests/run.sh — run every scripts/tests/*.sh except itself; non-zero if any fails.
#
# The scripts run in parallel, at most PLUGIN_TEST_JOBS at a time (default: the machine's CPU
# count; 1 runs them one at a time). Each runs with a temporary directory of its own (TMPDIR), and
# its output is held until it ends, then printed whole above its PASS or FAIL line, in name order
# however the scripts finish. The largest scripts start first: size tracks run time closely enough
# that the longest ones are not left to start last and hold up the end of the run. The scripts
# named in SERIAL below run after the others, one at a time, with the machine to themselves.
# The last line is always `tests: N ran, M failed`.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; FAILED=0; RAN=0

# Scripts that cannot share the machine, each with its reason. Keep this list short: a script on
# it adds its whole run time to every check.
#   statusline-override.sh: its stand-in status lines never read their input, so on a loaded
#     machine one can exit before the helper has written to it, and the helper then refuses.
#   version-check.sh: case (9) races a busy-looping writer against the hook's moment between
#     taking its backup and replacing the file; on a loaded machine the writer misses it.
#   workflow-runner.sh: it times the secret scan of a 400 KB line against a one-second limit by
#     the wall clock, which side-by-side scripts on a busy machine push past (1.1 to 2.0 seconds).
#   presence.sh: its keeper cases wait on real timers, and on a loaded machine a beat or a state
#     change lands outside the window a case allows.
SERIAL="statusline-override.sh version-check.sh workflow-runner.sh presence.sh"

cpus() {
  local n
  n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null)"
  case "$n" in ''|*[!0-9]*|0) echo 4 ;; *) echo "$n" ;; esac
}
JOBS="${PLUGIN_TEST_JOBS:-$(cpus)}"
case "$JOBS" in ''|*[!0-9]*) JOBS_OK=0 ;; *) JOBS_OK=1; JOBS=$((10#$JOBS)) ;; esac  # 00 is 0, not unlimited
[ "$JOBS_OK" = 1 ] && [ "$JOBS" -ge 1 ] \
  || { echo "run.sh: PLUGIN_TEST_JOBS must be a whole number of at least 1 (got '${PLUGIN_TEST_JOBS:-}')" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/plugin-tests.XXXXXX")" && WORK="$(cd "$WORK" && pwd)" \
  || { echo "run.sh: cannot create a temporary directory" >&2; exit 2; }  # absolute, so a test may cd
XARGS=""
cleanup() { [ -n "$XARGS" ] && kill "$XARGS" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

# One script: its own TMPDIR, its output kept in a file, its exit status written last (renamed
# into place, so a reader never sees a half-written status).
one() {
  local name="$1"; mkdir -p "$WORK/$name.tmp"
  TMPDIR="$WORK/$name.tmp" bash "$DIR/$name" > "$WORK/$name.out" 2>&1 < /dev/null
  echo "$?" > "$WORK/$name.rc.part" && mv "$WORK/$name.rc.part" "$WORK/$name.rc"
}
# Print one finished script: its output, then its PASS or FAIL line.
report() {
  local name="$1" rc
  RAN=$((RAN + 1))
  if [ -s "$WORK/$name.out" ]; then
    cat "$WORK/$name.out"; [ -n "$(tail -c 1 "$WORK/$name.out")" ] && echo  # PASS/FAIL on a line of its own
  fi
  rc="$(cat "$WORK/$name.rc" 2>/dev/null)"
  if [ "$rc" = 0 ]; then echo "PASS $name"; else
    [ -f "$WORK/$name.rc" ] || echo "run.sh: $name did not finish"
    echo "FAIL $name"; FAILED=$((FAILED + 1))
  fi
}

PARALLEL=(); SOLO=()
for t in "$DIR"/*.sh; do
  name="$(basename "$t")"
  [ "$name" = "run.sh" ] && continue
  case " $SERIAL " in *" $name "*) SOLO+=("$name") ;; *) PARALLEL+=("$name") ;; esac
done

if [ "${#PARALLEL[@]}" -gt 0 ]; then
  export WORK DIR; export -f one
  # Start order: largest file first (ties by name). Sizes come from wc, never from ls, whose output a
  # user's colour or quoting settings can change; names travel NUL-separated.
  for name in "${PARALLEL[@]}"; do printf '%s %s\n' "$(($(wc -c < "$DIR/$name")))" "$name"; done \
    | sort -k1,1nr -k2 | cut -d' ' -f2- | tr '\n' '\0' | xargs -0 -P "$JOBS" -I{} bash -c 'one "$1"' _ {} &
  XARGS=$!
  # Print in name order as soon as each script and every one before it have ended.
  for name in "${PARALLEL[@]}"; do
    while [ ! -f "$WORK/$name.rc" ] && kill -0 "$XARGS" 2>/dev/null; do sleep 0.2; done
    report "$name"
  done
  wait "$XARGS" 2>/dev/null; XARGS=""
fi
for name in ${SOLO[@]+"${SOLO[@]}"}; do
  one "$name"; report "$name"
done

echo "tests: $RAN ran, $FAILED failed"
[ "$FAILED" -eq 0 ]
