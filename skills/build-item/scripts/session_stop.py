"""A stop someone asked for on the Agent Fleet, kept on this machine between the stop check that
hears of it and everything that then refuses to go on.

The built-in reporter's stop check (hooks/presence-report.py stop-sync, run by the session's keeper)
hears of a stop from the server and keeps it here. While the record is there the stop gate
(hooks/stop-gate.py) refuses every tool call and every prompt of the session, and the step runner
(skills/run-workflow/scripts/workflow.py) hands it no step. The record goes when the server says the
stop is over (a person allowed the session to continue). A person at the machine may remove the
file; the next stop check puts it back while the stop is open.

The record is ${XDG_CACHE_HOME:-~/.cache}/devstride-plugin/stop/<session>.json, owner-only, holding
the stop's id, the name of the person who stopped the session, when, the reason, the scope (this
session, or every session of the organization) and whether the server was told this machine heard
it. A record that exists but cannot be read counts as a stop: only its absence lets a session go
on. When the stop check removes a record because the stop is over, it leaves the session a one-time
note in ${XDG_CACHE_HOME:-~/.cache}/devstride-plugin/stop-lifted/<session>.json (`note_lifted`), and
the gate tells the session's model, on its next prompt, that it may go on (`take_lifted`): the last
thing the model was told is the stop line, so without the note it keeps declining. The contract:
skills/setup/references/session-presence.md. python3 and the standard library only.
"""
import json
import os
import re
import secrets
import stat

import portable

SESSION_ID = re.compile(r"^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$")   # the hooks' session ids
ID_LIMIT, NAME_LIMIT, AT_LIMIT, REASON_LIMIT = 200, 200, 64, 500
RECORD_LIMIT = 16384   # every field at its limit, each character escaped, still fits
SCOPES = ("session", "organization")
ISO = re.compile(r"^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.\d{1,9})?(Z|[+-]\d\d:?\d\d)$")
CONTINUE = "This session runs no more tools or workflow steps until a person allows it to continue on Agents → Fleet."
LIFTED = "stop-lifted"   # the one-time notes that a stop is over, beside the records
GO_ON = ("Tools and workflow steps run again, so carry out the person's requests as usual, this prompt "
         "included.")
UNREADABLE = ("Stopped from DevStride: the stop record this machine keeps for the session cannot be read, "
              "which counts as a stop.")


def directory(environ=None, kind="stop"):
    base = (os.environ if environ is None else environ).get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
    return os.path.join(base, "devstride-plugin", kind)


def path(sid, environ=None, kind="stop"):
    return os.path.join(directory(environ, kind), sid + ".json")


def trusted(environ=None, kind="stop"):
    """Whether the records directory and its parent are real directories this user owns, not links,
    and neither is open to other users for writing (the parent may be open to the user's own group,
    as a umask of 002 leaves it): nothing is written or removed anywhere else, and nothing read
    anywhere else is believed."""
    folder = directory(environ, kind)
    for place, closed in ((os.path.dirname(folder), 0o002), (folder, 0o022)):
        try:
            info = os.lstat(place)
        except OSError:
            return False
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != portable.uid() or (
                not portable.IS_WINDOWS and info.st_mode & closed):  # Windows reports no mode bits
            return False
    return True


def clean(value, limit):
    """One line of text: control characters become spaces, whitespace collapsed, cut to `limit`;
    None when nothing is left or it is not text."""
    if not isinstance(value, str):
        return None
    text = "".join(" " if ord(c) < 32 or ord(c) == 127 else c for c in value)
    return " ".join(text.split())[:limit].strip() or None


def stop_of(value):
    """The stop a server's answer or a kept record describes, {"id", "by", "at", "reason",
    "scope"}, or None when it is not one: a stop always has an id, the rest may be unknown (None).
    `by` is the person's name, read from the server's {"userId", "name"} or from a kept record."""
    if not isinstance(value, dict):
        return None
    ident = value.get("id")
    if not isinstance(ident, str) or not ident or len(ident) > ID_LIMIT or re.search(r"[\x00-\x1f\x7f]", ident):
        return None
    by = value.get("by")
    scope = value.get("scope")
    return {"id": ident, "by": clean(by.get("name") if isinstance(by, dict) else by, NAME_LIMIT),
            "at": clean(value.get("at"), AT_LIMIT), "reason": clean(value.get("reason"), REASON_LIMIT),
            "scope": scope if scope in SCOPES else None}


def read(sid, environ=None):
    """The session's stop, or None when it has none: {"id", "by", "at", "reason", "scope",
    "acknowledged"}. A record that exists but cannot be read (not a regular file this user owns in
    a folder only they can write, too large, or not what `write` leaves) is a stop too, answered as
    {"unreadable": True}. A file that cannot even be looked for is no record: only a stop this
    machine has heard of stops anything."""
    if not isinstance(sid, str) or not SESSION_ID.match(sid):
        return None
    target = path(sid, environ)
    try:
        info = os.lstat(target)
    except OSError:
        return None
    if not stat.S_ISREG(info.st_mode) or not trusted(environ):
        return {"unreadable": True}  # a link, a folder, or a place another user could have written
    try:
        fd = os.open(target, os.O_RDONLY | portable.flags("O_NONBLOCK", "O_NOFOLLOW"))
    except FileNotFoundError:
        return None  # removed since the look: the stop is over
    except OSError:
        return {"unreadable": True}
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != portable.uid() or info.st_size > RECORD_LIMIT:
            return {"unreadable": True}
        record = json.loads(os.read(fd, RECORD_LIMIT + 1))
    except Exception:
        return {"unreadable": True}
    finally:
        os.close(fd)
    stop = stop_of(record)
    if stop is None:
        return {"unreadable": True}
    stop["acknowledged"] = record.get("acknowledged") is True
    return stop


def write(sid, stop, acknowledged=False, environ=None):
    """Keep the stop (what `stop_of` returned) for the gate and the runner; an owner-only file in an
    owner-only directory, replaced whole so a reader never sees half of it."""
    record = {name: stop.get(name) for name in ("id", "by", "at", "reason", "scope")}
    record["acknowledged"] = acknowledged is True
    put(sid, record, environ)


def put(sid, record, environ=None, kind="stop"):
    """Write one session's record of `kind` whole, owner-only, in an owner-only directory."""
    if not SESSION_ID.match(sid):
        return
    folder = directory(environ, kind)
    os.makedirs(os.path.dirname(folder), mode=0o700, exist_ok=True)  # private when this creates it
    os.makedirs(folder, mode=0o700, exist_ok=True)
    if not trusted(environ, kind):
        raise OSError("untrusted directory")
    data = (json.dumps(record) + "\n").encode()
    temporary = os.path.join(folder, ".%s.%s.tmp" % (sid, secrets.token_hex(8)))
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | portable.flags("O_NOFOLLOW"), 0o600)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)
    portable.replace(temporary, path(sid, environ, kind))


def remove(sid, environ=None, kind="stop"):
    """Drop the session's record, readable or not (a link is removed, never followed)."""
    if not isinstance(sid, str) or not SESSION_ID.match(sid) or not trusted(environ, kind):
        return
    try:
        if not stat.S_ISDIR(os.lstat(path(sid, environ, kind)).st_mode):
            os.unlink(path(sid, environ, kind))
    except OSError:
        pass


def note_lifted(sid, environ=None, now=None):
    """Leave the session a one-time note that its stop is over, for the gate to pass on at its next
    prompt: only when this machine heard it. Never the stop's reason or a person's name: both are
    free text people write, and this line reaches the model as the session goes back to work (the
    Fleet shows who). Never raises: without the note the session only stays cautious."""
    try:
        from datetime import datetime, timezone
        at = now or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        put(sid, {"at": at}, environ, LIFTED)
    except Exception:
        pass


def take_lifted(sid, environ=None):
    """The line telling the session its stop is over, once: the note is removed as it is read. None
    when there is none, or it is not a regular file this user owns in a folder only they can write
    (such a note is removed, never believed)."""
    if not isinstance(sid, str) or not SESSION_ID.match(sid):
        return None
    target = path(sid, environ, LIFTED)
    try:
        info = os.lstat(target)
    except OSError:
        return None
    note = None
    try:
        if stat.S_ISREG(info.st_mode) and info.st_uid == portable.uid() and info.st_size <= RECORD_LIMIT \
                and trusted(environ, LIFTED):
            fd = os.open(target, os.O_RDONLY | portable.flags("O_NONBLOCK", "O_NOFOLLOW"))
            try:
                note = json.loads(os.read(fd, RECORD_LIMIT + 1))
            finally:
                os.close(fd)
    except Exception:
        note = None
    remove(sid, environ, LIFTED)
    return lifted_line(note) if isinstance(note, dict) else None


def local_time(at):
    """An ISO 8601 time as this machine's clock shows it, "2:14 PM CST"; "" when it is not one."""
    match = ISO.match(at) if isinstance(at, str) else None
    if not match:
        return ""
    from datetime import datetime, timedelta, timezone
    try:
        offset = match.group(7)
        if offset == "Z":
            zone = timezone.utc
        else:
            minutes = int(offset[1:3]) * 60 + int(offset[-2:])
            zone = timezone(timedelta(minutes=-minutes if offset[0] == "-" else minutes))
        local = datetime(*(int(part) for part in match.groups()[:6]), tzinfo=zone).astimezone()
        name = local.tzname() or local.strftime("UTC%z")
    except (ValueError, OverflowError, OSError):
        return ""
    return "%d:%02d %s %s" % (local.hour % 12 or 12, local.minute, "AM" if local.hour < 12 else "PM", name)


def line(stop):
    """The one sentence every surface prints for a stopped session."""
    if not isinstance(stop, dict) or not stop.get("id"):
        return UNREADABLE + " " + CONTINUE
    when = local_time(stop.get("at"))
    reason = stop.get("reason") or "no reason given"
    return "Stopped from DevStride by %s%s: %s%s %s" % (
        stop.get("by") or "a person", " at " + when if when else "", reason,
        "" if reason[-1] in ".!?" else ".", CONTINUE)


def lifted_line(note):
    """The one line a session is told on its first prompt after its stop is over."""
    when = local_time(note.get("at")) if isinstance(note, dict) else ""
    return "The stop from DevStride is over: a person allowed this session to continue on Agents → Fleet%s. %s" % (
        " (this machine heard it at %s)" % when if when else "", GO_ON)
