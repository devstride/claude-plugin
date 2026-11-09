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
                               (source `compact`, the session carrying on after a compaction, is
                               ignored); the session's process and its start time are always re-read
           UserPromptSubmit -> state "working"; sends `beat` on a state change, when the last send
                               is a minute old, or when the session moved to another checkout; with
                               no record yet (a session that began before the block existed or the
                               plugin was updated) or after an `end`, sends `start`
           PostToolUse      -> state "working" (a turn a notification started has no prompt); sends
                               `beat` on a state change; never starts a report
           Stop             -> state "waiting"; sends `beat` on a state change
           SessionEnd       -> state "ended", sends `end` (PRESENCE_END_REASON = the payload's
                               reason, such as `clear` or `logout`)
           Every event but SessionEnd stamps the session's last activity (PRESENCE_ACTIVE_AT).
           PostToolUse, Stop or SessionEnd for a session with no record, or one already ended,
           does nothing.
           A state change within 30 seconds of the last send is held: the next hook or keeper send
           carries it, and the keeper sends it once those 30 seconds pass (both compare against the
           last state REPORTED, so a held change is not lost).
           The record follows the session, not the checkout: a session that moves to a checkout
           without the block keeps reporting under the one it came from, and Stop or SessionEnd is
           never dropped for a session that has a record. The session's process (CLAUDE_PID, else
           the parent of the hook's shell) and its start time are re-read on every start and prompt.
           Every read-modify-write of the record holds the session's state lock (never while the
           command runs), and every queued report takes the next number in the record's sequence.
  keeper <session>  (detached, one per session, holding the session's keeper lock, which is how a
           hook knows one runs) checks every 10 seconds: it exits once the session has ended, its
           record is gone or the block is removed, releasing its lock under the state lock so a
           resume never sees a keeper that is leaving; when the session's process is gone, or its
           process id now belongs to a process with another known start time, it sends `end`
           (reason `gone`) and exits; and it sends `beat` when the last send is `intervalMinutes`
           old or a held change is due. It covers a long turn with no prompt, and a killed session.
  send <event> <state> <session> <record> <sequence> <at>  (detached) runs the command once,
           holding the session's send lock so reports run one at a time, and only for the record
           that queued it (a record recreated since is another) and when its sequence number is
           above the last one sent: a report overtaken by a newer one is dropped, so an old `end`
           never follows a resumed session's `start`. PostToolUse, Stop or SessionEnd from an older process of
           the session, while a newer process holds it, does nothing. From the repository root, through the shell,
           at most 20 seconds, its exit code kept in the record. It exports
           PRESENCE_EVENT (start|beat|end), PRESENCE_STATE, PRESENCE_SESSION_ID, PRESENCE_MACHINE,
           PRESENCE_CHECKOUT, PRESENCE_BRANCH, PRESENCE_ITEM (an item number the branch name carries,
           else empty), PRESENCE_PLUGIN_VERSION, PRESENCE_INTERVAL_MINUTES, PRESENCE_END_REASON,
           PRESENCE_AT (when the hook or keeper queued the report, epoch milliseconds, always later
           than the session's previous report, so a repository can drop one older than it stored),
           PRESENCE_ACTIVE_AT (the session's last activity, epoch milliseconds; empty when unknown), and
           CLAUDE_CODE_SESSION_ID and CLAUDE_PID so the repository can resolve the session's name.

DEVSTRIDE_PRESENCE_MINUTE (seconds in a keeper minute, default 60) exists for the tests only.
Records: ${XDG_CACHE_HOME:-~/.cache}/devstride-plugin/presence/<session>.json (and the session's
three lock files), owner-only; another session's files untouched for 7 days are pruned at a new
session's start, each under its own lock; nothing is created for a session whose
checkout has no block. FAILS OPEN: every hook exits 0 and prints nothing (a prompt hook's stdout would become
context), whatever goes wrong. python3 and the standard library only.
"""
import calendar
import contextlib
import fcntl
import json
import os
import re
import secrets
import signal
import stat
import subprocess
import sys
import time

sys.dont_write_bytecode = True  # never leave compiled files in the installed plugin
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "skills/build-item/scripts"))
import claim_record  # noqa: E402  the one machine naming every claim uses

SESSION_ID = re.compile(r"^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$")
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
ITEM = re.compile(r"(?:^|[/_.-])(I[0-9]+)(?=$|[/_.-])")
DEFAULT_INTERVAL = 5
BEAT_AFTER = 60          # a prompt re-sends when the last send is this old
CHANGE_AFTER = 30        # a state change within this of the last send waits for the next send
COMMAND_TIMEOUT = 20
KEEP = 7 * 24 * 3600
STARTED_SLACK = 5        # seconds a process's reported start time may drift before it is another process
PAYLOAD_LIMIT = 4 * 1048576   # a prompt hook's payload carries the whole prompt
# Seconds in a keeper minute. Tests shorten it; nothing else sets DEVSTRIDE_PRESENCE_MINUTE.
try:
    MINUTE = max(0.01, float(os.environ.get("DEVSTRIDE_PRESENCE_MINUTE") or 60))
except ValueError:
    MINUTE = 60.0
STATES = {"SessionStart": "starting", "UserPromptSubmit": "working", "PostToolUse": "working", "Stop": "waiting",
          "SessionEnd": "ended"}
EVENTS = ("start", "beat", "end")
LATER = ("PostToolUse", "Stop", "SessionEnd")  # events that only update a session already reported


def cache_dir():
    return os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "devstride-plugin")


def private_dir(path):
    os.makedirs(path, mode=0o700, exist_ok=True)
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise OSError("untrusted directory")
    return path


def records_path():
    return os.path.join(cache_dir(), "presence")


def records_dir():
    """The records directory, created owner-only when missing: only once a report is due."""
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
    """The session's record, or None; read-only, so it never creates a directory."""
    record = read_json(os.path.join(records_path(), sid + ".json"), limit=65536)
    return record if isinstance(record, dict) and record.get("schema") == 1 else None


def save(sid, record):
    write_atomic(records_dir(), sid + ".json", record)


def stale(path, now):
    try:
        info = os.lstat(path)
    except OSError:
        return False
    return stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and now - info.st_mtime > KEEP


def prune(own, now):
    """Remove other sessions' files untouched for KEEP. A record or lock goes only while its lock is
    held and it is still stale, so a session that comes back at that moment keeps its files."""
    directory = records_path()
    # records before locks: pruning a record takes its state lock, which would recreate a lock pruned first
    for name in sorted(os.listdir(directory), key=lambda n: not n.endswith(".json")):
        path = os.path.join(directory, name)
        if not stale(path, now):
            continue
        try:
            if name.startswith("."):
                os.unlink(path)  # a temporary file left by a killed writer
                continue
            if name.endswith(".lock"):
                sid, kind = name[:-5].rsplit(".", 1)
            elif name.endswith(".json"):
                sid, kind = name[:-5], "state"
            else:
                continue
            if sid == own or not SESSION_ID.match(sid) or kind not in ("state", "send", "keeper"):
                continue
            fd = lock(sid, kind, False, touch=False)
            if fd is None:
                continue
            try:
                if stale(path, now):
                    os.unlink(path)
            finally:
                os.close(fd)
        except (OSError, ValueError):
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
    """A process's start time in epoch seconds, so a reused process id is told apart; 0 unknown.
    Printed in UTC, so a long-lived keeper and a fresh hook read it alike whatever the zone."""
    try:
        out = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True,
                             timeout=1, env=dict(os.environ, LC_ALL="C", TZ="UTC0"))
        return calendar.timegm(time.strptime(" ".join(out.stdout.split()), "%a %b %d %H:%M:%S %Y"))
    except Exception:
        return 0


def lock(sid, kind, block_until_free, touch=True):
    """An open, flock-held lock file for this session, or None when another process holds it (and
    block_until_free is False). The lock lives as long as the returned descriptor. A lock whose file
    was unlinked while we waited is a lock on nothing, so it is taken again on the file now there."""
    path = os.path.join(records_dir(), "%s.%s.lock" % (sid, kind))
    for _ in range(5):
        fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX if block_until_free else fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(fd)
            return None
        try:
            same = os.fstat(fd).st_ino == os.lstat(path).st_ino
        except OSError:
            same = False
        if same:
            if touch:
                os.utime(fd)
            return fd
        os.close(fd)
    return None


@contextlib.contextmanager
def state_lock(sid):
    """Held around every read-modify-write of the record, never while the command runs."""
    fd = lock(sid, "state", True)
    if fd is None:
        raise OSError("state lock")
    try:
        yield
    finally:
        os.close(fd)


def queue(record, now):
    """Mark a report as queued now (the state lock is held): its sequence number, and its time in
    milliseconds, always later than the session's previous report."""
    sequence = int(record.get("queued") or 0) + 1
    at = max(int(now * 1000), int(record.get("at") or 0) + 1)
    record.update({"queued": sequence, "at": at, "sent": round(now, 3), "reported": record.get("state")})
    return sequence, at


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


def active_at(record):
    value = record.get("activeAt")
    return str(value) if isinstance(value, int) and not isinstance(value, bool) and value > 0 else ""


def item_of(branch):
    match = ITEM.search(branch or "")
    return match.group(1) if match else ""


def run_command(sid, record, event, state, at):
    top = record.get("top")
    settings = block(top) if isinstance(top, str) else None
    if not settings:
        return None
    branch = branch_of(top)
    env = dict(os.environ)
    env.update({
        "PRESENCE_EVENT": event, "PRESENCE_STATE": state,
        "PRESENCE_SESSION_ID": sid, "PRESENCE_MACHINE": claim_record.machine_name(),
        "PRESENCE_CHECKOUT": top, "PRESENCE_BRANCH": branch, "PRESENCE_ITEM": item_of(branch),
        "PRESENCE_PLUGIN_VERSION": str(record.get("version") or ""),
        "PRESENCE_INTERVAL_MINUTES": str(settings["intervalMinutes"]),
        "PRESENCE_END_REASON": str(record.get("reason") or "") if event == "end" else "",
        "PRESENCE_AT": str(at), "PRESENCE_ACTIVE_AT": active_at(record), "CLAUDE_CODE_SESSION_ID": sid,
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


def send(event, state, sid, incarnation, sequence, at):
    """Run the repository's command once for this session: one report at a time, only for the record
    that queued it, and only when no newer report has already been sent."""
    if event not in EVENTS or state not in STATES.values():
        return
    fd = lock(sid, "send", True)
    if fd is None:
        return
    try:
        with state_lock(sid):
            record = load(sid)
            if not record or record.get("id") != incarnation or sequence <= int(record.get("done") or 0):
                return  # the record was replaced, or a newer report for this session already ran
        code = run_command(sid, record, event, state, at)
        with state_lock(sid):
            latest = load(sid)
            if latest and latest.get("id") == incarnation:  # never recreate a record removed meanwhile
                latest["done"] = max(sequence, int(latest.get("done") or 0))
                if code is not None:
                    latest["last"] = {"event": event, "exit": code, "at": round(time.time(), 3)}
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
        return  # the session carries on after a compaction
    cwd = payload.get("cwd") if isinstance(payload.get("cwd"), str) else os.getcwd()
    top = repo_top(cwd)
    here = block(top)
    peek = load(sid)
    if not here and not (peek and block(peek.get("top"))):
        return  # nothing to report, and nothing written
    if event in LATER and (peek is None or peek.get("state") == "ended"):
        return  # never reported here, or already ended
    mine = int(os.environ["CLAUDE_PID"]) if os.environ.get("CLAUDE_PID", "").isdigit() else 0
    # every `ps` runs here, before the state lock is taken
    owner = owner_pid() if event in ("SessionStart", "UserPromptSubmit") else 0
    owner_started = started(owner) if owner else 0
    with state_lock(sid):
        now = time.time()
        record = load(sid)
        if not here:
            if not (record and block(record.get("top"))):
                return
            top = record["top"]  # moved to a checkout without the block: keep reporting under the old one
        fresh = record is None
        previous = None if fresh else record.get("state")
        if event in LATER:
            if fresh or previous == "ended":
                return
            if mine and record.get("owner") not in (0, None, mine) and alive(record.get("owner")):
                return  # from an older process of this session, which a newer one has since resumed
        if fresh:
            record = {"schema": 1, "top": top, "state": None, "sent": 0, "owner": 0}
        if not record.get("id"):
            record["id"] = secrets.token_hex(6)  # this record's incarnation: sends are bound to it
        moved = not fresh and record.get("top") != top
        sent, state = record.get("sent") or 0, STATES[event]
        record.update({"top": top, "state": state, "version": running_version() or record.get("version") or ""})
        if event != "SessionEnd":
            record["activeAt"] = int(now * 1000)  # the session's last sign of life: start, prompt, tool use, stop
        if owner and (event == "SessionStart" or owner_started or owner != record.get("owner")):
            # re-read on every start and prompt; a start whose look-up failed keeps no old start time
            record.update({"owner": owner, "ownerStarted": owner_started})
        if event == "SessionEnd":
            record["reason"] = str(payload.get("reason") or "")
            verb = "end"
        elif event == "SessionStart" or fresh or previous == "ended":
            verb = "start"
        elif event == "UserPromptSubmit" and (now - sent >= BEAT_AFTER or moved):
            verb = "beat"
        elif (state != record.get("reported") or moved) and now - sent >= CHANGE_AFTER:
            verb = "beat"
        else:
            verb = None
        sequence, at = queue(record, now) if verb else (0, 0)
        save(sid, record)
        if verb:
            spawn("send", verb, state, sid, record["id"], str(sequence), str(at))
        if event in ("SessionStart", "UserPromptSubmit") and record.get("owner") and not keeper_running(sid):
            spawn("keeper", sid)
    if fresh and event == "SessionStart":
        prune(sid, now)


def replaced(record):
    """Whether the session's process id now belongs to another process: only a known start time
    more than a few seconds off counts (a stepped clock shifts what `ps` reports), never a failed
    look-up."""
    was = record.get("ownerStarted")
    if isinstance(was, bool) or not isinstance(was, int) or was <= 0:
        return False
    now = started(record.get("owner"))
    return bool(now and abs(now - was) > STARTED_SLACK)


def keeper(sid):
    if load(sid) is None:
        return  # no session to keep
    fd = lock(sid, "keeper", False)
    if fd is None:
        return  # another keeper runs for this session
    poll = 10 * MINUTE / 60
    try:
        while fd is not None:
            time.sleep(poll)
            os.utime(fd)
            peek = load(sid) or {}
            settings = block(peek.get("top"))
            due = bool(settings) and time.time() - (peek.get("sent") or 0) >= settings["intervalMinutes"] * MINUTE
            reused = due and replaced(peek)  # `ps` runs outside the state lock
            job = None
            with state_lock(sid):
                record = load(sid)
                settings = block(record.get("top")) if record else None
                if not settings or record.get("state") == "ended":
                    os.close(fd)  # released under the state lock: a resume then starts a new keeper
                    fd = None
                    continue
                owner, now = record.get("owner"), time.time()
                due = now - (record.get("sent") or 0) >= settings["intervalMinutes"] * MINUTE
                held = record.get("state") != record.get("reported") and now - (record.get("sent") or 0) >= CHANGE_AFTER
                same = owner == peek.get("owner") and record.get("ownerStarted") == peek.get("ownerStarted")
                if not alive(owner) or (reused and same):
                    record.update({"state": "ended", "reason": "gone"})
                    job = ("end", "ended") + queue(record, now)
                    save(sid, record)
                    os.close(fd)
                    fd = None
                elif due or held:
                    job = ("beat", record["state"]) + queue(record, now)
                    save(sid, record)
            if job:
                send(job[0], job[1], sid, record["id"], job[2], job[3])
    finally:
        if fd is not None:
            os.close(fd)


def main(argv):
    try:
        if argv[:1] == ["hook"]:
            hook()
        elif argv[:1] == ["keeper"] and len(argv) == 2 and SESSION_ID.match(argv[1]):
            keeper(argv[1])
        elif (argv[:1] == ["send"] and len(argv) == 7 and SESSION_ID.match(argv[3]) and argv[5].isdigit()
              and argv[6].isdigit()):
            send(argv[1], argv[2], argv[3], argv[4], int(argv[5]), int(argv[6]))
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
