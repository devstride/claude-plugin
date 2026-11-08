#!/usr/bin/env python3
"""hooks/presence.py — every running session reports itself through the repository's own command.

A fleet view built from work claims shows only the sessions holding a claim: a session that is
reviewing, fixing, waiting on tests or waiting for its person has no row. This hook gives every
session a presence report, whatever it is doing, through ONE command the consuming repository names
in `.claude/ds-config.json`:

    "presence": { "command": "<the repository's own command>", "intervalMinutes": 5 }

An absent or null block, or a session outside a repository, runs nothing and writes nothing. The
plugin never talks to a tracker itself: what a report means, where it goes and when it expires are
the repository's. The contract: skills/setup/references/session-presence.md.

  hook     (the hook command; the event comes from the payload's hook_event_name)
           SessionStart     -> state "starting", sends `start`, starts this session's keeper
           UserPromptSubmit -> state "working"; sends `beat` on a state change, or when the last
                               send is a minute old; with no record yet (a session that began
                               before the block existed or the plugin was updated) sends `start`
                               and starts the keeper
           Stop             -> state "waiting"; sends `beat` on a state change
           SessionEnd       -> state "ended", sends `end` (PRESENCE_END_REASON = the payload's
                               reason, such as `clear` or `logout`)
           A state change within 30 seconds of the last send is held: the next hook or keeper send
           carries it (a hook compares against the last state REPORTED, so a held change is not lost).
  keeper <session>  (detached, one per session) sleeps `intervalMinutes`, then sends `beat` while
           the session's Claude Code process lives. When that process is gone it sends `end`
           (reason `gone`) and exits; it exits silently once the session has ended, its record is
           gone or the block is removed. It covers a long turn with no prompt, and a killed session.
  send <event> <session>  (detached) runs the command once: from the repository root, through the
           shell, at most 20 seconds, its exit code kept in the record. It exports
           PRESENCE_EVENT (start|beat|end), PRESENCE_STATE, PRESENCE_SESSION_ID, PRESENCE_MACHINE,
           PRESENCE_CHECKOUT, PRESENCE_BRANCH, PRESENCE_ITEM (an item number the branch name carries,
           else empty), PRESENCE_PLUGIN_VERSION, PRESENCE_INTERVAL_MINUTES, PRESENCE_END_REASON,
           and CLAUDE_CODE_SESSION_ID and CLAUDE_PID so the repository can resolve the session's name.

DEVSTRIDE_PRESENCE_MINUTE (seconds in a keeper minute, default 60) exists for the tests only.
Records: ${XDG_CACHE_HOME:-~/.cache}/devstride-plugin/presence/<session>.json, owner-only, pruned
after 7 days. FAILS OPEN: every hook exits 0 and prints nothing (a prompt hook's stdout would become
context), whatever goes wrong. python3 and the standard library only.
"""
import json
import os
import re
import secrets
import signal
import socket
import stat
import subprocess
import sys
import time

SESSION_ID = re.compile(r"^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$")
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
ITEM = re.compile(r"(?:^|[/_.-])(I[0-9]+)(?=$|[/_.-])")
DEFAULT_INTERVAL = 5
BEAT_AFTER = 60          # a prompt re-sends when the last send is this old
CHANGE_AFTER = 30        # a state change within this of the last send waits for the next send
COMMAND_TIMEOUT = 20
KEEP = 7 * 24 * 3600
# Seconds in a keeper minute. Tests shorten it; nothing else sets DEVSTRIDE_PRESENCE_MINUTE.
try:
    MINUTE = max(0.01, float(os.environ.get("DEVSTRIDE_PRESENCE_MINUTE") or 60))
except ValueError:
    MINUTE = 60.0
STATES = {"SessionStart": "starting", "UserPromptSubmit": "working", "Stop": "waiting", "SessionEnd": "ended"}


def cache_dir():
    return os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "devstride-plugin")


def private_dir(path):
    os.makedirs(path, mode=0o700, exist_ok=True)
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise OSError("untrusted directory")
    return path


def records_dir():
    return private_dir(os.path.join(private_dir(cache_dir()), "presence"))


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


def write_atomic(directory, name, payload):
    data = (json.dumps(payload, separators=(",", ":"), sort_keys=True) + "\n").encode()
    temporary = os.path.join(directory, ".%s.%s.tmp" % (name, secrets.token_hex(8)))
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)
    os.replace(temporary, os.path.join(directory, name))


def load(sid):
    record = read_json(os.path.join(records_dir(), sid + ".json"), limit=65536)
    return record if isinstance(record, dict) and record.get("schema") == 1 else None


def save(sid, record):
    write_atomic(records_dir(), sid + ".json", record)


def prune(now):
    directory = records_dir()
    for name in os.listdir(directory):
        path = os.path.join(directory, name)
        try:
            info = os.lstat(path)
            if stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and now - info.st_mtime > KEEP:
                os.unlink(path)
        except OSError:
            pass


def repo_top(start):
    """The checkout's root: the nearest directory holding .git (a directory or a worktree's file)."""
    here = os.path.realpath(start)
    while True:
        if os.path.exists(os.path.join(here, ".git")):
            return here
        parent = os.path.dirname(here)
        if parent == here:
            return None
        here = parent


def block(top):
    """The effective presence block, or None when absent, null or unusable."""
    config = read_json(os.path.join(top, ".claude", "ds-config.json")) if top else None
    value = config.get("presence") if isinstance(config, dict) else None
    if not isinstance(value, dict):
        return None
    command = value.get("command")
    if not isinstance(command, str) or not command.strip():
        return None
    interval = value.get("intervalMinutes", DEFAULT_INTERVAL)
    if isinstance(interval, bool) or not isinstance(interval, int) or not 1 <= interval <= 60:
        interval = DEFAULT_INTERVAL
    return {"command": command, "intervalMinutes": interval}


def running_version():
    root = os.environ.get("CLAUDE_PLUGIN_ROOT") or ""
    manifest = read_json(os.path.join(os.path.realpath(root), ".claude-plugin", "plugin.json")) if root else None
    version = manifest.get("version") if isinstance(manifest, dict) and manifest.get("name") == "devstride" else None
    return version if isinstance(version, str) and SEMVER.match(version) else ""


def alive(pid):
    if not isinstance(pid, int) or pid <= 1:
        return False
    try:
        os.kill(pid, 0)
        return True
    except PermissionError:
        return True
    except OSError:
        return False


def owner_pid():
    """The session's Claude Code process: CLAUDE_PID when Claude Code exports it, else the parent of
    the shell that runs this hook. 0 when neither can be found."""
    value = os.environ.get("CLAUDE_PID", "")
    if value.isdigit() and alive(int(value)):
        return int(value)
    try:
        out = subprocess.run(["ps", "-o", "ppid=", "-p", str(os.getppid())], capture_output=True,
                             text=True, timeout=2)
        pid = int(out.stdout.strip())
        return pid if alive(pid) else 0
    except Exception:
        return 0


def spawn(*args):
    subprocess.Popen([sys.executable, os.path.realpath(__file__)] + list(args), stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True,
                     start_new_session=True)


def branch_of(top):
    try:
        out = subprocess.run(["git", "-C", top, "symbolic-ref", "--short", "-q", "HEAD"],
                             capture_output=True, text=True, timeout=3)
        return out.stdout.strip() if out.returncode == 0 else ""
    except Exception:
        return ""


def item_of(branch):
    match = ITEM.search(branch or "")
    return match.group(1) if match else ""


def send(event, sid):
    """Run the repository's command once for this session; keep its exit code in the record."""
    record = load(sid)
    if not record or event not in ("start", "beat", "end"):
        return
    top = record.get("top")
    settings = block(top) if isinstance(top, str) else None
    if not settings:
        return
    branch = branch_of(top)
    env = dict(os.environ)
    env.update({
        "PRESENCE_EVENT": event, "PRESENCE_STATE": str(record.get("state") or ""),
        "PRESENCE_SESSION_ID": sid, "PRESENCE_MACHINE": socket.gethostname().split(".")[0],
        "PRESENCE_CHECKOUT": top, "PRESENCE_BRANCH": branch, "PRESENCE_ITEM": item_of(branch),
        "PRESENCE_PLUGIN_VERSION": str(record.get("version") or ""),
        "PRESENCE_INTERVAL_MINUTES": str(settings["intervalMinutes"]),
        "PRESENCE_END_REASON": str(record.get("reason") or "") if event == "end" else "",
        "CLAUDE_CODE_SESSION_ID": sid,
    })
    if record.get("owner"):
        env["CLAUDE_PID"] = str(record["owner"])
    code = None
    try:
        child = subprocess.Popen(settings["command"], shell=True, cwd=top, env=env, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        try:
            code = child.wait(timeout=COMMAND_TIMEOUT)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
            code = "timeout"
    except Exception:
        code = "error"
    latest = load(sid) or record
    latest["last"] = {"event": event, "exit": code, "at": round(time.time(), 3)}
    save(sid, latest)


def hook():
    try:
        payload = json.loads(sys.stdin.read(65536) or "{}")
    except Exception:
        return
    if not isinstance(payload, dict):
        return
    event, sid = payload.get("hook_event_name"), payload.get("session_id")
    if event not in STATES or not isinstance(sid, str) or not SESSION_ID.match(sid):
        return
    cwd = payload.get("cwd") if isinstance(payload.get("cwd"), str) else os.getcwd()
    top = repo_top(cwd)
    if not block(top):
        return
    now = time.time()
    record = load(sid)
    state = STATES[event]
    fresh = record is None or record.get("top") != top
    if fresh:
        if event in ("Stop", "SessionEnd"):
            return  # nothing was ever reported for this session here
        record = {"schema": 1, "top": top, "state": None, "sent": 0, "owner": 0, "keeper": 0}
        if event == "SessionStart":
            prune(now)
    previous, sent = record.get("state"), record.get("sent") or 0
    record.update({"state": state, "version": running_version() or record.get("version") or ""})
    if event == "SessionEnd":
        record["reason"] = str(payload.get("reason") or "")
        verb = "end" if previous != "ended" else None
    elif fresh or previous == "ended":
        verb = "start"
    elif event == "UserPromptSubmit" and now - sent >= BEAT_AFTER:
        verb = "beat"
    elif state != record.get("reported") and now - sent >= CHANGE_AFTER:
        verb = "beat"
    else:
        verb = None
    if event in ("SessionStart", "UserPromptSubmit") and not alive(record.get("keeper")):
        record["owner"] = owner_pid()
        keeper = bool(record["owner"])
    else:
        keeper = False
    if verb:
        record.update({"sent": round(now, 3), "reported": state})
    save(sid, record)
    if verb:
        spawn("send", verb, sid)
    if keeper:
        spawn("keeper", sid)


def keeper(sid):
    record = load(sid)
    if not record:
        return
    record["keeper"] = os.getpid()
    save(sid, record)
    while True:
        settings = block(record.get("top"))
        if not settings:
            return
        time.sleep(settings["intervalMinutes"] * MINUTE)
        record = load(sid)
        if not record or record.get("state") == "ended" or record.get("keeper") != os.getpid():
            return
        if not alive(record.get("owner")):
            record.update({"state": "ended", "reason": "gone", "sent": round(time.time(), 3), "reported": "ended"})
            save(sid, record)
            send("end", sid)
            return
        if not block(record.get("top")):
            return
        record.update({"sent": round(time.time(), 3), "reported": record.get("state")})
        save(sid, record)
        send("beat", sid)
        record = load(sid) or record


def main(argv):
    try:
        if argv[:1] == ["hook"]:
            hook()
        elif argv[:1] == ["keeper"] and len(argv) == 2 and SESSION_ID.match(argv[1]):
            keeper(argv[1])
        elif argv[:1] == ["send"] and len(argv) == 3 and SESSION_ID.match(argv[2]):
            send(argv[1], argv[2])
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
