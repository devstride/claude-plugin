#!/bin/bash
# Windows compatibility, checked on macOS and Linux: every shipped Python file imports with the
# Unix-only calls removed (scripts/tests/fixtures/fake-windows.py), and no shipped code uses the
# few constructs that always fail on Windows outside the shared helper (portable.py): a top-level
# `import fcntl`, `shell=True` (cmd.exe there), or a `%-` date format (refused there). The helper's
# own way to end one process (portable.terminate) is checked in both of its halves: the signal it
# sends here, and the command it would run on Windows. The check that runs on a real Windows
# machine is scripts/windows-check.sh.
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
if out=$(python3 - "$ROOT" <<'PY' 2>&1
import os, signal, subprocess, sys
sys.path.insert(0, os.path.join(sys.argv[1], "skills/build-item/scripts"))
import portable

# here: SIGTERM to that one process, which a program may handle; nothing else is started
handles = "import signal, sys, time\nsignal.signal(signal.SIGTERM, lambda *_: sys.exit(7))\nprint('ready', flush=True)\ntime.sleep(60)"
child = subprocess.Popen([sys.executable, "-c", handles], stdout=subprocess.PIPE)
plain = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
try:
    child.stdout.readline()
    assert portable.terminate(child.pid) is True and child.wait(timeout=10) == 7, "a program that handles SIGTERM ends its own way"
    assert portable.terminate(plain.pid) is True and plain.wait(timeout=10) == -signal.SIGTERM, "one that does not is ended by it"
finally:
    for process in (child, plain):
        if process.poll() is None:
            process.kill()
        process.wait()
    child.stdout.close()

real_kill, real_run, sent, ran = os.kill, subprocess.run, [], []
try:
    os.kill = lambda pid, sig: sent.append((pid, sig))
    for never in (0, 1, -1, -4242, True, False, None, "4242", 4242.0, [4242]):
        assert portable.terminate(never) is False, never
    assert sent == [], "no process id but a whole number above 1 is ever signalled"
    assert portable.terminate(4242) is True and sent == [(4242, signal.SIGTERM)], sent

    def gone(pid, sig):
        raise ProcessLookupError()
    os.kill = gone
    assert portable.terminate(4242) is False, "a process that has gone is no request made"

    # on Windows: taskkill ends the process and everything it started; no signal is sent
    def never_signal(pid, sig):
        raise AssertionError("os.kill on Windows")

    class Done:
        returncode = 0

    def run(argv, **options):
        ran.append((argv, options))
        return Done()
    os.kill, subprocess.run, portable.IS_WINDOWS = never_signal, run, True
    assert portable.terminate(4242) is True
    assert ran == [(["taskkill", "/T", "/F", "/PID", "4242"], {"stdout": subprocess.DEVNULL, "stderr": subprocess.DEVNULL,
                                                             "timeout": 5, "creationflags": 0x8000000})], ran
    Done.returncode = 128
    assert portable.terminate(4242) is False, "taskkill found no such process"
    for never in (0, 1, -1, True, None, "4242"):
        assert portable.terminate(never) is False, never
    assert len(ran) == 2, "nor is taskkill run for anything but a whole number above 1"

    def missing(argv, **options):
        raise FileNotFoundError("taskkill")
    subprocess.run = missing
    assert portable.terminate(4242) is False
    # a process's own arguments cannot be read there: no session is taken for an unattended one by them
    platform, sys.platform = sys.platform, "win32"
    try:
        assert portable.arguments(os.getpid()) == [] and portable.arguments(0) == [] and portable.arguments(None) == []
    finally:
        sys.platform = platform
finally:
    os.kill, subprocess.run, portable.IS_WINDOWS = real_kill, real_run, os.name == "nt"
mine = portable.arguments(os.getpid())
assert mine == [] or mine[1:] == ["-", sys.argv[1]], mine   # read whole where this system keeps them
PY
); then ok "(4) portable.terminate asks one process to end: SIGTERM here, taskkill /T /F on Windows, never for a process id of 1 or below or one that is not a whole number; a process's arguments are not read on Windows"
else bad "(4) $out"; fi
out=$(python3 - "$ROOT" <<'PY' 2>&1
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "skills", "build-item", "scripts"))
import portable, reporter_credential as rc
portable.IS_WINDOWS = True
assert rc.folder({"APPDATA": "/appdata", "XDG_CONFIG_HOME": "/xdg"}) == os.path.join("/appdata", "devstride-plugin")
portable.IS_WINDOWS = False
assert rc.folder({"APPDATA": "/appdata", "XDG_CONFIG_HOME": "/xdg"}) == os.path.join("/xdg", "devstride-plugin")
assert rc.folder({"HOME": os.path.expanduser("~")}) == os.path.join(os.path.expanduser("~"), ".config", "devstride-plugin")
PY
)
if [ -z "$out" ]; then ok "(5) the session reporter credential lives under %APPDATA% on Windows, else \$XDG_CONFIG_HOME or ~/.config"
else bad "(5) $out"; fi
exit "$FAIL"
