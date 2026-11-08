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
                               (source `compact`, an automatic mid-turn compaction, is ignored)
           UserPromptSubmit -> state "working"; sends `beat` on a state change, when the last send
                               is a minute old, or when the session moved to another checkout; with
                               no record yet (a session that began before the block existed or the
                               plugin was updated) or after an `end`, sends `start`
           Stop             -> state "waiting"; sends `beat` on a state change
           SessionEnd       -> state "ended", sends `end` (PRESENCE_END_REASON = the payload's
                               reason, such as `clear` or `logout`)
           A state change within 30 seconds of the last send is held: the next hook or keeper send
           carries it (a hook compares against the last state REPORTED, so a held change is not lost).
           The record follows the session, not the checkout: a session that moves to a checkout
           without the block keeps reporting under the one it came from, and Stop or SessionEnd is
           never dropped for a session that has a record. The session's process (CLAUDE_PID, else
           the parent of the hook's shell) and its start time are refreshed whenever they change.
  keeper <session>  (detached, one per session, holding the session's keeper lock, which is how a
           hook knows one runs) checks every 10 seconds: it exits once the session has ended, its
           record is gone or the block is removed; when the session's process is gone, or its
           process id now belongs to a process with another start time, it sends `end` (reason
           `gone`) and exits; and it sends `beat` when the last send is `intervalMinutes` old. It
           covers a long turn with no prompt, and a killed session.
  send <event> <session> <at>  (detached) runs the command once, holding the session's send lock so
           reports run one at a time and in order: nothing but `start` is sent after an `end`, and
           a second `end` is not sent. From the repository root, through the shell, at most 20
           seconds, its exit code kept in the record. It exports
           PRESENCE_EVENT (start|beat|end), PRESENCE_STATE, PRESENCE_SESSION_ID, PRESENCE_MACHINE,
           PRESENCE_CHECKOUT, PRESENCE_BRANCH, PRESENCE_ITEM (an item number the branch name carries,
           else empty), PRESENCE_PLUGIN_VERSION, PRESENCE_INTERVAL_MINUTES, PRESENCE_END_REASON,
           PRESENCE_AT (when the hook or keeper queued the report, epoch seconds, so a repository
           can drop a report older than one it already stored), and CLAUDE_CODE_SESSION_ID and CLAUDE_PID so the repository can resolve the session's name.

DEVSTRIDE_PRESENCE_MINUTE (seconds in a keeper minute, default 60) exists for the tests only.
Records: ${XDG_CACHE_HOME:-~/.cache}/devstride-plugin/presence/<session>.json (and the session's
two lock files), owner-only, pruned after 7 days untouched. FAILS OPEN: every hook exits 0 and prints nothing (a prompt hook's stdout would become
context), whatever goes wrong. python3 and the standard library only.
"""
import fcntl
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
PAYLOAD_LIMIT = 4 * 1048576   # a prompt hook's payload carries the whole prompt
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


def env_owner():
    value = os.environ.get("CLAUDE_PID", "")
    return int(value) if value.isdigit() and alive(int(value)) else 0


def owner_pid():
    """The session's Claude Code process: CLAUDE_PID when Claude Code exports it, else the parent of
    the shell that runs this hook. 0 when neither can be found."""
    if env_owner():
        return env_owner()
    try:
        out = subprocess.run(["ps", "-o", "ppid=", "-p", str(os.getppid())], capture_output=True,
                             text=True, timeout=2)
        pid = int(out.stdout.strip())
        return pid if alive(pid) else 0
    except Exception:
        return 0


def started(pid):
    """A process's start time as `ps` prints it, so a reused process id is told apart; "" unknown."""
    try:
        out = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True, timeout=2)
        return out.stdout.strip() if out.returncode == 0 else ""
    except Exception:
        return ""


def lock(sid, kind, block_until_free):
    """An open, flock-held lock file for this session, or None when another process holds it (and
    block_until_free is False). The lock lives as long as the returned descriptor."""
    path = os.path.join(records_dir(), "%s.%s.lock" % (sid, kind))
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX if block_until_free else fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        return None
    os.utime(fd)
    return fd


def keeper_running(sid):
    fd = lock(sid, "keeper", False)
    if fd is None:
        return True
    os.close(fd)
    return False


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


def run_command(sid, record, event, at):
    top = record.get("top")
    settings = block(top) if isinstance(top, str) else None
    if not settings:
        return None
    branch = branch_of(top)
    env = dict(os.environ)
    env.update({
        "PRESENCE_EVENT": event, "PRESENCE_STATE": str(record.get("state") or ""),
        "PRESENCE_SESSION_ID": sid, "PRESENCE_MACHINE": socket.gethostname().split(".")[0],
        "PRESENCE_CHECKOUT": top, "PRESENCE_BRANCH": branch, "PRESENCE_ITEM": item_of(branch),
        "PRESENCE_PLUGIN_VERSION": str(record.get("version") or ""),
        "PRESENCE_INTERVAL_MINUTES": str(settings["intervalMinutes"]),
        "PRESENCE_END_REASON": str(record.get("reason") or "") if event == "end" else "",
        "PRESENCE_AT": str(at), "CLAUDE_CODE_SESSION_ID": sid,
    })
    if record.get("owner"):
        env["CLAUDE_PID"] = str(record["owner"])
    try:
        child = subprocess.Popen(settings["command"], shell=True, cwd=top, env=env, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        try:
            return child.wait(timeout=COMMAND_TIMEOUT)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
            return "timeout"
    except Exception:
        return "error"


def send(event, sid, at):
    """Run the repository's command once for this session, one report at a time, in order."""
    if event not in ("start", "beat", "end"):
        return
    fd = lock(sid, "send", True)
    if fd is None:
        return
    try:
        record = load(sid)
        if not record:
            return
        ended = record.get("state") == "ended"
        if (event == "beat" and ended) or (event == "start" and ended) or (event == "end" and record.get("endSent")):
            return
        code = run_command(sid, record, event, at)
        if code is None:
            return
        latest = load(sid) or record
        latest["last"] = {"event": event, "exit": code, "at": round(time.time(), 3)}
        if event == "end":
            latest["endSent"] = latest.get("state") == "ended"  # a start queued since then re-arms it
        save(sid, latest)
    finally:
        os.close(fd)


def read_payload():
    try:
        payload = json.loads(sys.stdin.read(PAYLOAD_LIMIT) or "{}")
    except Exception:
        return None
    return payload if isinstance(payload, dict) else None


def hook():
    payload = read_payload()
    if not payload:
        return
    event, sid = payload.get("hook_event_name"), payload.get("session_id")
    if event not in STATES or not isinstance(sid, str) or not SESSION_ID.match(sid):
        return
    if event == "SessionStart" and payload.get("source") == "compact":
        return  # an automatic compaction mid-turn: the session is still working
    cwd = payload.get("cwd") if isinstance(payload.get("cwd"), str) else os.getcwd()
    top = repo_top(cwd)
    record = load(sid)
    if not block(top):
        if record and block(record.get("top")):
            top = record["top"]  # moved to a checkout without the block: keep reporting under the old one
        else:
            return
    now = time.time()
    fresh = record is None
    if fresh:
        if event in ("Stop", "SessionEnd"):
            return  # nothing was ever reported for this session
        record = {"schema": 1, "top": top, "state": None, "sent": 0, "owner": 0}
        if event == "SessionStart":
            prune(now)
    moved = not fresh and record.get("top") != top
    previous, sent, state = record.get("state"), record.get("sent") or 0, STATES[event]
    record.update({"top": top, "state": state, "version": running_version() or record.get("version") or ""})
    owner = env_owner() or (owner_pid() if event == "SessionStart" or not alive(record.get("owner")) else 0)
    if owner and owner != record.get("owner"):
        record.update({"owner": owner, "ownerStarted": started(owner)})
    if event == "SessionEnd":
        record["reason"] = str(payload.get("reason") or "")
        verb = "end" if previous != "ended" else None
    elif event == "SessionStart" or fresh or previous == "ended":
        verb = "start"
    elif event == "UserPromptSubmit" and (now - sent >= BEAT_AFTER or moved):
        verb = "beat"
    elif (state != record.get("reported") or moved) and now - sent >= CHANGE_AFTER:
        verb = "beat"
    else:
        verb = None
    if verb:
        record.update({"sent": round(now, 3), "reported": state})
        if verb == "start":
            record["endSent"] = False
    save(sid, record)
    if verb:
        spawn("send", verb, sid, str(int(now)))
    if event in ("SessionStart", "UserPromptSubmit") and record.get("owner") and not keeper_running(sid):
        spawn("keeper", sid)


def keeper(sid):
    fd = lock(sid, "keeper", False)
    if fd is None:
        return  # another keeper runs for this session
    poll = 10 * MINUTE / 60
    while True:
        time.sleep(poll)
        os.utime(fd)
        record = load(sid)
        if not record or record.get("state") == "ended":
            return
        settings = block(record.get("top"))
        if not settings:
            return
        owner, now = record.get("owner"), time.time()
        due = now - (record.get("sent") or 0) >= settings["intervalMinutes"] * MINUTE
        gone = not alive(owner) or (due and record.get("ownerStarted") and started(owner) != record["ownerStarted"])
        if gone:
            record.update({"state": "ended", "reason": "gone", "sent": round(now, 3), "reported": "ended"})
            save(sid, record)
            send("end", sid, int(now))
            return
        if due:
            record.update({"sent": round(now, 3), "reported": record.get("state")})
            save(sid, record)
            send("beat", sid, int(now))


def main(argv):
    try:
        if argv[:1] == ["hook"]:
            hook()
        elif argv[:1] == ["keeper"] and len(argv) == 2 and SESSION_ID.match(argv[1]):
            keeper(argv[1])
        elif argv[:1] == ["send"] and len(argv) == 4 and SESSION_ID.match(argv[2]) and argv[3].isdigit():
            send(argv[1], argv[2], int(argv[3]))
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
