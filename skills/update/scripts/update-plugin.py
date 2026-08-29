#!/usr/bin/env python3
"""Safely update the exact DevStride installation that loaded this plugin."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import signal
import stat
import subprocess
import sys
import time
from typing import Any, Optional, Union


MAX_OUTPUT = 1024 * 1024
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
SAFE_ID = re.compile(r"^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$")
SCOPES = {"user", "project", "local", "managed"}
CANONICAL_REPO = "devstride/claude-plugin"
TOTAL_DEADLINE: Optional[float] = None


class UpdateProblem(Exception):
    def __init__(self, code: str, *, status: str = "blocked", **fields: Any) -> None:
        super().__init__(code)
        self.code = code
        self.status = status
        self.fields = fields


def emit(payload: dict[str, Any], exit_code: int) -> None:
    print(json.dumps(payload, separators=(",", ":"), sort_keys=True))
    raise SystemExit(exit_code)


def real(path: str | Path) -> str:
    return os.path.realpath(os.fspath(path))


def semver(value: str) -> tuple[int, int, int]:
    if not SEMVER.fullmatch(value):
        raise UpdateProblem("invalid-version", value=value)
    return tuple(int(part) for part in value.split("."))  # type: ignore[return-value]


def safe_json_file(
    path: Path, label: str, *, within: Optional[Union[str, Path]] = None
) -> Any:
    allowed = real(within) if within is not None else None
    parent = real(path.parent)
    if allowed is not None and os.path.commonpath((allowed, parent)) != allowed:
        raise UpdateProblem(f"{label}-unsafe")
    try:
        dir_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError as exc:
        raise UpdateProblem(f"{label}-unreadable") from exc
    try:
        before = os.stat(path.name, dir_fd=dir_fd, follow_symlinks=False)
        flags = os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW
        fd = os.open(path.name, flags, dir_fd=dir_fd)
    except OSError as exc:
        os.close(dir_fd)
        raise UpdateProblem(f"{label}-missing") from exc
    try:
        after = os.fstat(fd)
        identity = lambda value: (
            value.st_dev,
            value.st_ino,
            value.st_size,
            value.st_mtime_ns,
            value.st_ctime_ns,
            value.st_mode,
            value.st_uid,
            value.st_nlink,
        )
        if (
            not stat.S_ISREG(after.st_mode)
            or after.st_uid not in {os.getuid(), 0}
            or after.st_nlink != 1
            or identity(before) != identity(after)
        ):
            raise UpdateProblem(f"{label}-unsafe")
        if after.st_size > MAX_OUTPUT:
            raise UpdateProblem(f"{label}-too-large")
        data = b""
        while len(data) <= MAX_OUTPUT:
            chunk = os.read(fd, min(65536, MAX_OUTPUT + 1 - len(data)))
            if not chunk:
                break
            data += chunk
        final = os.fstat(fd)
        if len(data) > MAX_OUTPUT or identity(after) != identity(final):
            raise UpdateProblem(f"{label}-changed")
    finally:
        os.close(fd)
        os.close(dir_fd)
    try:
        return json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise UpdateProblem(f"{label}-invalid") from exc


def run_command(
    argv: list[str],
    *,
    cwd: str,
    timeout: int,
    extra_env: Optional[dict[str, str]] = None,
) -> tuple[int, bytes, bytes]:
    if TOTAL_DEADLINE is not None:
        timeout = min(timeout, max(0.0, TOTAL_DEADLINE - time.monotonic()))
    if timeout <= 0:
        raise UpdateProblem("update-deadline-exceeded", status="failed", command=argv[:3])
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)
    process: Optional[subprocess.Popen[bytes]] = None
    completed_normally = False
    selector = selectors.DefaultSelector()
    try:
        process = subprocess.Popen(
            argv,
            cwd=cwd,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        assert process.stdout is not None and process.stderr is not None
        selector.register(process.stdout, selectors.EVENT_READ, "out")
        selector.register(process.stderr, selectors.EVENT_READ, "err")
        buffers = {"out": bytearray(), "err": bytearray()}
        deadline = time.monotonic() + timeout
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise UpdateProblem("command-timeout", status="failed", command=argv[:3])
            for key, _ in selector.select(min(remaining, 0.1)):
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                buffers[key.data].extend(chunk)
                if len(buffers[key.data]) > MAX_OUTPUT:
                    raise UpdateProblem(
                        "command-output-too-large", status="failed", command=argv[:3]
                    )
        return_code = process.wait(timeout=max(0.1, deadline - time.monotonic()))
        out, err = bytes(buffers["out"]), bytes(buffers["err"])
        completed_normally = True
    except FileNotFoundError as exc:
        raise UpdateProblem("command-missing", status="failed", command=argv[0]) from exc
    except subprocess.TimeoutExpired as exc:
        raise UpdateProblem("command-timeout", status="failed", command=argv[:3]) from exc
    except OSError as exc:
        raise UpdateProblem("command-start-failed", status="failed", command=argv[0]) from exc
    finally:
        selector.close()
        if process is not None and not completed_normally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                if process.poll() is None:
                    process.kill()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
        if process is not None:
            if process.stdout is not None:
                process.stdout.close()
            if process.stderr is not None:
                process.stderr.close()
    return return_code, out, err


def command_json(argv: list[str], *, cwd: str, timeout: int, label: str) -> Any:
    code, out, _ = run_command(argv, cwd=cwd, timeout=timeout)
    if code != 0:
        raise UpdateProblem(f"{label}-failed", status="failed")
    try:
        return json.loads(out)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise UpdateProblem(f"{label}-invalid", status="failed") from exc


def repository_root(explicit: Optional[str]) -> str:
    candidate = explicit or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    try:
        result = subprocess.run(
            ["git", "-C", candidate, "rev-parse", "--show-toplevel"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=5,
            check=False,
        )
        if result.returncode == 0 and result.stdout.strip():
            return real(result.stdout.decode().strip())
    except (OSError, subprocess.TimeoutExpired, UnicodeDecodeError):
        pass
    return real(candidate)


def read_pin(repo: str) -> Optional[str]:
    path = Path(repo, ".claude", "ds-config.json")
    if not os.path.lexists(path):
        return None
    data = safe_json_file(path, "repository-config", within=repo)
    if not isinstance(data, dict):
        raise UpdateProblem("repository-config-invalid")
    plugin = data.get("plugin") or {}
    if not isinstance(plugin, dict):
        raise UpdateProblem("repository-config-invalid")
    pin = plugin.get("pin")
    if pin is None:
        return None
    if not isinstance(pin, str) or not SEMVER.fullmatch(pin):
        raise UpdateProblem("repository-pin-invalid")
    return pin


def plugin_rows(cwd: str) -> list[dict[str, Any]]:
    data = command_json(
        ["claude", "plugin", "list", "--json"], cwd=cwd, timeout=15, label="plugin-list"
    )
    if not isinstance(data, list) or any(not isinstance(row, dict) for row in data):
        raise UpdateProblem("plugin-list-invalid", status="failed")
    return data


def row_id(row: dict[str, Any]) -> str:
    value = row.get("id") or row.get("name") or ""
    return value if isinstance(value, str) else ""


def is_devstride(row: dict[str, Any]) -> bool:
    plugin_id = row_id(row)
    return SAFE_ID.fullmatch(plugin_id) is not None and plugin_id.split("@", 1)[0] in {
        "devstride",
        "ds",
    }


def row_bound_to_repo(row: dict[str, Any], repo: str) -> bool:
    scope = row.get("scope")
    project = row.get("projectPath")
    return scope in {"project", "local"} and isinstance(project, str) and real(project) == repo


def inspect_install(root: str, repo: str) -> dict[str, Any]:
    manifest = safe_json_file(
        Path(root, ".claude-plugin", "plugin.json"), "running-manifest", within=root
    )
    if not isinstance(manifest, dict) or manifest.get("name") != "devstride":
        raise UpdateProblem("running-manifest-invalid")
    running = manifest.get("version")
    if not isinstance(running, str) or not SEMVER.fullmatch(running):
        raise UpdateProblem("running-version-invalid")

    rows = plugin_rows(repo)
    devstride_rows = [row for row in rows if is_devstride(row)]
    if any(type(row.get("enabled", True)) is not bool for row in devstride_rows):
        raise UpdateProblem("installed-row-invalid")
    root_rows = [
        row
        for row in devstride_rows
        if real(str(row.get("installPath") or "")) == root
    ]
    if any(row.get("enabled", True) is not True for row in root_rows):
        raise UpdateProblem("loaded-install-disabled")
    exact_rows = [row for row in root_rows if row.get("enabled", True) is True]
    if any(
        row.get("scope") in {"project", "local"} and not row_bound_to_repo(row, repo)
        for row in exact_rows
    ):
        raise UpdateProblem("project-install-unbound")

    applicable: list[dict[str, Any]] = []
    for row in rows:
        if not is_devstride(row) or row.get("enabled", True) is not True:
            continue
        scope = row.get("scope")
        if scope in {"user", "managed"} or row_bound_to_repo(row, repo):
            applicable.append(row)
    if len(applicable) > 1:
        candidates = sorted(f"{row_id(row)} ({row.get('scope', 'unknown')})" for row in applicable)
        raise UpdateProblem("multiple-applicable-installs", candidates=candidates)
    if not applicable:
        raise UpdateProblem("loaded-install-not-found")

    row = applicable[0]
    plugin_id = row_id(row)
    scope = row.get("scope")
    install_path = row.get("installPath")
    version = row.get("version")
    if not SAFE_ID.fullmatch(plugin_id) or scope not in SCOPES:
        raise UpdateProblem("installed-row-invalid")
    if not isinstance(install_path, str) or not install_path:
        raise UpdateProblem("installed-row-invalid")
    if not isinstance(version, str) or not SEMVER.fullmatch(version):
        raise UpdateProblem("installed-version-invalid")

    installed_root = real(install_path)
    if installed_root == root:
        resolution = "exact"
    else:
        root_path = Path(root)
        installed_path = Path(installed_root)
        derived = f"{root_path.parent.name}@{root_path.parent.parent.name}"
        same_lineage = real(root_path.parent) == real(installed_path.parent)
        if derived != plugin_id or not same_lineage:
            raise UpdateProblem("loaded-install-not-found")
        resolution = "cache-lineage"

    installed_manifest = safe_json_file(
        Path(installed_root, ".claude-plugin", "plugin.json"),
        "installed-manifest",
        within=installed_root,
    )
    if (
        not isinstance(installed_manifest, dict)
        or installed_manifest.get("name") != "devstride"
        or installed_manifest.get("version") != version
    ):
        raise UpdateProblem("installed-manifest-mismatch")

    project_path = row.get("projectPath") if scope in {"project", "local"} else None
    if scope in {"project", "local"} and not row_bound_to_repo(row, repo):
        raise UpdateProblem("project-install-unbound")
    pin = read_pin(repo)
    fingerprint_input = json.dumps(
        [plugin_id, scope, real(project_path) if isinstance(project_path, str) else None, pin],
        separators=(",", ":"),
    )
    return {
        "status": "ok",
        "code": "installed",
        "runningVersion": running,
        "diskVersion": version,
        "id": plugin_id,
        "scope": scope,
        "installPath": installed_root,
        "marketplace": plugin_id.split("@", 1)[1],
        "projectPath": real(project_path) if isinstance(project_path, str) else None,
        "repoBound": row_bound_to_repo(row, repo),
        "resolution": resolution,
        "pin": pin,
        "fingerprint": hashlib.sha256(fingerprint_input.encode()).hexdigest(),
    }


def marketplace_row(name: str, cwd: str) -> dict[str, Any]:
    data = command_json(
        ["claude", "plugin", "marketplace", "list", "--json"],
        cwd=cwd,
        timeout=15,
        label="marketplace-list",
    )
    if not isinstance(data, list):
        raise UpdateProblem("marketplace-list-invalid", status="failed")
    matches = [row for row in data if isinstance(row, dict) and row.get("name") == name]
    if len(matches) != 1:
        raise UpdateProblem("marketplace-missing" if not matches else "marketplace-ambiguous")
    row = matches[0]
    ref = row.get("ref")
    repo_source = row.get("repo")
    source = row.get("source")
    if (isinstance(ref, str) and ref) or (
        isinstance(repo_source, str) and re.fullmatch(r"[^/@]+/[^/@]+@.+", repo_source)
    ):
        raise UpdateProblem("marketplace-pinned", ref=ref or repo_source)
    if source in {"seed", "managed-seed"}:
        raise UpdateProblem("marketplace-managed")
    if source != "github" or repo_source != CANONICAL_REPO:
        raise UpdateProblem("marketplace-untrusted")
    location = row.get("installLocation")
    if not isinstance(location, str) or not location:
        raise UpdateProblem("marketplace-location-missing")
    return row


def marketplace_target(row: dict[str, Any], entry_name: str) -> str:
    location = Path(str(row["installLocation"]))
    catalog = safe_json_file(
        location / ".claude-plugin" / "marketplace.json",
        "marketplace-catalog",
        within=location,
    )
    if not isinstance(catalog, dict) or not isinstance(catalog.get("plugins"), list):
        raise UpdateProblem("marketplace-catalog-invalid")
    entries = [
        entry
        for entry in catalog["plugins"]
        if isinstance(entry, dict) and entry.get("name") == entry_name
    ]
    if len(entries) != 1 or entries[0].get("source") != "./":
        raise UpdateProblem("marketplace-entry-unsupported")
    manifest = safe_json_file(
        location / ".claude-plugin" / "plugin.json",
        "marketplace-manifest",
        within=location,
    )
    if not isinstance(manifest, dict) or manifest.get("name") != "devstride":
        raise UpdateProblem("marketplace-manifest-invalid")
    version = manifest.get("version")
    if not isinstance(version, str) or not SEMVER.fullmatch(version):
        raise UpdateProblem("marketplace-version-invalid")
    return version


def newest_release(cwd: str) -> dict[str, str]:
    code, out, _ = run_command(
        [
            "git",
            "ls-remote",
            "--tags",
            "https://github.com/devstride/claude-plugin",
            "refs/tags/devstride--v*",
        ],
        cwd=cwd,
        timeout=15,
    )
    direct: dict[str, str] = {}
    peeled: dict[str, str] = {}
    try:
        for raw_line in out.decode("ascii").splitlines():
            oid, ref = raw_line.split()
            if not re.fullmatch(r"[0-9a-f]{40,64}", oid):
                continue
            if ref.endswith("^{}"):
                peeled[ref[:-3]] = oid
            elif re.fullmatch(r"refs/tags/devstride--v[0-9]+\.[0-9]+\.[0-9]+", ref):
                direct[ref] = oid
    except (UnicodeDecodeError, ValueError) as exc:
        raise UpdateProblem("latest-release-unreachable", status="failed") from exc
    if code != 0 or not direct:
        raise UpdateProblem("latest-release-unreachable", status="failed")
    ref = max(direct, key=lambda item: semver(item.rsplit("--v", 1)[1]))
    version = ref.rsplit("--v", 1)[1]
    return {
        "version": version,
        "tag": ref[len("refs/tags/") :],
        "commit": peeled.get(ref, direct[ref]),
    }


def attest_marketplace(row: dict[str, Any], release: dict[str, str], cwd: str) -> None:
    location = real(str(row["installLocation"]))
    checks = (
        (["git", "-C", location, "rev-parse", "--show-toplevel"], "root"),
        (["git", "-C", location, "rev-parse", "HEAD"], "head"),
        (["git", "-C", location, "status", "--porcelain", "--untracked-files=all"], "status"),
    )
    values: dict[str, str] = {}
    for argv, key in checks:
        code, out, _ = run_command(argv, cwd=cwd, timeout=10)
        if code != 0:
            raise UpdateProblem("marketplace-checkout-invalid")
        values[key] = out.decode("utf-8", "replace").strip()
    if real(values["root"]) != location:
        raise UpdateProblem("marketplace-checkout-invalid")
    if values["status"]:
        raise UpdateProblem("marketplace-checkout-dirty")
    if values["head"] != release["commit"]:
        raise UpdateProblem(
            "marketplace-checkout-untagged",
            expectedCommit=release["commit"],
            actualCommit=values["head"],
        )


def tagged_payload(row: dict[str, Any], release: dict[str, str], cwd: str) -> dict[str, tuple[str, str]]:
    location = real(str(row["installLocation"]))
    code, out, _ = run_command(
        ["git", "-C", location, "ls-tree", "-r", "-z", release["commit"]],
        cwd=cwd,
        timeout=10,
    )
    if code != 0:
        raise UpdateProblem("marketplace-tree-unreadable")
    entries: dict[str, tuple[str, str]] = {}
    try:
        for record in out.rstrip(b"\0").split(b"\0"):
            if not record:
                continue
            metadata, raw_path = record.split(b"\t", 1)
            mode, kind, blob = metadata.decode("ascii").split()
            path = raw_path.decode("utf-8")
            parts = Path(path).parts
            if (
                kind != "blob"
                or mode not in {"100644", "100755", "120000"}
                or not re.fullmatch(r"[0-9a-f]{40,64}", blob)
                or not parts
                or Path(path).is_absolute()
                or ".." in parts
                or path in entries
            ):
                raise ValueError
            entries[path] = (mode, blob)
    except (UnicodeDecodeError, ValueError) as exc:
        raise UpdateProblem("marketplace-tree-invalid") from exc
    if not entries:
        raise UpdateProblem("marketplace-tree-invalid")
    return entries


def _verify_installed_payload(root: str, entries: dict[str, tuple[str, str]]) -> None:
    root = real(root)
    try:
        root_stat = os.lstat(root)
    except OSError as exc:
        raise UpdateProblem("installed-payload-missing") from exc
    if not stat.S_ISDIR(root_stat.st_mode) or root_stat.st_uid not in {os.getuid(), 0}:
        raise UpdateProblem("installed-payload-unsafe")

    marker_snapshot: Optional[tuple[int, ...]] = None
    marker_identity = lambda value: (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_uid,
        value.st_nlink,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )
    try:
        root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            opened_root = os.fstat(root_fd)
            if (opened_root.st_dev, opened_root.st_ino) != (root_stat.st_dev, root_stat.st_ino):
                raise UpdateProblem("installed-payload-changed")
            try:
                marker_info = os.stat(".in_use", dir_fd=root_fd, follow_symlinks=False)
            except FileNotFoundError:
                marker_info = None
            if marker_info is not None:
                if not stat.S_ISDIR(marker_info.st_mode) or marker_info.st_uid != os.getuid():
                    raise UpdateProblem("installed-payload-unsafe")
                marker_fd = os.open(
                    ".in_use", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_fd
                )
                try:
                    opened_marker = os.fstat(marker_fd)
                    if marker_identity(marker_info) != marker_identity(opened_marker):
                        raise UpdateProblem("installed-payload-changed")
                    marker_snapshot = marker_identity(opened_marker)
                    for name in os.listdir(marker_fd):
                        info = os.stat(name, dir_fd=marker_fd, follow_symlinks=False)
                        if (
                            not re.fullmatch(r"[0-9]+", name)
                            or not stat.S_ISREG(info.st_mode)
                            or info.st_uid != os.getuid()
                            or info.st_nlink != 1
                            or info.st_size > 4096
                        ):
                            raise UpdateProblem("installed-payload-unsafe")
                        fd = os.open(
                            name,
                            os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW,
                            dir_fd=marker_fd,
                        )
                        try:
                            data = os.read(fd, 4097)
                            final = os.fstat(fd)
                        finally:
                            os.close(fd)
                        if len(data) > 4096 or (final.st_size, final.st_mtime_ns) != (
                            info.st_size,
                            info.st_mtime_ns,
                        ):
                            raise UpdateProblem("installed-payload-changed")
                        try:
                            marker = json.loads(data)
                        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                            raise UpdateProblem("installed-payload-unsafe") from exc
                        if (
                            not isinstance(marker, dict)
                            or set(marker) != {"pid", "procStart"}
                            or type(marker["pid"]) is not int
                            or marker["pid"] != int(name)
                            or not isinstance(marker["procStart"], str)
                            or len(marker["procStart"]) > 128
                        ):
                            raise UpdateProblem("installed-payload-unsafe")
                    if marker_identity(opened_marker) != marker_identity(os.fstat(marker_fd)):
                        raise UpdateProblem("installed-payload-changed")
                finally:
                    os.close(marker_fd)
        finally:
            os.close(root_fd)
    except UpdateProblem:
        raise
    except OSError as exc:
        # Claude creates/removes `.in_use` markers as sessions start and stop. A race is not an
        # integrity verdict: retry once in the wrapper, then fail closed with a useful code.
        raise UpdateProblem("installed-payload-changed") from exc

    actual: set[str] = set()
    def walk_error(error: OSError) -> None:
        raise error
    try:
        for directory, dirs, files in os.walk(root, followlinks=False, onerror=walk_error):
            relative_dir = os.path.relpath(directory, root)
            for name in list(dirs):
                path = name if relative_dir == "." else f"{relative_dir}/{name}"
                if path == ".in_use":
                    dirs.remove(name)
                elif os.path.islink(os.path.join(directory, name)):
                    actual.add(path)
                    dirs.remove(name)
            for name in files:
                path = name if relative_dir == "." else f"{relative_dir}/{name}"
                if path != ".in_use" and not path.startswith(".in_use/"):
                    actual.add(path)
    except OSError as exc:
        raise UpdateProblem("installed-payload-unreadable") from exc
    expected = set(entries)
    if actual != expected:
        raise UpdateProblem(
            "installed-payload-mismatch",
            missing=sorted(expected - actual)[:5],
            extra=sorted(actual - expected)[:5],
        )

    total = 0
    for relative, (mode, expected_blob) in entries.items():
        path = Path(root, relative)
        parent = real(path.parent)
        if os.path.commonpath((root, parent)) != root:
            raise UpdateProblem("installed-payload-unsafe")
        dir_fd = -1
        try:
            dir_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            item = os.stat(path.name, dir_fd=dir_fd, follow_symlinks=False)
        except OSError as exc:
            if dir_fd >= 0:
                os.close(dir_fd)
            raise UpdateProblem("installed-payload-unreadable") from exc
        try:
            if item.st_uid not in {os.getuid(), 0} or item.st_nlink != 1:
                raise UpdateProblem("installed-payload-unsafe")
            if mode == "120000":
                if not stat.S_ISLNK(item.st_mode):
                    raise UpdateProblem("installed-payload-mismatch")
                data = os.readlink(path.name, dir_fd=dir_fd).encode("utf-8")
            else:
                if not stat.S_ISREG(item.st_mode):
                    raise UpdateProblem("installed-payload-mismatch")
                expected_exec = mode == "100755"
                if bool(item.st_mode & 0o111) != expected_exec or item.st_size > 16 * MAX_OUTPUT:
                    raise UpdateProblem("installed-payload-mismatch")
                fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dir_fd)
                try:
                    opened = os.fstat(fd)
                    if (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns) != (
                        item.st_dev,
                        item.st_ino,
                        item.st_size,
                        item.st_mtime_ns,
                    ):
                        raise UpdateProblem("installed-payload-changed")
                    chunks: list[bytes] = []
                    remaining = opened.st_size
                    while remaining:
                        chunk = os.read(fd, min(65536, remaining))
                        if not chunk:
                            raise UpdateProblem("installed-payload-changed")
                        chunks.append(chunk)
                        remaining -= len(chunk)
                    data = b"".join(chunks)
                    final = os.fstat(fd)
                    if (final.st_size, final.st_mtime_ns) != (opened.st_size, opened.st_mtime_ns):
                        raise UpdateProblem("installed-payload-changed")
                finally:
                    os.close(fd)
            total += len(data)
            if total > 64 * MAX_OUTPUT:
                raise UpdateProblem("installed-payload-too-large")
            blob = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
            if blob != expected_blob:
                raise UpdateProblem("installed-payload-mismatch", file=relative)
        finally:
            os.close(dir_fd)

    # Claude can add/remove `.in_use` markers while another session starts or stops. Recheck the
    # directory after the payload proof; if it moved, retry everything instead of ignoring a name
    # whose contents changed after validation.
    try:
        root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            try:
                final_marker = os.stat(".in_use", dir_fd=root_fd, follow_symlinks=False)
            except FileNotFoundError:
                final_snapshot = None
            else:
                final_snapshot = marker_identity(final_marker)
        finally:
            os.close(root_fd)
    except OSError as exc:
        raise UpdateProblem("installed-payload-changed") from exc
    if final_snapshot != marker_snapshot:
        raise UpdateProblem("installed-payload-changed")


def verify_installed_payload(root: str, entries: dict[str, tuple[str, str]]) -> None:
    last: Optional[UpdateProblem] = None
    for attempt in range(2):
        try:
            _verify_installed_payload(root, entries)
            return
        except UpdateProblem as exc:
            last = exc
            if exc.code != "installed-payload-changed" or attempt:
                break
    assert last is not None
    changed = last.code == "installed-payload-changed"
    raise UpdateProblem(
        last.code,
        status="failed",
        retryCommand="/devstride:update" if changed else None,
        safeToReload=False,
        repairRequired=not changed,
        **last.fields,
    ) from last


@contextmanager
def update_lock(info: dict[str, Any]) -> Any:
    del info  # One marketplace checkout is shared by every alias, scope, and repository.
    base = Path(
        os.environ.get("XDG_RUNTIME_DIR")
        or os.environ.get("XDG_STATE_HOME")
        or Path.home() / ".local" / "state"
    )
    try:
        base.mkdir(mode=0o700, parents=True, exist_ok=True)
        base = Path(real(base))
        base_info = base.lstat()
        if not stat.S_ISDIR(base_info.st_mode) or base_info.st_uid != os.getuid():
            raise UpdateProblem("update-lock-unsafe")
        base_fd = os.open(base, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            try:
                os.mkdir("devstride-plugin", 0o700, dir_fd=base_fd)
            except FileExistsError:
                pass
            lock_dir_info = os.stat(
                "devstride-plugin", dir_fd=base_fd, follow_symlinks=False
            )
            if not stat.S_ISDIR(lock_dir_info.st_mode) or lock_dir_info.st_uid != os.getuid():
                raise UpdateProblem("update-lock-unsafe")
            os.chmod("devstride-plugin", 0o700, dir_fd=base_fd, follow_symlinks=False)
        finally:
            os.close(base_fd)
        path = base / "devstride-plugin" / "update.lock"
        fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        current = os.fstat(fd)
        if not stat.S_ISREG(current.st_mode) or current.st_uid != os.getuid() or current.st_nlink != 1:
            raise UpdateProblem("update-lock-unsafe")
        os.fchmod(fd, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as exc:
        if "fd" in locals():
            os.close(fd)
        raise UpdateProblem("update-in-progress") from exc
    except OSError as exc:
        if "fd" in locals():
            os.close(fd)
        raise UpdateProblem("update-lock-unavailable") from exc
    try:
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def same_install(left: dict[str, Any], right: dict[str, Any]) -> bool:
    return all(left.get(key) == right.get(key) for key in ("id", "scope", "projectPath", "pin"))


def contextual(base: dict[str, Any], function: Any, *args: Any, **kwargs: Any) -> Any:
    try:
        return function(*args, **kwargs)
    except UpdateProblem as exc:
        raise UpdateProblem(exc.code, status=exc.status, **{**base, **exc.fields}) from exc


def reinstall_commands(info: dict[str, Any]) -> list[str]:
    return [
        f"claude plugin uninstall {info['id']} --scope {info['scope']} --keep-data",
        f"claude plugin install {info['id']} --scope {info['scope']}",
        "/devstride:update",
    ]


def apply_update_locked(root: str, repo: str, before: dict[str, Any]) -> dict[str, Any]:
    base = {
        "runningVersion": before["runningVersion"],
        "diskBefore": before["diskVersion"],
        "diskAfter": before["diskVersion"],
        "targetVersion": None,
        "id": before["id"],
        "scope": before["scope"],
        "marketplace": before["marketplace"],
        "reloadRequired": before["runningVersion"] != before["diskVersion"],
        "safeToReload": False,
        "repairRequired": False,
        "manualInspectionRequired": False,
        "repairCommands": [],
        "retryCommand": "/devstride:update",
    }
    if before["pin"]:
        raise UpdateProblem("repository-pinned", **base, pin=before["pin"])
    if before["scope"] == "managed":
        raise UpdateProblem("managed-install", **base)

    first_marketplace = contextual(base, marketplace_row, before["marketplace"], repo)
    keep_cache = {"CLAUDE_CODE_PLUGIN_KEEP_MARKETPLACE_ON_FAILURE": "1"}
    refresh = ["claude", "plugin", "marketplace", "update", before["marketplace"]]
    code, _, _ = contextual(
        base, run_command, refresh, cwd=repo, timeout=30, extra_env=keep_cache
    )
    if code != 0:
        raise UpdateProblem("marketplace-refresh-failed", status="failed", **base)

    after_refresh = contextual(base, inspect_install, root, repo)
    if not same_install(before, after_refresh):
        raise UpdateProblem("install-changed-during-update", **base)
    second_marketplace = contextual(base, marketplace_row, before["marketplace"], repo)
    for key in ("name", "source", "repo", "ref", "installLocation"):
        if first_marketplace.get(key) != second_marketplace.get(key):
            raise UpdateProblem("marketplace-changed-during-update", **base)

    release = contextual(base, newest_release, repo)
    contextual(base, attest_marketplace, second_marketplace, release, repo)
    payload = contextual(base, tagged_payload, second_marketplace, release, repo)
    target = contextual(
        base, marketplace_target, second_marketplace, before["id"].split("@", 1)[0]
    )
    published = release["version"]
    base["targetVersion"] = target
    if target != published:
        raise UpdateProblem(
            "marketplace-release-mismatch", **base, publishedVersion=published
        )

    if semver(after_refresh["diskVersion"]) > semver(target):
        base["repairCommands"] = reinstall_commands(before)
        raise UpdateProblem(
            "installed-ahead-of-release",
            **{
                **base,
                "retryCommand": None,
                "safeToReload": False,
                "repairRequired": True,
            },
        )
    if after_refresh["diskVersion"] == target:
        base["repairCommands"] = reinstall_commands(before)
        contextual(base, verify_installed_payload, after_refresh["installPath"], payload)
        base["diskAfter"] = after_refresh["diskVersion"]
        base["reloadRequired"] = before["runningVersion"] != after_refresh["diskVersion"]
        base["safeToReload"] = True
        base["repairCommands"] = []
        return {"status": "current", "code": "already-current", **base}

    update = [
        "claude",
        "plugin",
        "update",
        before["id"],
        "--scope",
        before["scope"],
    ]
    before_mutation = contextual(base, inspect_install, root, repo)
    current_marketplace = contextual(base, marketplace_row, before["marketplace"], repo)
    if not same_install(before, before_mutation) or before_mutation["diskVersion"] != before["diskVersion"]:
        raise UpdateProblem("install-changed-during-update", **base)
    for key in ("name", "source", "repo", "ref", "installLocation"):
        if second_marketplace.get(key) != current_marketplace.get(key):
            raise UpdateProblem("marketplace-changed-during-update", **base)
    contextual(base, attest_marketplace, current_marketplace, release, repo)
    if contextual(
        base, marketplace_target, current_marketplace, before["id"].split("@", 1)[0]
    ) != target:
        raise UpdateProblem("marketplace-changed-during-update", **base)
    update_code, _, _ = contextual(
        base, run_command, update, cwd=repo, timeout=60, extra_env=keep_cache
    )
    try:
        after = inspect_install(root, repo)
    except UpdateProblem as exc:
        raise UpdateProblem(
            "post-update-inspection-failed",
            status="failed",
            **{
                **base,
                "retryCommand": None,
                "safeToReload": False,
                "repairRequired": False,
                "manualInspectionRequired": True,
            },
        ) from exc
    base["diskAfter"] = after["diskVersion"]
    base["reloadRequired"] = before["runningVersion"] != after["diskVersion"]
    if not same_install(before, after):
        raise UpdateProblem(
            "updated-wrong-install",
            status="failed",
            **{
                **base,
                "retryCommand": None,
                "safeToReload": False,
                "repairRequired": False,
                "manualInspectionRequired": True,
            },
        )
    if after["diskVersion"] != target:
        base["repairCommands"] = reinstall_commands(after)
        raise UpdateProblem(
            "update-verification-failed",
            status="failed",
            **{
                **base,
                "retryCommand": None,
                "safeToReload": False,
                "repairRequired": True,
            },
        )
    base["repairCommands"] = reinstall_commands(after)
    contextual(base, verify_installed_payload, after["installPath"], payload)
    base["safeToReload"] = True
    base["repairCommands"] = []
    code_name = "updated-with-cli-warning" if update_code != 0 else "updated"
    return {"status": "updated", "code": code_name, **base}


def apply_update(root: str, repo: str) -> dict[str, Any]:
    initial = inspect_install(root, repo)
    with update_lock(initial):
        before = inspect_install(root, repo)
        if (
            initial["fingerprint"] != before["fingerprint"]
            or initial["diskVersion"] != before["diskVersion"]
        ):
            raise UpdateProblem("install-changed-during-update")
        return apply_update_locked(root, repo, before)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="action", required=True)
    for action in ("inspect", "apply"):
        command = subparsers.add_parser(action)
        command.add_argument("--root", default=os.environ.get("CLAUDE_PLUGIN_ROOT"))
        command.add_argument("--repo")
        command.add_argument("--total-timeout", type=float)
    latest = subparsers.add_parser("latest")
    latest.add_argument("--json", action="store_true")
    args = parser.parse_args()
    if args.action == "latest":
        try:
            release = newest_release(os.getcwd())
        except UpdateProblem:
            raise SystemExit(1)
        print(json.dumps(release, separators=(",", ":"), sort_keys=True) if args.json else release["version"])
        raise SystemExit(0)
    if not args.root:
        emit({"status": "blocked", "code": "plugin-root-missing"}, 3)
    if args.total_timeout is not None:
        if not 1 <= args.total_timeout <= 600:
            emit({"status": "blocked", "code": "invalid-total-timeout"}, 3)
        global TOTAL_DEADLINE
        TOTAL_DEADLINE = time.monotonic() + args.total_timeout
    root = real(args.root)
    repo = repository_root(args.repo)
    try:
        result = inspect_install(root, repo) if args.action == "inspect" else apply_update(root, repo)
    except UpdateProblem as exc:
        emit({"status": exc.status, "code": exc.code, **exc.fields}, 4 if exc.status == "failed" else 3)
    except Exception:
        emit({"status": "failed", "code": "internal-error"}, 4)
    emit(result, 0)


if __name__ == "__main__":
    main()
