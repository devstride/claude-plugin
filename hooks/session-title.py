#!/usr/bin/env python3
"""hooks/session-title.py — let the repository name an unnamed session, through Claude Code's own title.

Claude Code lets a SessionStart or UserPromptSubmit hook set the session's title, with the same
effect as /rename. This hook asks the consuming repository for one, through ONE command it names in
`.claude/ds-config.json`:

    "session": { "titleCommand": "<the repository's own command>" }

An absent, null or blank command, or a session outside a repository, runs nothing and writes nothing.

  hook     (the hook command; the event comes from the payload's hook_event_name)
           UserPromptSubmit, and SessionStart whose source is startup, resume or fork (the sources
           whose title Claude Code applies; clear and compact are ignored). Runs the command once,
           through the shell, from the directory holding the config (the nearest one above the
           payload's cwd), at most 3 seconds, its whole process group killed after that. It exports
           CLAUDE_CODE_SESSION_ID, SESSION_TITLE (the payload's session_title: the session's custom
           title, empty when it has none; a generated title is never a custom one) and
           SESSION_TITLE_OWNED=1 when that title is the one this hook last set on its own (absent
           otherwise). The prompt goes on stdin, cut to 8 KB; SessionStart sends nothing.
           Output: line 1 is the title; an optional line 2 `replace` says a person asked for it.
           Line 1 is cleaned (no control characters or `|`, whitespace collapsed, at most 64
           characters) and applied only when the session has no custom title, or its custom title
           is this hook's own, or line 2 is `replace`; never otherwise, so a name set with --name
           or /rename wins. A title set because of `replace` is a person's, so it is never OWNED, and
           neither is the hook's own title once a prompt has seen the session renamed to another.
           The hook prints `{"hookSpecificOutput":{"hookEventName":<event>,"sessionTitle":<t>}}`
           only when the title differs from the custom title the session already has.
Records: ${XDG_CACHE_HOME:-~/.cache}/devstride-plugin/session-title/<session>.json (the title this hook
last set, and whether it set it on its own), owner-only, written only when a title is printed or
stops being the hook's own;
another session's record untouched for 7 days is pruned at a new session's start. Nothing is
written in the repository or the plugin directory. FAILS OPEN: every hook exits 0, and prints
nothing but that one JSON line (a prompt hook's other stdout would become context), whatever goes
wrong. python3 and the standard library only.
"""
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

SESSION_ID = re.compile(r"^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$")
EVENTS = ("UserPromptSubmit", "SessionStart")
SOURCES = ("startup", "resume", "fork")   # the SessionStart sources whose sessionTitle Claude Code applies
COMMAND_TIMEOUT = 3
PROMPT_LIMIT = 8192
OUTPUT_LIMIT = 65536
TITLE_LIMIT = 64
PAYLOAD_LIMIT = 4 * 1048576   # a prompt hook's payload carries the whole prompt
KEEP = 7 * 24 * 3600


def records_path():
    base = os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
    return os.path.join(base, "devstride-plugin", "session-title")


def private_dir(path):
    os.makedirs(path, mode=0o700, exist_ok=True)
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise OSError("untrusted directory")
    return path


def read_json(path, limit=65536):
    """A regular file we own, opened without following a symlink; None on any doubt."""
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


def last_set(sid):
    record = read_json(os.path.join(records_path(), sid + ".json"))
    return record if isinstance(record, dict) and isinstance(record.get("title"), str) else {}


def remember(sid, title, own):
    directory = private_dir(records_path())
    data = (json.dumps({"title": title, "own": own, "at": int(time.time())}) + "\n").encode()
    temporary = os.path.join(directory, ".%s.%s.tmp" % (sid, secrets.token_hex(8)))
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)
    os.replace(temporary, os.path.join(directory, sid + ".json"))


def prune(own, now):
    """Remove other sessions' records (and temporary files) untouched for KEEP."""
    directory = records_path()
    try:
        names = os.listdir(directory)
    except OSError:
        return
    for name in names:
        if name == own + ".json":
            continue
        path = os.path.join(directory, name)
        try:
            info = os.lstat(path)
            if stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and now - info.st_mtime > KEEP:
                os.unlink(path)
        except OSError:
            pass


def config_root(start):
    """The nearest directory at or above start holding .claude/ds-config.json, and its config."""
    here = os.path.abspath(start)
    while True:
        if os.path.isfile(os.path.join(here, ".claude", "ds-config.json")):
            config = read_json(os.path.join(here, ".claude", "ds-config.json"), limit=1048576)
            return here, config if isinstance(config, dict) else {}
        parent = os.path.dirname(here)
        if parent == here:
            return None, {}
        here = parent


def title_command(config):
    session = config.get("session") if isinstance(config.get("session"), dict) else {}
    command = session.get("titleCommand")
    return command if isinstance(command, str) and command.strip() else None


def clean(value):
    """One line, no control characters or `|`, whitespace collapsed, at most 64 characters."""
    text = "".join(" " if ord(c) < 32 or ord(c) == 127 or c == "|" else c for c in value)
    return " ".join(text.split())[:TITLE_LIMIT].strip()


def run(command, root, sid, current, owned, prompt):
    """The command's stdout, or None when it failed, timed out or could not start."""
    env = dict(os.environ)
    env.update({"CLAUDE_CODE_SESSION_ID": sid, "SESSION_TITLE": current})
    env.pop("SESSION_TITLE_OWNED", None)
    if owned:
        env["SESSION_TITLE_OWNED"] = "1"
    data = prompt.encode("utf-8", "replace")[:PROMPT_LIMIT]
    data = data.decode("utf-8", "ignore").encode("utf-8")  # never end inside a character
    try:
        child = subprocess.Popen(command, shell=True, cwd=root, env=env, stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
    except Exception:
        return None
    try:
        out, _ = child.communicate(data, timeout=COMMAND_TIMEOUT)
    except Exception:  # a timeout, or a command that closed its stdin early
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except OSError:
            pass
        for stream in (child.stdin, child.stdout):
            try:
                stream.close()
            except Exception:
                pass
        try:
            child.wait(timeout=1)
        except Exception:
            pass
        return None
    if child.returncode != 0:
        return None
    return out[:OUTPUT_LIMIT].decode("utf-8", "replace")


def hook():
    try:
        payload = json.loads(sys.stdin.read(PAYLOAD_LIMIT) or "{}")
    except Exception:
        return
    if not isinstance(payload, dict):
        return
    event, sid = payload.get("hook_event_name"), payload.get("session_id")
    if event not in EVENTS or not isinstance(sid, str) or not SESSION_ID.match(sid):
        return
    if event == "SessionStart" and payload.get("source") not in SOURCES:
        return
    cwd = payload.get("cwd") if isinstance(payload.get("cwd"), str) and payload.get("cwd") else os.getcwd()
    root, config = config_root(cwd)
    command = title_command(config) if root else None
    if not command:
        return  # nothing configured: nothing runs and nothing is written
    if event == "SessionStart" and payload.get("source") == "startup":
        prune(sid, time.time())
    current = payload.get("session_title") if isinstance(payload.get("session_title"), str) else ""
    mine = last_set(sid)
    owned = bool(current) and mine.get("own") is True and mine.get("title") == current
    if current and mine.get("own") is True and not owned:
        # a person renamed the session since: the hook's title is no longer its own, even if the
        # person later names it back to that same text
        remember(sid, mine["title"], False)
    prompt = payload.get("prompt") if event == "UserPromptSubmit" and isinstance(payload.get("prompt"), str) else ""
    out = run(command, root, sid, current, owned, prompt)
    if out is None:
        return
    lines = out.splitlines()
    title = clean(lines[0]) if lines else ""
    replace = len(lines) > 1 and lines[1].strip() == "replace"
    if title and title == current and owned and replace:
        remember(sid, title, False)  # the same text, now a person's request: never replaced on its own again
        return
    if not title or title == current or not (not current or owned or replace):
        return
    remember(sid, title, not replace)  # before printing: a title the hook cannot record is never set
    sys.stdout.write(json.dumps({"hookSpecificOutput": {"hookEventName": event, "sessionTitle": title}}) + "\n")
    sys.stdout.flush()


def main(argv):
    try:
        if argv[:1] == ["hook"]:
            hook()
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
