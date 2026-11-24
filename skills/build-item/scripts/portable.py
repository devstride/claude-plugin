"""The few operating-system calls the plugin makes that differ between macOS/Linux and Windows,
in one place, standard library only.

Every shipped script that locks a file, checks who owns one, starts or stops a process, or runs a
shell command goes through here, so each works on native Windows (Claude Code with Git for
Windows and Python from python.org) as it does on macOS and Linux. Where Windows has no
equivalent the call degrades safely: a file-mode check passes (Windows has no mode bits to read),
a missing flag is simply left out. Nothing here may raise for a reason other than the operation
itself failing (OSError), so a caller's `except OSError` keeps covering it.

Importers set `sys.dont_write_bytecode = True` before importing this file, so no compiled copy is
ever left in the installed plugin.
"""
import os
import shutil
import subprocess
import sys
import time

IS_WINDOWS = os.name == "nt"

try:
    import fcntl  # macOS and Linux
except ImportError:  # Windows
    fcntl = None
try:
    import msvcrt  # Windows
except ImportError:
    msvcrt = None


def flags(*names):
    """os.open flags by name, leaving out any this system lacks (O_NOFOLLOW, O_NONBLOCK and
    O_DIRECTORY do not exist on Windows), always with O_BINARY where it exists: without it Windows
    opens a descriptor in text mode, turning every \\n written into \\r\\n."""
    value = getattr(os, "O_BINARY", 0)
    for name in names:
        value |= getattr(os, name, 0)
    return value


def uid():
    """This process's user id; 0 on Windows, which is the owner every file reports there, so an
    ownership check `st_uid == uid()` holds for the user's own files on both."""
    return os.getuid() if hasattr(os, "getuid") else 0


def private(mode):
    """Whether a file's mode keeps it private to its owner (no group or other bits). Always true
    on Windows, which reports every file as 0o666 and guards files by their folder's access list."""
    return IS_WINDOWS or not mode & 0o077


def lock(fd, block):
    """Take an exclusive lock on an open file; True when held, False when another process holds it
    and `block` is false. Released when the descriptor is closed or the process ends."""
    if fcntl is not None:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX if block else fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except OSError:
            if block:
                raise
            return False
    os.lseek(fd, 0, os.SEEK_SET)
    while True:
        try:
            msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
            return True
        except OSError:
            if not block:
                return False
            time.sleep(0.05)


def touch(fd, path):
    """Set a file's modified time to now, by descriptor where the system allows it."""
    if os.utime in os.supports_fd:
        os.utime(fd)
    else:
        os.utime(path)


def pread(fd, size, offset):
    """Read `size` bytes at `offset` (os.pread does not exist on Windows)."""
    if hasattr(os, "pread"):
        return os.pread(fd, size, offset)
    os.lseek(fd, offset, os.SEEK_SET)
    return os.read(fd, size)


def replace(source, target):
    """os.replace, retried briefly on Windows, where a file another process has open cannot be
    replaced for a moment."""
    for attempt in range(6):
        try:
            os.replace(source, target)
            return
        except PermissionError:
            if not IS_WINDOWS or attempt == 5:
                raise
            time.sleep(0.02)


# Windows process access, through the system's own library (ctypes is part of the standard library).
_STILL_ACTIVE = 259
_QUERY = 0x1000  # PROCESS_QUERY_LIMITED_INFORMATION


def _kernel32():
    import ctypes
    from ctypes import wintypes
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.OpenProcess.restype = wintypes.HANDLE
    k32.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
    k32.CloseHandle.argtypes = (wintypes.HANDLE,)
    return ctypes, wintypes, k32


def alive(pid):
    """Whether a process with this id is running. On Windows os.kill(pid, 0) would send a Ctrl+C
    to the console instead, so it is asked of the system directly."""
    if not isinstance(pid, int) or pid <= 1:
        return False
    if not IS_WINDOWS:
        try:
            os.kill(pid, 0)
            return True
        except PermissionError:
            return True
        except OSError:
            return False
    try:
        ctypes, wintypes, k32 = _kernel32()
        handle = k32.OpenProcess(_QUERY, False, pid)
        if not handle:
            return ctypes.get_last_error() == 5  # access denied: it exists
        try:
            code = wintypes.DWORD()
            if not k32.GetExitCodeProcess(handle, ctypes.byref(code)):
                return False
            return code.value == _STILL_ACTIVE
        finally:
            k32.CloseHandle(handle)
    except Exception:
        return False


def parent_of(pid):
    """The parent process id of `pid`; 0 when unknown."""
    if not IS_WINDOWS:
        try:
            out = subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)], capture_output=True, text=True, timeout=2)
            return int(out.stdout.strip())
        except Exception:
            return 0
    try:
        ctypes, wintypes, k32 = _kernel32()

        class Entry(ctypes.Structure):
            _fields_ = [("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD),
                        ("th32ProcessID", wintypes.DWORD), ("th32DefaultHeapID", ctypes.c_size_t),
                        ("th32ModuleID", wintypes.DWORD), ("cntThreads", wintypes.DWORD),
                        ("th32ParentProcessID", wintypes.DWORD), ("pcPriClassBase", ctypes.c_long),
                        ("dwFlags", wintypes.DWORD), ("szExeFile", ctypes.c_wchar * 260)]

        k32.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
        snapshot = k32.CreateToolhelp32Snapshot(0x2, 0)  # TH32CS_SNAPPROCESS
        if not snapshot or snapshot == wintypes.HANDLE(-1).value:
            return 0
        try:
            entry = Entry()
            entry.dwSize = ctypes.sizeof(Entry)
            more = k32.Process32FirstW(snapshot, ctypes.byref(entry))
            while more:
                if entry.th32ProcessID == pid:
                    return int(entry.th32ParentProcessID)
                more = k32.Process32NextW(snapshot, ctypes.byref(entry))
        finally:
            k32.CloseHandle(snapshot)
    except Exception:
        pass
    return 0


def started(pid):
    """A process's start time in whole epoch seconds, so a reused process id is told apart; 0 when
    unknown."""
    if not IS_WINDOWS:
        import calendar
        try:
            out = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True,
                                 timeout=1, env=dict(os.environ, LC_ALL="C", TZ="UTC0"))
            return calendar.timegm(time.strptime(" ".join(out.stdout.split()), "%a %b %d %H:%M:%S %Y"))
        except Exception:
            return 0
    try:
        ctypes, wintypes, k32 = _kernel32()
        handle = k32.OpenProcess(_QUERY, False, pid)
        if not handle:
            return 0
        try:
            times = [wintypes.FILETIME() for _ in range(4)]
            if not k32.GetProcessTimes(handle, *[ctypes.byref(t) for t in times]):
                return 0
            ticks = (times[0].dwHighDateTime << 32) | times[0].dwLowDateTime
            return int(ticks // 10000000 - 11644473600)  # 100 ns since 1601 -> seconds since 1970
        finally:
            k32.CloseHandle(handle)
    except Exception:
        return 0


_DETACHED, _NEW_GROUP, _BREAKAWAY, _NO_WINDOW = 0x8, 0x200, 0x1000000, 0x8000000


def spawn_detached(argv, **kwargs):
    """Start a process that outlives this one, in its own session (its own process group, with no
    console, on Windows), and return its Popen."""
    if not IS_WINDOWS:
        return subprocess.Popen(argv, start_new_session=True, **kwargs)
    try:
        return subprocess.Popen(argv, creationflags=_DETACHED | _NEW_GROUP | _BREAKAWAY, **kwargs)
    except OSError:  # the job Claude Code runs in may refuse a breakaway
        return subprocess.Popen(argv, creationflags=_DETACHED | _NEW_GROUP, **kwargs)


def group():
    """Popen arguments that put a bounded child in a group of its own, so kill_tree can stop it
    and everything it started."""
    return {"creationflags": _NEW_GROUP | _NO_WINDOW} if IS_WINDOWS else {"start_new_session": True}


def kill_tree(process):
    """Stop a child started with group() or spawn_detached() and everything it started."""
    try:
        if IS_WINDOWS:
            subprocess.run(["taskkill", "/T", "/F", "/PID", str(process.pid)], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=5, creationflags=_NO_WINDOW)
        else:
            import signal
            os.killpg(process.pid, signal.SIGKILL)
    except Exception:
        pass
    try:
        process.kill()
    except Exception:
        pass


def which(name, skip=None):
    """The full path of a program on the search path, or None. On Windows the current directory is
    never searched: Python's own lookup tries it first there, so a program of that name inside the
    project being worked on would run instead. Each PATHEXT ending is tried; `skip` leaves out the
    search-path directories it returns true for."""
    if not IS_WINDOWS:
        return shutil.which(name)
    endings = [e for e in os.environ.get("PATHEXT", ".COM;.EXE;.BAT;.CMD").split(os.pathsep) if e]
    names = [name] if os.path.splitext(name)[1] else [name + e for e in endings]
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        directory = directory.strip('"')
        if not directory or not os.path.isabs(directory) or (skip and skip(directory)):
            continue
        for candidate in names:
            path = os.path.join(directory, candidate)
            if os.path.isfile(path):
                return path
    return None


def bash():
    """The bash to run a shell command with. On Windows, Git for Windows' bash: the first `bash` on
    the search path that is not the one in the Windows system folder, which starts WSL instead."""
    if not IS_WINDOWS:
        return "bash"
    system = os.path.normcase(os.environ.get("SystemRoot", r"C:\Windows"))
    found = which("bash", skip=lambda d: os.path.normcase(os.path.abspath(d)).startswith(system))
    if found:
        return found
    for root in (os.environ.get("ProgramFiles"), os.environ.get("ProgramW6432"), os.environ.get("LOCALAPPDATA")):
        for tail in (r"Git\bin\bash.exe", r"Programs\Git\bin\bash.exe"):
            candidate = os.path.join(root, tail) if root else ""
            if candidate and os.path.isfile(candidate):
                return candidate
    return "bash"


def shell(command):
    """The argument list that runs a shell command line: /bin/sh on macOS and Linux (what
    shell=True uses), Git for Windows' bash on Windows (where shell=True would run cmd.exe, which
    does not understand a command written for a POSIX shell)."""
    return [bash(), "-c", command] if IS_WINDOWS else ["/bin/sh", "-c", command]


def zone(name):
    """A time zone by name. UTC and GMT need no time-zone database (Windows ships none: any other
    name there needs the `tzdata` package, and its absence raises the usual lookup error)."""
    from datetime import timedelta, timezone
    if name in (None, "", "Z"):
        return timezone.utc
    try:
        from zoneinfo import ZoneInfo
        return ZoneInfo(name)
    except Exception:
        if name in ("UTC", "Etc/UTC", "GMT"):  # the same offset and name the database would give
            return timezone(timedelta(0), "GMT" if name == "GMT" else "UTC")
        raise


def stdin_text(limit):
    """At most `limit` characters of standard input, read as UTF-8 whatever the system's code page
    (on Windows Python would otherwise read it as cp1252, and a prompt holding an arrow or an emoji
    fails). It returns once it has that many, so a huge payload is never held."""
    sys.stdin.reconfigure(encoding="utf-8", errors="replace")
    return sys.stdin.read(limit)
