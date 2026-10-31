#!/usr/bin/env python3
"""hooks/session-runtime.py — which devstride plugin a Claude Code session is RUNNING.

`claude plugin list` reads disk, and a session serves the copy it loaded until `/reload-plugins` or a
restart, so after an update the two disagree and nothing in the session says so. Only the plugin's
own hooks receive `CLAUDE_PLUGIN_ROOT` (the loaded copy), and the status-line payload carries no
plugin data, so the loaded copy writes down what it is:

  record   (SessionStart, every source, and every UserPromptSubmit) reads the hook payload on stdin
           and writes ${XDG_CACHE_HOME:-~/.cache}/devstride-plugin/sessions/<session_id>.json =
           {schema: 1, running, root, transcript, at}. Rewritten on every prompt, so the first
           prompt after a reload records what was actually loaded. Records older than 7 days are
           pruned at session start.
  check --session <id> [--repo <dir>]
           prints one JSON line {running, installed, newest, verdict}: `reload` when the session
           runs an older version than the install that applies to this repository, `update` when it
           runs that install and a newer release is published (and the repository does not pin or
           switch off the check), `current` otherwise, `unknown` when there is no record, a
           malformed one, or no single applicable install. A `/reload-plugins` in the transcript
           after the record was written reads as `current` until the next prompt rewrites it, so a
           successful reload never shows a false warning and a failed one shows again.

The status line imports `check` in-process; a repository's tooling runs `check`. Fails open: every
error exits 0 silently (record) or reads as `unknown` (check). python3 and the standard library only.
"""
import json
import os
import re
import secrets
import stat
import sys
import time
from datetime import datetime

SESSION_ID = re.compile(r"^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$")
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
PLUGIN_IDS = ("devstride@devstride", "ds@devstride")
SOURCE = "https://github.com/devstride/claude-plugin"
NEWEST_TTL = 21600            # the session-start check's six hours
KEEP = 7 * 24 * 3600          # session records older than this are pruned
TAIL = 131072                 # the transcript tail read for a reload


def cache_dir():
    return os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "devstride-plugin")


def version_tuple(value):
    return tuple(int(part) for part in value.split("."))


def read_json(path, limit=1048576):
    """A regular file we (or root) own, opened without following a symlink; None on any doubt."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    except OSError:
        return None
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid not in (os.getuid(), 0) or info.st_size > limit:
            return None
        return json.loads(os.read(fd, limit + 1))
    except Exception:
        return None
    finally:
        os.close(fd)


def running_version(root):
    manifest = read_json(os.path.join(os.path.realpath(root), ".claude-plugin", "plugin.json"))
    if not isinstance(manifest, dict) or manifest.get("name") != "devstride":
        return None
    version = manifest.get("version")
    return version if isinstance(version, str) and SEMVER.match(version) else None


def private_dir(path):
    """Create (0700) and vouch for a directory: ours, a real directory, not a symlink."""
    os.makedirs(path, mode=0o700, exist_ok=True)
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise OSError("untrusted directory")
    return path


def write_atomic(directory, name, payload):
    data = (json.dumps(payload, separators=(",", ":"), sort_keys=True) + "\n").encode()
    temporary = os.path.join(directory, ".%s.%s.tmp" % (name, secrets.token_hex(8)))
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)
    os.replace(temporary, os.path.join(directory, name))  # replaces a symlink itself, never its target


def prune(directory, now):
    for name in os.listdir(directory):
        path = os.path.join(directory, name)
        try:
            info = os.lstat(path)
            if stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and now - info.st_mtime > KEEP:
                os.unlink(path)
        except OSError:
            pass


def record():
    try:
        payload = json.loads(sys.stdin.read(65536) or "{}")
        sid = payload.get("session_id") or ""
        root = os.environ.get("CLAUDE_PLUGIN_ROOT") or ""
        if not isinstance(sid, str) or not SESSION_ID.match(sid) or not root:
            return
        running = running_version(root)
        if not running:
            return
        transcript = payload.get("transcript_path")
        directory = private_dir(os.path.join(private_dir(cache_dir()), "sessions"))
        now = time.time()
        write_atomic(directory, sid + ".json", {
            "schema": 1, "running": running, "root": os.path.realpath(root),
            "transcript": transcript if isinstance(transcript, str) else None, "at": round(now, 3),
        })
        if payload.get("hook_event_name") == "SessionStart":
            prune(directory, now)
    except Exception:
        pass


def git_common_dir(start):
    """The repository's shared git directory (the main checkout's .git for every linked worktree),
    found by walking up from `start` and reading `.git` files — no git process."""
    here = os.path.realpath(start)
    while True:
        dot = os.path.join(here, ".git")
        if os.path.isdir(dot):
            return here, os.path.realpath(dot)
        if os.path.isfile(dot):
            with open(dot) as fh:
                line = fh.readline().strip()
            if not line.startswith("gitdir:"):
                return here, None
            gitdir = os.path.normpath(os.path.join(here, line[len("gitdir:"):].strip()))
            common = gitdir
            commondir = os.path.join(gitdir, "commondir")
            if os.path.isfile(commondir):
                with open(commondir) as fh:
                    common = os.path.normpath(os.path.join(gitdir, fh.readline().strip()))
            return here, os.path.realpath(common)
        parent = os.path.dirname(here)
        if parent == here:
            return None, None
        here = parent


def installed_version(repo_common):
    """The one install that applies here: every user/managed row plus every project/local row
    recorded in a checkout of this repository. None when there is not exactly one."""
    registry = read_json(os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"),
                                      "plugins", "installed_plugins.json"), limit=16777216)
    plugins = (registry or {}).get("plugins") if isinstance(registry, dict) else None
    if not isinstance(plugins, dict):
        return None
    applicable = []
    for key in PLUGIN_IDS:
        for row in plugins.get(key) or []:
            if not isinstance(row, dict):
                continue
            scope, project = row.get("scope"), row.get("projectPath")
            if scope in ("user", "managed"):
                applicable.append(row)
            elif scope in ("project", "local") and isinstance(project, str) and repo_common:
                try:
                    if git_common_dir(project)[1] == repo_common:
                        applicable.append(row)
                except OSError:
                    pass
    if len(applicable) != 1:
        return None
    version = applicable[0].get("version")
    return version if isinstance(version, str) and SEMVER.match(version) else None


def newest_version(now):
    value = read_json(os.path.join(cache_dir(), "newest.json"))
    if not isinstance(value, dict) or value.get("schema") != 2 or value.get("source") != SOURCE:
        return None
    newest, fetched = value.get("newest"), value.get("fetchedAt")
    if isinstance(newest, str) and SEMVER.match(newest) and type(fetched) is int and 0 <= now - fetched < NEWEST_TTL:
        return newest
    return None


def updates_wanted(top):
    """False when the repository pins the plugin or switches the update check off."""
    config = read_json(os.path.join(top, ".claude", "ds-config.json")) if top else None
    plugin = config.get("plugin") if isinstance(config, dict) else None
    if not isinstance(plugin, dict):
        return True
    return plugin.get("pin") is None and plugin.get("updateCheck", True) is not False


def reloaded_since(transcript, at):
    """True when the transcript tail holds a `/reload-plugins` run after `at`."""
    if not isinstance(transcript, str) or not transcript:
        return False
    try:
        with open(transcript, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            fh.seek(max(0, fh.tell() - TAIL))
            lines = fh.read().split(b"\n")
    except OSError:
        return False
    for line in lines:
        if b'"reload-plugins"' not in line:
            continue
        try:
            entry = json.loads(line)
            if entry.get("type") != "system" or (entry.get("commandRun") or {}).get("command") != "reload-plugins":
                continue
            when = datetime.fromisoformat(str(entry.get("timestamp")).replace("Z", "+00:00")).timestamp()
        except Exception:
            continue
        if when > at:
            return True
    return False


def check(session, repo=None):
    result = {"running": None, "installed": None, "newest": None, "verdict": "unknown"}
    try:
        if not isinstance(session, str) or not SESSION_ID.match(session):
            return result
        entry = read_json(os.path.join(cache_dir(), "sessions", session + ".json"))
        if not isinstance(entry, dict) or entry.get("schema") != 1:
            return result
        running, at = entry.get("running"), entry.get("at")
        if not isinstance(running, str) or not SEMVER.match(running) or not isinstance(at, (int, float)):
            return result
        result["running"] = running
        top, common = git_common_dir(repo or os.getcwd())
        installed = installed_version(common)
        now = int(time.time())
        result["installed"], result["newest"] = installed, newest_version(now)
        if not installed:
            return result
        if reloaded_since(entry.get("transcript"), at):
            result["verdict"] = "current"
        elif version_tuple(running) < version_tuple(installed):
            result["verdict"] = "reload"
        elif (running == installed and result["newest"] and updates_wanted(top)
              and version_tuple(installed) < version_tuple(result["newest"])):
            result["verdict"] = "update"
        else:
            result["verdict"] = "current"
    except Exception:
        result["verdict"] = "unknown"
    return result


def main(argv):
    if argv[:1] == ["record"]:
        record()
        return 0
    if argv[:1] == ["check"]:
        options = dict(zip(argv[1::2], argv[2::2]))
        print(json.dumps(check(options.get("--session"), options.get("--repo")), sort_keys=True))
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
