"""A new name someone asked a session to take on the Agent Fleet, kept on this machine between the
built-in reporter that hears of it and the title hook that applies it.

The built-in reporter (hooks/presence-report.py) reads the request from the server's answer to a
report and keeps it here; the title hook (hooks/session-title.py) sets it as the session's own title
at the next prompt, start, resume or fork, as /rename would, once per request; and the reporter's
next report, once the session's name is the one asked for or the title hook has set it (a person
may have renamed the session since), sends the request's time back as `renameApplied`, so the
server stops asking. A repository whose own presence command reports the session keeps its own
record of a request: nothing here is written for that session.

The record is ${XDG_CACHE_HOME:-~/.cache}/devstride-plugin/session-title/<session>.request.json, beside
the title hook's own records (whose start-of-session prune also removes one untouched for 7 days),
owner-only, holding only the cleaned name and the request's time. python3 and the standard library
only.
"""
import json
import os
import re
import secrets
import stat

import portable

SESSION_ID = re.compile(r"^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$")   # the hooks' session ids
NAME_LIMIT = 64    # Claude Code's title is cut at 64 characters
AT_LIMIT = 64      # the report's `renameApplied` is at most 64 characters
RECORD_LIMIT = 4096


def directory():
    base = os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
    return os.path.join(base, "devstride-plugin", "session-title")


def path(sid):
    return os.path.join(directory(), sid + ".request.json")


def trusted():
    """Whether the records directory and its parent are real directories this user owns, not links,
    and neither is open to other users for writing (the parent may be open to the user's own group,
    as a umask of 002 leaves it): nothing is read, replaced or removed anywhere else."""
    for folder, closed in ((os.path.dirname(directory()), 0o002), (directory(), 0o022)):
        try:
            info = os.lstat(folder)
        except OSError:
            return False
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != portable.uid() or (
                not portable.IS_WINDOWS and info.st_mode & closed):  # Windows reports no mode bits
            return False
    return True


def clean(value):
    """The name as Claude Code will hold it: one line, no control characters or `|`, whitespace
    collapsed, at most 64 characters; None when nothing is left or it is not text."""
    if not isinstance(value, str):
        return None
    text = "".join(" " if ord(c) < 32 or ord(c) == 127 or c == "|" else c for c in value)
    return " ".join(text.split())[:NAME_LIMIT].strip() or None


def stamp(value):
    """A request's time as the report may carry it back, or None."""
    if not isinstance(value, str) or not value or len(value) > AT_LIMIT or re.search(r"[\x00-\x1f\x7f]", value):
        return None
    return value


def applied(sid):
    """The time of the last Fleet rename the title hook set for this session (its own record's
    `applied`), or None: proof the session took that request even when a person renamed it since."""
    if not isinstance(sid, str) or not SESSION_ID.match(sid) or not trusted():
        return None
    record = os.path.join(directory(), sid + ".json")
    try:
        if not stat.S_ISREG(os.lstat(record).st_mode):
            return None
        fd = os.open(record, os.O_RDONLY | portable.flags("O_NONBLOCK", "O_NOFOLLOW"))
    except OSError:
        return None
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != portable.uid() or info.st_size > RECORD_LIMIT:
            return None
        data = json.loads(os.read(fd, RECORD_LIMIT + 1))
    except Exception:
        return None
    finally:
        os.close(fd)
    return stamp(data.get("applied")) if isinstance(data, dict) else None


def same(name, wanted):
    """Whether the session's name is the one asked for (Claude Code collapses whitespace in a title)."""
    return bool(clean(name)) and clean(name) == clean(wanted)


def request_of(answer):
    """(name, at) from a report's answer, or None: only a recorded answer carries a request."""
    if not isinstance(answer, dict) or answer.get("outcome") != "recorded":
        return None
    asked = answer.get("rename")
    if not isinstance(asked, dict):
        return None
    name, at = clean(asked.get("name")), stamp(asked.get("at"))
    return (name, at) if name and at else None


def read(sid):
    """The waiting request, {"name", "at"}, or None: a regular file this user owns, never a link."""
    if not isinstance(sid, str) or not SESSION_ID.match(sid) or not trusted():
        return None
    try:
        if not stat.S_ISREG(os.lstat(path(sid)).st_mode):
            return None  # a link (where the system cannot refuse one when opening it)
        fd = os.open(path(sid), os.O_RDONLY | portable.flags("O_NONBLOCK", "O_NOFOLLOW"))
    except OSError:
        return None
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != portable.uid() or info.st_size > RECORD_LIMIT:
            return None
        record = json.loads(os.read(fd, RECORD_LIMIT + 1))
    except Exception:
        return None
    finally:
        os.close(fd)
    if not isinstance(record, dict):
        return None
    name, at = clean(record.get("name")), stamp(record.get("at"))
    return {"name": name, "at": at} if name and at else None


def write(sid, name, at):
    """Keep the request for the title hook; an owner-only file in an owner-only directory, replaced
    whole so a reader never sees half of it."""
    if not SESSION_ID.match(sid):
        return
    os.makedirs(os.path.dirname(directory()), mode=0o700, exist_ok=True)  # private when this creates it
    os.makedirs(directory(), mode=0o700, exist_ok=True)
    if not trusted():
        raise OSError("untrusted directory")
    data = (json.dumps({"name": name, "at": at}) + "\n").encode()
    temporary = os.path.join(directory(), ".%s.%s.tmp" % (sid, secrets.token_hex(8)))
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | portable.flags("O_NOFOLLOW"), 0o600)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)
    portable.replace(temporary, path(sid))


def remove(sid):
    if not isinstance(sid, str) or not SESSION_ID.match(sid) or not trusted():
        return
    try:
        info = os.lstat(path(sid))
        if stat.S_ISREG(info.st_mode) and info.st_uid == portable.uid():
            os.unlink(path(sid))
    except OSError:
        pass
