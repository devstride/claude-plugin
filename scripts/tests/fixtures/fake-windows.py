"""Run a plugin script as if this machine lacked what Windows lacks, so a Unix-only call shows up
on macOS and Linux too.

  python3 fake-windows.py <script.py> [args...]   run the script as __main__
  python3 fake-windows.py --import <file.py>...   only import each file (not as __main__)

Before the script runs: the fcntl module is gone (and a stand-in msvcrt takes its place, locking
through the real one), and os loses getuid, geteuid, getgid, killpg, setsid, pread, O_NOFOLLOW,
O_NONBLOCK, O_DIRECTORY and O_CLOEXEC, and supports nothing by directory descriptor. Python itself
still runs on this system, so this finds a missing name or flag, not a Windows behaviour: the
Windows check in CI covers those.
"""
import importlib.util
import os
import runpy
import sys
import types

sys.dont_write_bytecode = True
import fcntl as _real  # noqa: E402
# Loaded before the stand-in msvcrt below: these choose their Windows half when msvcrt imports.
import asyncio, getpass, selectors, shutil, subprocess, tempfile  # noqa: E401,E402,F401

fake = types.ModuleType("msvcrt")
fake.LK_UNLCK, fake.LK_LOCK, fake.LK_NBLCK, fake.LK_RLCK, fake.LK_NBRLCK = 0, 1, 2, 3, 4


def _locking(fd, mode, size):
    if mode == fake.LK_UNLCK:
        _real.flock(fd, _real.LOCK_UN)
    else:
        _real.flock(fd, _real.LOCK_EX | (_real.LOCK_NB if mode in (fake.LK_NBLCK, fake.LK_NBRLCK) else 0))


fake.locking = _locking
sys.modules["fcntl"] = None
sys.modules["msvcrt"] = fake
for name in ("getuid", "geteuid", "getgid", "getegid", "killpg", "setsid", "pread",
             "O_NOFOLLOW", "O_NONBLOCK", "O_DIRECTORY", "O_CLOEXEC"):
    if hasattr(os, name):
        delattr(os, name)
os.supports_dir_fd = set()
os.supports_follow_symlinks = set()

if sys.argv[1:2] == ["--import"]:
    failed = 0
    for index, path in enumerate(sys.argv[2:]):
        spec = importlib.util.spec_from_file_location("_fake_windows_%d" % index, path)
        module = importlib.util.module_from_spec(spec)
        sys.path.insert(0, os.path.dirname(os.path.abspath(path)))
        try:
            spec.loader.exec_module(module)
        except BaseException as error:  # noqa: BLE001 -- every failure is the finding
            failed += 1
            print("IMPORT FAILED %s: %s: %s" % (path, type(error).__name__, error))
        finally:
            sys.path.pop(0)
    sys.exit(1 if failed else 0)

script = sys.argv[1]
sys.argv = sys.argv[1:]
sys.path.insert(0, os.path.dirname(os.path.abspath(script)))
runpy.run_path(script, run_name="__main__")
