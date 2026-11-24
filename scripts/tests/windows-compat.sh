#!/bin/bash
# Windows compatibility, checked on macOS and Linux: every shipped Python file imports with the
# Unix-only calls removed (scripts/tests/fixtures/fake-windows.py), and no shipped code uses the
# few constructs that always fail on Windows outside the shared helper (portable.py): a top-level
# `import fcntl`, `shell=True` (cmd.exe there), or a `%-` date format (refused there). The check
# that runs on a real Windows machine is scripts/windows-check.sh.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT" || exit 1
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
export PYTHONDONTWRITEBYTECODE=1
if out=$(python3 scripts/tests/fixtures/fake-windows.py --import hooks/*.py skills/*/scripts/*.py 2>&1); then
  ok "(1) every shipped Python file imports without fcntl, getuid, killpg, pread, O_NOFOLLOW, O_NONBLOCK or dir_fd"
else
  bad "(1) $out"
fi
found=$(grep -nE '^import fcntl|^from fcntl|shell=True|strftime\([^)]*%-' hooks/*.py skills/*/scripts/*.py 2>/dev/null \
  | grep -v '^skills/build-item/scripts/portable.py:' | grep -vE ':[0-9]+:\s*#' | grep -v '# .*shell=True' || true)
if [ -z "$found" ]; then ok "(2) no top-level fcntl import, shell=True or %- date format outside portable.py"; else bad "(2) $found"; fi
out=$(cd "$(mktemp -d)" && OSTYPE=msys PATH=/usr/bin:/bin HOME="$PWD" bash -uc '. "$1/hooks/python.sh"; echo "$?:${DEVSTRIDE_PY:+set}"' _ "$ROOT" 2>&1)
case "$out" in 0:set) ok "(3) the launcher finds Python on a Windows-style shell with no cache, under set -u" ;; *) bad "(3) $out" ;; esac
exit "$FAIL"
