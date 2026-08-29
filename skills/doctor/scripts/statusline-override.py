#!/usr/bin/env python3
"""Safely inspect or remove one personal Claude status-line override."""

import argparse
import ctypes
import hashlib
import json
import os
import re
import secrets
import selectors
import signal
import stat
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


MISSING_SHA256 = hashlib.sha256(b"devstride-statusline-override:missing:v1").hexdigest()
SCRIPT_INSPECT_LIMIT = 4096
RENDER_STREAM_LIMIT = 65536
RENDER_TIMEOUT_SECONDS = 3
KILL_WAIT_SECONDS = 1


class Refusal(Exception):
    """A safety precondition was not met; no selected setting may be changed."""


class DuplicateKey(Exception):
    pass


def emit(payload: Dict[str, Any], *, error: bool = False) -> None:
    stream = sys.stderr if error else sys.stdout
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")), file=stream)


def unique_object(pairs: List[Tuple[str, Any]]) -> Dict[str, Any]:
    value: Dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise DuplicateKey(key)
        value[key] = item
    return value


def parse_object(raw: bytes, label: str) -> Dict[str, Any]:
    try:
        text = raw.decode("utf-8")
        value = json.loads(text, object_pairs_hook=unique_object)
    except UnicodeDecodeError as exc:
        raise Refusal(f"{label} is not UTF-8 JSON: {exc}") from exc
    except DuplicateKey as exc:
        raise Refusal(f"{label} contains duplicate JSON key {exc.args[0]!r}") from exc
    except json.JSONDecodeError as exc:
        raise Refusal(f"{label} is not valid JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise Refusal(f"{label} must contain a top-level JSON object")
    return value


def same_identity(left: os.stat_result, right: os.stat_result) -> bool:
    return (
        left.st_dev,
        left.st_ino,
        left.st_mode,
        left.st_uid,
        left.st_size,
        left.st_mtime_ns,
        left.st_ctime_ns,
        left.st_nlink,
    ) == (
        right.st_dev,
        right.st_ino,
        right.st_mode,
        right.st_uid,
        right.st_size,
        right.st_mtime_ns,
        right.st_ctime_ns,
        right.st_nlink,
    )


def same_node(left: os.stat_result, right: os.stat_result) -> bool:
    return (left.st_dev, left.st_ino) == (right.st_dev, right.st_ino)


def read_regular(
    path: Path, label: str, *, personal: bool, missing_ok: bool = False
) -> Optional[Tuple[bytes, Dict[str, Any], os.stat_result]]:
    try:
        before = os.lstat(str(path))
    except FileNotFoundError:
        if missing_ok:
            return None
        raise Refusal(f"cannot inspect {label}: file does not exist")
    except OSError as exc:
        raise Refusal(f"cannot inspect {label}: {exc}") from exc
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise Refusal(f"{label} must be a regular non-symlink file")
    if personal and before.st_uid != os.geteuid():
        raise Refusal(f"{label} is not owned by the current user")
    if personal and before.st_nlink != 1:
        raise Refusal(f"{label} has {before.st_nlink} hard links; refusing an ambiguous rewrite")

    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(str(path), flags)
    except OSError as exc:
        raise Refusal(f"cannot safely open {label}: {exc}") from exc
    try:
        opened = os.fstat(fd)
        if not same_identity(before, opened):
            raise Refusal(f"{label} changed while it was being opened")
        with os.fdopen(fd, "rb") as handle:
            fd = -1
            raw = handle.read()
            after = os.fstat(handle.fileno())
        if not same_identity(opened, after):
            raise Refusal(f"{label} changed while it was being read")
    finally:
        if fd >= 0:
            os.close(fd)
    return raw, parse_object(raw, label), after


def git_root(repository: Path) -> Path:
    try:
        result = subprocess.run(
            ["git", "-C", str(repository), "rev-parse", "--show-toplevel"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=3,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Refusal(f"cannot prove the repository root: {exc}") from exc
    if result.returncode != 0 or not result.stdout.strip():
        raise Refusal("REPOSITORY_ROOT is not a readable git checkout")
    root = Path(result.stdout.strip()).resolve()
    if root != repository:
        raise Refusal(f"REPOSITORY_ROOT must be the git root ({root})")
    return root


def selected_path(args: argparse.Namespace, repository: Path) -> Tuple[str, Path]:
    if args.local is not None:
        return "local", repository / ".claude" / "settings.local.json"

    path = user_settings_path(repository)
    if within(path, repository):
        raise Refusal("the selected user settings file resolves inside the target repository")
    return "user", path


def user_settings_path(repository: Path) -> Path:
    configured = os.environ.get("CLAUDE_CONFIG_DIR")
    if configured:
        config_root = Path(configured).expanduser().resolve()
    else:
        home = os.environ.get("HOME")
        if not home:
            raise Refusal("HOME is not set and CLAUDE_CONFIG_DIR is absent")
        config_root = (Path(home).expanduser() / ".claude").resolve()
    path = config_root / "settings.json"
    if within(path.resolve(), repository):
        raise Refusal("the selected user settings file resolves inside the target repository")
    return path


def require_safe_local_parent(repository: Path) -> None:
    parent = repository / ".claude"
    try:
        metadata = os.lstat(str(parent))
    except FileNotFoundError:
        return
    except OSError as exc:
        raise Refusal(f"cannot inspect repository .claude directory: {exc}") from exc
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise Refusal("repository .claude must be a real directory, not a symlink")
    if parent.resolve() != parent or not within(parent, repository):
        raise Refusal("repository .claude resolves outside the target repository")


def is_ignored(repository: Path, relative: str) -> bool:
    try:
        result = subprocess.run(
            ["git", "-C", str(repository), "check-ignore", "--quiet", "--no-index", "--", relative],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=3,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Refusal(f"cannot check whether {relative} is ignored: {exc}") from exc
    if result.returncode not in (0, 1):
        raise Refusal(f"git check-ignore failed for {relative}")
    return result.returncode == 0


def is_tracked(repository: Path, relative: str) -> bool:
    try:
        result = subprocess.run(
            ["git", "-C", str(repository), "ls-files", "--error-unmatch", "--", relative],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=3,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Refusal(f"cannot check whether {relative} is tracked: {exc}") from exc
    if result.returncode not in (0, 1):
        raise Refusal(f"git ls-files failed for {relative}")
    return result.returncode == 0


def run_git(repository: Path, arguments: List[str], label: str) -> subprocess.CompletedProcess[bytes]:
    try:
        return subprocess.run(
            ["git", "-C", str(repository), *arguments],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=3,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Refusal(f"cannot verify {label}: {exc}") from exc


def require_clean_committed_shared(repository: Path) -> None:
    head = run_git(repository, ["rev-parse", "--verify", "HEAD"], "the shared status-line commit")
    if head.returncode != 0:
        raise Refusal("shared status-line files are not committed in HEAD")
    for relative in (".claude/settings.json", ".claude/statusline.sh"):
        entry = run_git(repository, ["ls-tree", "-z", "HEAD", "--", relative], relative)
        if entry.returncode != 0 or not entry.stdout.endswith(("\t" + relative + "\0").encode()):
            raise Refusal(f"shared {relative} is not committed in HEAD")
        staged = run_git(
            repository, ["diff", "--cached", "--quiet", "HEAD", "--", relative], relative
        )
        if staged.returncode not in (0, 1):
            raise Refusal(f"git could not compare staged {relative} with HEAD")
        if staged.returncode == 1:
            raise Refusal(f"shared {relative} has staged changes; commit or restore it first")
        working = run_git(repository, ["diff", "--quiet", "--", relative], relative)
        if working.returncode not in (0, 1):
            raise Refusal(f"git could not compare working {relative} with the index")
        if working.returncode == 1:
            raise Refusal(f"shared {relative} has uncommitted changes; commit or restore it first")
        if relative.endswith("statusline.sh") and not entry.stdout.startswith(b"100755 "):
            raise Refusal("shared .claude/statusline.sh is not executable in HEAD")


def bounded_script_prefix(path: Path) -> bytes:
    try:
        before = os.lstat(str(path))
    except OSError as exc:
        raise Refusal(f"managed .claude/statusline.sh is unavailable: {exc}") from exc
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise Refusal("managed .claude/statusline.sh must be a regular non-symlink file")
    if before.st_nlink != 1:
        raise Refusal("managed .claude/statusline.sh must have exactly one hard link")
    if not os.access(str(path), os.X_OK):
        raise Refusal("managed .claude/statusline.sh is not executable")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(str(path), flags)
    except OSError as exc:
        raise Refusal(f"cannot safely open managed .claude/statusline.sh: {exc}") from exc
    try:
        opened = os.fstat(fd)
        if not same_identity(before, opened):
            raise Refusal("managed .claude/statusline.sh changed while it was being opened")
        chunks: List[bytes] = []
        remaining = SCRIPT_INSPECT_LIMIT
        while remaining:
            chunk = os.read(fd, remaining)
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        after = os.fstat(fd)
        if not same_identity(opened, after):
            raise Refusal("managed .claude/statusline.sh changed while it was being inspected")
        return b"".join(chunks)
    finally:
        os.close(fd)


def stop_process_group(process: subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except (OSError, ProcessLookupError):
        try:
            process.kill()
        except OSError:
            pass
    for stream in (process.stdin, process.stdout, process.stderr):
        if stream is not None:
            try:
                stream.close()
            except OSError:
                pass
    try:
        process.wait(timeout=KILL_WAIT_SECONDS)
    except subprocess.TimeoutExpired as exc:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except (OSError, ProcessLookupError):
            try:
                process.kill()
            except OSError:
                pass
        try:
            process.wait(timeout=KILL_WAIT_SECONDS)
        except subprocess.TimeoutExpired as second_exc:
            raise Refusal("managed status-line process group could not be stopped safely") from second_exc


def render_statusline(script: Path, repository: Path) -> bytes:
    payload = json.dumps({"workspace": {"current_dir": str(repository)}}).encode("utf-8")
    try:
        process = subprocess.Popen(
            ["bash", str(script)],
            cwd=str(repository),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
    except OSError as exc:
        raise Refusal(f"managed .claude/statusline.sh could not start: {exc}") from exc

    selector = selectors.DefaultSelector()
    buffers: Dict[str, bytearray] = {"stdout": bytearray(), "stderr": bytearray()}
    stopped = False
    try:
        if process.stdin is None or process.stdout is None or process.stderr is None:
            raise Refusal("managed .claude/statusline.sh pipes could not be created")
        try:
            process.stdin.write(payload)
            process.stdin.close()
        except OSError as exc:
            stop_process_group(process)
            stopped = True
            raise Refusal(f"managed .claude/statusline.sh closed its input unexpectedly: {exc}") from exc
        os.set_blocking(process.stdout.fileno(), False)
        os.set_blocking(process.stderr.fileno(), False)
        selector.register(process.stdout, selectors.EVENT_READ, "stdout")
        selector.register(process.stderr, selectors.EVENT_READ, "stderr")
        deadline = time.monotonic() + RENDER_TIMEOUT_SECONDS
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                stop_process_group(process)
                stopped = True
                raise Refusal("managed .claude/statusline.sh did not render within the 3-second safety check")
            for key, _ in selector.select(timeout=min(remaining, 0.1)):
                name = key.data
                try:
                    chunk = os.read(key.fileobj.fileno(), 8192)
                except BlockingIOError:
                    continue
                if not chunk:
                    selector.unregister(key.fileobj)
                    key.fileobj.close()
                    continue
                buffers[name].extend(chunk)
                if len(buffers[name]) > RENDER_STREAM_LIMIT:
                    stop_process_group(process)
                    stopped = True
                    raise Refusal(
                        f"managed .claude/statusline.sh {name} exceeded the 65536-byte safety limit"
                    )
        remaining = max(0.01, deadline - time.monotonic())
        try:
            return_code = process.wait(timeout=remaining)
        except subprocess.TimeoutExpired as exc:
            stop_process_group(process)
            stopped = True
            raise Refusal("managed .claude/statusline.sh did not exit within the 3-second safety check") from exc
        if return_code != 0 or not bytes(buffers["stdout"]).strip():
            raise Refusal("managed .claude/statusline.sh did not render non-empty output")
        return bytes(buffers["stdout"])
    finally:
        selector.close()
        if process.poll() is None and not stopped:
            stop_process_group(process)


def read_optional_settings(path: Path, label: str, *, personal: bool) -> Optional[Dict[str, Any]]:
    result = read_regular(path, label, personal=personal, missing_ok=True)
    return None if result is None else result[1]


def require_hooks_enabled(repository: Path) -> None:
    local_path = repository / ".claude" / "settings.local.json"
    shared_path = repository / ".claude" / "settings.json"
    user_path = user_settings_path(repository)
    sources = (
        ("local", read_optional_settings(local_path, "local settings", personal=True)),
        ("shared project", read_optional_settings(shared_path, "shared project settings", personal=False)),
        ("user", read_optional_settings(user_path, "user settings", personal=True)),
    )
    for source, settings in sources:
        if settings is None or "disableAllHooks" not in settings:
            continue
        value = settings["disableAllHooks"]
        if not isinstance(value, bool):
            raise Refusal(f"{source} disableAllHooks must be true or false before cleanup is safe")
        if value:
            raise Refusal(
                f"effective disableAllHooks:true from {source} settings disables the shared status line"
            )
        return


def require_working_shared_statusline(repository: Path) -> None:
    require_safe_local_parent(repository)
    require_clean_committed_shared(repository)
    shared_path = repository / ".claude" / "settings.json"
    shared_read = read_regular(shared_path, "shared .claude/settings.json", personal=False)
    if shared_read is None:
        raise Refusal("shared .claude/settings.json is missing")
    _, shared, _ = shared_read
    configured = shared.get("statusLine")
    if not isinstance(configured, dict) or configured.get("type") != "command" or configured.get("command") != "bash .claude/statusline.sh":
        raise Refusal("shared .claude/settings.json lacks the canonical statusLine command 'bash .claude/statusline.sh'")

    script = repository / ".claude" / "statusline.sh"
    try:
        prefix = bounded_script_prefix(script).decode("utf-8")
    except UnicodeDecodeError as exc:
        raise Refusal(f"managed .claude/statusline.sh is not UTF-8: {exc}") from exc
    if not re.search(r"^# ds-statusline: managed v[0-9]", prefix, re.MULTILINE):
        raise Refusal(".claude/statusline.sh does not carry the managed status-line marker")
    for relative in (".claude/settings.json", ".claude/statusline.sh"):
        if is_ignored(repository, relative):
            raise Refusal(f"shared {relative} is gitignored")

    render_statusline(script, repository)
    require_hooks_enabled(repository)
    require_clean_committed_shared(repository)


def within(child: Path, parent: Path) -> bool:
    try:
        child.relative_to(parent)
        return True
    except ValueError:
        return False


def open_owned_directory(path: Path, label: str) -> int:
    try:
        before = os.lstat(str(path))
    except OSError as exc:
        raise Refusal(f"cannot inspect {label}: {exc}") from exc
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISDIR(before.st_mode):
        raise Refusal(f"{label} must be a real directory, not a symlink")
    if before.st_uid != os.geteuid():
        raise Refusal(f"{label} is not owned by the current user")

    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(str(path), flags)
    except OSError as exc:
        raise Refusal(f"cannot safely open {label}: {exc}") from exc
    opened = os.fstat(fd)
    if not same_identity(before, opened) or not stat.S_ISDIR(opened.st_mode):
        os.close(fd)
        raise Refusal(f"{label} changed while it was being opened")
    return fd


def open_private_child(parent_fd: int, name: str, label: str) -> int:
    created = False
    try:
        os.mkdir(name, 0o700, dir_fd=parent_fd)
        created = True
    except FileExistsError:
        pass
    except OSError as exc:
        raise Refusal(f"cannot create {label}: {exc}") from exc

    try:
        before = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except OSError as exc:
        raise Refusal(f"cannot inspect {label}: {exc}") from exc
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISDIR(before.st_mode):
        raise Refusal(f"{label} must be a real directory, not a symlink")
    if before.st_uid != os.geteuid():
        raise Refusal(f"{label} is not owned by the current user")

    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(name, flags, dir_fd=parent_fd)
    except OSError as exc:
        raise Refusal(f"cannot safely open {label}: {exc}") from exc
    opened = os.fstat(fd)
    if not same_identity(before, opened) or not stat.S_ISDIR(opened.st_mode):
        os.close(fd)
        raise Refusal(f"{label} changed while it was being opened")
    if opened.st_uid != os.geteuid():
        os.close(fd)
        raise Refusal(f"{label} is not owned by the current user")
    os.fchmod(fd, 0o700)
    if stat.S_IMODE(os.fstat(fd).st_mode) != 0o700:
        os.close(fd)
        raise Refusal(f"{label} could not be made private")
    if created:
        os.fsync(parent_fd)
    return fd


def backup_removed(scope: str, digest: str, value: Any, repository: Path) -> Path:
    state = os.environ.get("XDG_STATE_HOME")
    if state:
        state_root = Path(state).expanduser().resolve()
    else:
        home = os.environ.get("HOME")
        if not home:
            raise Refusal("HOME is not set and XDG_STATE_HOME is absent; cannot create a recovery backup")
        state_root = (Path(home).expanduser() / ".local" / "state").resolve()
    if within(state_root, repository):
        raise Refusal("XDG state resolves inside the repository; recovery backup must stay outside git")

    directory = state_root / "devstride-plugin" / "statusline-overrides"
    root_fd = plugin_fd = directory_fd = -1
    backup_fd = -1
    try:
        state_root.mkdir(parents=True, exist_ok=True)
        root_fd = open_owned_directory(state_root, "XDG state root")
        plugin_fd = open_private_child(root_fd, "devstride-plugin", "plugin state directory")
        directory_fd = open_private_child(
            plugin_fd, "statusline-overrides", "status-line backup directory"
        )
        resolved_directory = directory.resolve(strict=True)
        if within(resolved_directory, repository):
            raise Refusal("recovery backup directory resolves inside the repository")

        prefix = f"{scope}-{digest[:12]}-"
        filename = ""
        for _ in range(32):
            filename = f"{prefix}{secrets.token_hex(8)}.json"
            try:
                backup_fd = os.open(
                    filename,
                    os.O_RDWR | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
                    0o600,
                    dir_fd=directory_fd,
                )
                break
            except FileExistsError:
                continue
        if backup_fd < 0:
            raise OSError("could not allocate a unique backup name")

        content = (json.dumps({"statusLine": value}, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
        with os.fdopen(backup_fd, "w+b") as handle:
            backup_fd = -1
            os.fchmod(handle.fileno(), 0o600)
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
            handle.seek(0)
            written = handle.read()
            written_stat = os.fstat(handle.fileno())
        if (
            not stat.S_ISREG(written_stat.st_mode)
            or written_stat.st_uid != os.geteuid()
            or stat.S_IMODE(written_stat.st_mode) != 0o600
            or written_stat.st_nlink != 1
        ):
            raise OSError("backup permissions, ownership, or file shape failed postcheck")
        if parse_object(written, "recovery backup") != {"statusLine": value}:
            raise OSError("backup content failed postcheck")
        os.fsync(directory_fd)

        backup = directory / filename
        check = os.lstat(str(backup))
        resolved_backup = backup.resolve(strict=True)
        if (
            not same_node(check, written_stat)
            or resolved_backup.parent != resolved_directory
            or within(resolved_backup, repository)
        ):
            raise OSError("backup path escaped its verified state directory")
        return resolved_backup
    except (OSError, Refusal) as exc:
        raise Refusal(f"could not create the private recovery backup: {exc}") from exc
    finally:
        for descriptor in (backup_fd, directory_fd, plugin_fd, root_fd):
            if descriptor >= 0:
                os.close(descriptor)


def read_regular_at(
    directory_fd: int, name: str, label: str, *, personal: bool
) -> Tuple[bytes, Dict[str, Any], os.stat_result]:
    raw, metadata = read_bytes_at(directory_fd, name, label, personal=personal)
    return raw, parse_object(raw, label), metadata


def read_bytes_at(
    directory_fd: int, name: str, label: str, *, personal: bool
) -> Tuple[bytes, os.stat_result]:
    try:
        before = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except OSError as exc:
        raise Refusal(f"cannot inspect {label}: {exc}") from exc
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise Refusal(f"{label} must be a regular non-symlink file")
    if personal and before.st_uid != os.geteuid():
        raise Refusal(f"{label} is not owned by the current user")
    if personal and before.st_nlink != 1:
        raise Refusal(f"{label} has {before.st_nlink} hard links; refusing an ambiguous rewrite")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(name, flags, dir_fd=directory_fd)
    except OSError as exc:
        raise Refusal(f"cannot safely open {label}: {exc}") from exc
    try:
        opened = os.fstat(fd)
        if not same_identity(before, opened):
            raise Refusal(f"{label} changed while it was being opened")
        with os.fdopen(fd, "rb") as handle:
            fd = -1
            raw = handle.read()
            after = os.fstat(handle.fileno())
        if not same_identity(opened, after):
            raise Refusal(f"{label} changed while it was being read")
        return raw, after
    finally:
        if fd >= 0:
            os.close(fd)


def exchange_names(directory_fd: int, left: str, right: str) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "darwin":
        function = getattr(libc, "renameatx_np", None)
    elif sys.platform.startswith("linux"):
        function = getattr(libc, "renameat2", None)
    else:
        function = None
    if function is None:
        raise Refusal("this platform lacks the atomic file exchange required for safe cleanup")
    function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    result = function(
        directory_fd,
        os.fsencode(left),
        directory_fd,
        os.fsencode(right),
        2,
    )
    if result != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def same_exchange_identity(left: os.stat_result, right: os.stat_result) -> bool:
    """Compare identity across rename/exchange, which legitimately changes inode ctime."""
    return (
        left.st_dev,
        left.st_ino,
        left.st_mode,
        left.st_uid,
        left.st_size,
        left.st_mtime_ns,
        left.st_nlink,
    ) == (
        right.st_dev,
        right.st_ino,
        right.st_mode,
        right.st_uid,
        right.st_size,
        right.st_mtime_ns,
        right.st_nlink,
    )


def atomic_compare_exchange_at(
    directory_fd: int,
    name: str,
    expected_raw: bytes,
    expected_metadata: os.stat_result,
    replacement_raw: bytes,
    mode: int,
) -> os.stat_result:
    temporary = ""
    temporary_role = "replacement"
    fd = -1
    for _ in range(32):
        temporary = f".{name}.{secrets.token_hex(8)}"
        try:
            fd = os.open(
                temporary,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
                mode,
                dir_fd=directory_fd,
            )
            break
        except FileExistsError:
            continue
    if fd < 0:
        raise OSError("could not allocate a unique atomic rewrite file")
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as handle:
            fd = -1
            handle.write(replacement_raw)
            handle.flush()
            os.fsync(handle.fileno())
            replacement_metadata = os.fstat(handle.fileno())
        immediate_raw, immediate_metadata = read_bytes_at(
            directory_fd, name, "personal settings immediately before rewrite", personal=True
        )
        if immediate_raw != expected_raw or not same_identity(
            immediate_metadata, expected_metadata
        ):
            raise Refusal(
                "selected personal settings changed before atomic exchange; newer bytes were preserved"
            )
        exchange_names(directory_fd, temporary, name)
        temporary_role = "old"
        previous_raw, previous_metadata = read_bytes_at(
            directory_fd, temporary, "pre-rewrite personal settings", personal=True
        )
        if previous_raw != expected_raw or not same_exchange_identity(
            previous_metadata, expected_metadata
        ):
            current_raw, current_metadata = read_bytes_at(
                directory_fd, name, "current personal settings", personal=True
            )
            if current_raw == replacement_raw and same_exchange_identity(
                current_metadata, replacement_metadata
            ):
                try:
                    exchange_names(directory_fd, temporary, name)
                    temporary_role = "replacement"
                except (OSError, Refusal) as exchange_exc:
                    raise Refusal(
                        f"could not restore pre-rewrite bytes; they remain in {temporary}: {exchange_exc}"
                    ) from exchange_exc
                restored_raw, restored_metadata = read_bytes_at(
                    directory_fd, name, "concurrently changed personal settings", personal=True
                )
                if restored_raw != previous_raw or not same_exchange_identity(
                    restored_metadata, previous_metadata
                ):
                    raise Refusal("pre-rewrite concurrent bytes could not be verified after restoration")
                os.unlink(temporary, dir_fd=directory_fd)
                temporary = ""
                temporary_role = "none"
                os.fsync(directory_fd)
                raise Refusal(
                    "selected personal settings changed immediately before rewrite; concurrent bytes were preserved"
                )
            raise Refusal(
                "personal settings changed during the atomic exchange; the newest path was preserved "
                f"and the pre-exchange bytes remain in {temporary}"
            )
        written_raw, written_metadata = read_bytes_at(
            directory_fd, name, "rewritten personal settings", personal=True
        )
        if written_raw != replacement_raw or not same_exchange_identity(
            written_metadata, replacement_metadata
        ):
            raise Refusal(
                "rewritten personal settings changed before verification; newest bytes were preserved "
                f"and pre-exchange bytes remain in {temporary}"
            )
        os.unlink(temporary, dir_fd=directory_fd)
        temporary = ""
        temporary_role = "none"
        os.fsync(directory_fd)
        return written_metadata
    except (OSError, Refusal) as exc:
        if temporary and temporary_role == "old":
            preserved = temporary
            temporary = ""
            raise Refusal(
                "atomic exchange could not finish safely; the current path was not overwritten again "
                f"and pre-exchange bytes remain in {preserved}: {exc}"
            ) from exc
        raise
    finally:
        if fd >= 0:
            os.close(fd)
        if temporary and temporary_role == "replacement":
            try:
                os.unlink(temporary, dir_fd=directory_fd)
            except FileNotFoundError:
                pass


def main() -> int:
    parser = argparse.ArgumentParser(description="Inspect or safely remove one personal statusLine override.")
    parser.add_argument("action", choices=("inspect", "remove"))
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument("--local", metavar="REPOSITORY_ROOT")
    selection.add_argument("--user", metavar="REPOSITORY_ROOT")
    parser.add_argument("--expect-sha256", metavar="HEX")
    args = parser.parse_args()

    repository_arg = args.local if args.local is not None else args.user
    backup: Optional[Path] = None
    common: Dict[str, Any] = {"action": args.action}
    try:
        repository = git_root(Path(repository_arg).expanduser().resolve())
        scope, path = selected_path(args, repository)
        if scope == "local":
            require_safe_local_parent(repository)
        common.update({"scope": scope, "file": str(path)})

        if args.action == "inspect":
            if args.expect_sha256 is not None:
                raise Refusal("--expect-sha256 is accepted only with remove")
        else:
            if args.expect_sha256 is None:
                raise Refusal("remove requires --expect-sha256 from a fresh inspect")
            if not re.fullmatch(r"[0-9a-f]{64}", args.expect_sha256):
                raise Refusal("--expect-sha256 must be 64 lowercase hexadecimal characters")

        selected = read_regular(
            path, "selected personal settings", personal=True, missing_ok=True
        )
        if args.action == "remove" and scope == "local" and is_tracked(
            repository, ".claude/settings.local.json"
        ):
            raise Refusal(
                ".claude/settings.local.json is tracked by git and is not safely personal"
            )
        if selected is None:
            if args.action == "remove" and args.expect_sha256 != MISSING_SHA256:
                raise Refusal("selected personal settings changed since inspect; inspect again")
            emit({**common, "result": "missing", "sha256": MISSING_SHA256})
            return 0

        raw, settings, metadata = selected
        digest = hashlib.sha256(raw).hexdigest()
        if args.action == "inspect":
            result = "present" if "statusLine" in settings else "absent"
            emit({**common, "result": result, "sha256": digest})
            return 0

        if digest != args.expect_sha256:
            raise Refusal("selected personal settings changed since inspect; inspect again")
        if "statusLine" not in settings:
            emit({**common, "result": "absent", "sha256": digest})
            return 0

        require_working_shared_statusline(repository)
        backup = backup_removed(scope, digest, settings["statusLine"], repository)
        parent_fd = open_owned_directory(path.parent, "selected settings directory")
        try:
            bound_raw, _, bound_metadata = read_regular_at(
                parent_fd, path.name, "selected personal settings", personal=True
            )
            if bound_raw != raw or not same_identity(metadata, bound_metadata):
                raise Refusal("selected personal settings changed during removal; nothing was rewritten")
            require_hooks_enabled(repository)
            require_clean_committed_shared(repository)

            remaining = dict(settings)
            del remaining["statusLine"]
            replacement = (json.dumps(remaining, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
            mode = stat.S_IMODE(metadata.st_mode)
            replaced = False
            replacement_metadata: Optional[os.stat_result] = None
            try:
                replacement_metadata = atomic_compare_exchange_at(
                    parent_fd, path.name, raw, bound_metadata, replacement, mode
                )
                replaced = True
                _, after, after_metadata = read_regular_at(
                    parent_fd, path.name, "selected personal settings", personal=True
                )
                if (
                    after != remaining
                    or "statusLine" in after
                    or stat.S_IMODE(after_metadata.st_mode) != mode
                    or not same_exchange_identity(replacement_metadata, after_metadata)
                ):
                    raise Refusal("postcheck did not preserve the selected settings")
            except (OSError, Refusal) as exc:
                if not replaced or replacement_metadata is None:
                    raise Refusal(f"atomic rewrite failed; original file was not replaced: {exc}") from exc
                try:
                    current_raw, _, current_metadata = read_regular_at(
                        parent_fd, path.name, "current personal settings", personal=True
                    )
                except Refusal as current_exc:
                    raise Refusal(
                        "rewrite postcheck failed; current bytes were preserved because safe restoration "
                        f"could not be proved: {current_exc}"
                    ) from exc
                if current_raw != replacement or not same_exchange_identity(
                    replacement_metadata, current_metadata
                ):
                    raise Refusal(
                        "rewrite postcheck failed; a concurrent change was preserved instead of "
                        "overwriting it with stale original bytes"
                    ) from exc
                try:
                    atomic_compare_exchange_at(
                        parent_fd,
                        path.name,
                        replacement,
                        replacement_metadata,
                        raw,
                        mode,
                    )
                    restored_raw, _, restored_metadata = read_regular_at(
                        parent_fd, path.name, "restored personal settings", personal=True
                    )
                    if restored_raw != raw or stat.S_IMODE(restored_metadata.st_mode) != mode:
                        raise Refusal("original bytes could not be verified after restoration")
                except (OSError, Refusal) as restore_exc:
                    raise Refusal(
                        f"rewrite failed and exact-byte restoration failed: {restore_exc}"
                    ) from exc
                raise Refusal(f"rewrite postcheck failed; original bytes were restored: {exc}") from exc
        finally:
            os.close(parent_fd)

        emit({**common, "result": "removed", "backup": str(backup)})
        return 0
    except Refusal as exc:
        payload = {**common, "result": "refused", "error": str(exc)}
        if backup is not None:
            payload["backup"] = str(backup)
        emit(payload, error=True)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
