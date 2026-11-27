#!/usr/bin/env python3
"""This machine's session reporter credential: the narrow DevStride key a machine signed in through
the browser reports its own agent sessions with — standard library only, no network.

A browser sign-in gives Claude Code a DevStride connection but no API key, so the built-in session
reporter (hooks/presence-report.py) has nothing to send with. The first time a DevStride skill runs on
such a machine, the presence hook asks the model to register a reporter key through the signed-in
connection (the `register_session_reporter` tool) with this script's help:

  python3 reporter_credential.py prepare     makes a 32-byte secret, keeps it in a pending file and
                                             prints only `FINGERPRINT: <hex>` (the SHA-256 of the
                                             secret) and `MACHINE: <name>`. The secret is never
                                             printed: the model, and DevStride, see only the
                                             fingerprint.
  python3 reporter_credential.py finish --key-id <id> --org-id <id> --org-slug <slug> --username <name>
                                             moves the pending secret into the credential file with
                                             the registration's answer, and prints `REPORTER: READY
                                             (Session reporter · <machine>)`.
  python3 reporter_credential.py status      prints READY, PENDING or NONE, never a value.

The file is session-reporter.json in $XDG_CONFIG_HOME/devstride-plugin/ (else ~/.config/
devstride-plugin/), or %APPDATA%\\devstride-plugin\\ on Windows: owner-only (0600 in a 0700 folder;
Windows guards it with the user profile's own access list), written through a temporary file and
replaced whole, and read only through devstride_connection.owned_file, so a link, a file another user
owns or one with group or other permission bits is refused; on macOS and Linux so is a file in a
folder that is a link, that another user owns or that others may write to, and a folder that is a link
or another user's is named even when no file can be seen in it (prepare closes a folder of the user's
own to 0700 whenever group or other users have any access to it). A full API key always wins over it, and the release clearance provider never reads it: the key
it holds is refused on every route but the session presence report. Exit 0 on success, 2 for a refusal (one line on stderr, never a value).
"""
import hashlib
import json
import os
import re
import secrets
import stat
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import claim_record  # noqa: E402  the one machine naming every claim uses
import devstride_connection  # noqa: E402  the one safe way a file holding a key is opened
import portable  # noqa: E402  the calls that differ on Windows

FILE_NAME = "session-reporter.json"
PENDING_NAME = "session-reporter.pending.json"
FILE_LIMIT = 65536
MACHINE_MAX = 100
MACHINE_RULE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,98}[a-z0-9])?\Z")
SECRET_RULE = re.compile(r"^[0-9a-f]{64}\Z")
VALUE_RULE = re.compile(r"^[^\x00-\x1f\x7f]{1,200}\Z")
FIELDS = ("apiKey", "secret", "organizationId", "organizationSlug", "username", "machine")


class Refused(Exception):
    """A refusal: `str(error)` is one value-free line."""


def folder(environ=None):
    environ = os.environ if environ is None else environ
    if portable.IS_WINDOWS and environ.get("APPDATA"):
        return os.path.join(environ["APPDATA"], "devstride-plugin")
    base = environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "devstride-plugin")


def path(environ=None):
    return os.path.join(folder(environ), FILE_NAME)


def pending_path(environ=None):
    return os.path.join(folder(environ), PENDING_NAME)


def fingerprint(secret):
    """The lowercase hex SHA-256 of the secret exactly as it is sent in the request header."""
    return hashlib.sha256(secret.encode("utf-8")).hexdigest()


def machine(environ=None):
    """The machine's name as claims spell it, cut to the length DevStride accepts."""
    return re.sub(r"-+$", "", claim_record.machine_name(environ)[:MACHINE_MAX])


def private_folder(where):
    """The plugin's configuration folder, made owner-only: one the user owns that group or other users
    have any access to (a umask of 002 or 022, a hand-made folder) is closed to 0700 before anything is
    written in it, so no other user can replace the credential or list the folder. Windows has no mode
    bits: the user profile's own access list guards it there."""
    os.makedirs(where, mode=0o700, exist_ok=True)
    info = os.lstat(where)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != portable.uid():
        raise Refused("the plugin's configuration folder is not a folder you own")
    if not portable.IS_WINDOWS and info.st_mode & 0o077:
        os.chmod(where, 0o700)
    return where


def foreign_folder(where):
    """Why the folder itself cannot be trusted, else None: on macOS and Linux a folder that is a link,
    or one another user owns (which may not even let the user see whether a credential is in it, so it
    must never read as having none). Never on Windows, nor for a folder that is not there."""
    if portable.IS_WINDOWS:
        return None
    try:
        info = os.lstat(where)
    except OSError:
        return None
    if stat.S_ISLNK(info.st_mode):
        return "folder is a link"
    if info.st_uid != portable.uid():
        return "folder not yours"
    return None


def unsafe_folder(where):
    """Why a file in `where` cannot be trusted because of its folder, else None: on macOS and Linux a
    folder that is a link or another user's (foreign_folder), or one that group or other users may
    write to, lets someone else replace the file. A folder others may only read is accepted: the file
    in it is owner-only, so they can see its name and nothing more. Never on Windows (no mode bits; the
    profile's access list guards it), nor for a folder that is not there."""
    why = foreign_folder(where)
    if why or portable.IS_WINDOWS:
        return why
    try:
        info = os.stat(where)
    except OSError:
        return None
    if info.st_mode & 0o022:
        return "folder open to others"
    return None


def write_private(target, values):
    """Write `values` as JSON to `target`, owner-only, through a new temporary file replaced whole."""
    temporary = "%s.%s.tmp" % (target, secrets.token_hex(4))
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | portable.flags("O_NOFOLLOW"), 0o600)
    try:
        os.write(fd, json.dumps(values, sort_keys=True).encode("utf-8"))
        os.fsync(fd)
    finally:
        os.close(fd)
    try:
        os.replace(temporary, target)
    except OSError:
        os.unlink(temporary)
        raise


def load(target, kind):
    """The JSON object in an owner-only file, or None when there is no such file. Raises
    devstride_connection.UnsafeFile for a file that cannot be read safely, and for a folder that is a
    link or another user's, checked BEFORE the file: such a folder may hide the file, and a credential
    read as absent would send the next skill into a registration that cannot be saved."""
    where = os.path.dirname(target)
    why = foreign_folder(where)
    if why:
        raise devstride_connection.UnsafeFile(kind, target, why)
    raw = devstride_connection.owned_file(kind, target, FILE_LIMIT)
    if raw is None:
        return None
    why = unsafe_folder(where)
    if why:
        raise devstride_connection.UnsafeFile(kind, target, why)
    try:
        values = json.loads(raw.decode("utf-8"))
    except ValueError:
        return None
    return values if isinstance(values, dict) else None


def read(environ=None):
    """The stored credential {apiKey, secret, organizationId, organizationSlug, username, machine},
    or None when there is none or it is incomplete. Raises devstride_connection.UnsafeFile."""
    values = load(path(environ), "reporter")
    if not values or not all(isinstance(values.get(name), str) and VALUE_RULE.match(values[name]) for name in FIELDS):
        return None
    if not SECRET_RULE.match(values["secret"]):
        return None
    return {name: values[name] for name in FIELDS}


def set_aside(environ=None):
    """Move a refused credential out of the way (DevStride no longer takes it: revoked, replaced by
    another machine's registration, or stored with another session's secret), so the machine reads as
    keyless again: the session-start line returns and the next DevStride skill registers a new one.
    Kept beside the original, owner-only, for a person to look at; True when one was moved."""
    try:
        os.replace(path(environ), path(environ) + ".refused")
        return True
    except OSError:
        return False


def status(environ=None):
    try:
        if read(environ):
            return "READY"
        return "PENDING" if load(pending_path(environ), "reporter") else "NONE"
    except devstride_connection.Problem:
        return "NONE"


def prepare(environ=None):
    name = machine(environ)
    if not MACHINE_RULE.match(name):
        raise Refused("this machine has no usable name: set DEVSTRIDE_MACHINE_NAME")
    secret = secrets.token_bytes(32).hex()
    write_private(os.path.join(private_folder(folder(environ)), PENDING_NAME), {"secret": secret, "machine": name})
    return fingerprint(secret), name


def finish(answer, environ=None):
    """Move the pending secret into the credential file with the registration's answer."""
    for name in ("apiKey", "organizationId", "organizationSlug", "username"):
        if not isinstance(answer.get(name), str) or not VALUE_RULE.match(answer[name]):
            raise Refused("the registration's %s is missing or malformed" % name)
    try:
        pending = load(pending_path(environ), "reporter")
    except devstride_connection.UnsafeFile as error:
        raise Refused("the pending secret cannot be read safely: %s" % error.reason)
    if not pending or not isinstance(pending.get("secret"), str) or not SECRET_RULE.match(pending["secret"]) \
            or not isinstance(pending.get("machine"), str) or not MACHINE_RULE.match(pending["machine"]):
        raise Refused("no pending secret: run prepare, then register again")
    values = dict((name, answer[name]) for name in ("apiKey", "organizationId", "organizationSlug", "username"))
    values.update(secret=pending["secret"], machine=pending["machine"])
    write_private(os.path.join(private_folder(folder(environ)), FILE_NAME), values)
    os.unlink(pending_path(environ))
    return pending["machine"]


def options(argv):
    """`--name value` pairs into {name: value}; anything else is a refusal."""
    wanted = {"--key-id": "apiKey", "--org-id": "organizationId", "--org-slug": "organizationSlug",
              "--username": "username"}
    answer = {}
    while argv:
        flag = argv.pop(0)
        if flag not in wanted or not argv:
            raise Refused("usage: finish --key-id <id> --org-id <id> --org-slug <slug> --username <name>")
        answer[wanted[flag]] = argv.pop(0)
    return answer


def main(argv):
    mode = argv[0] if argv else ""
    try:
        if mode == "prepare" and len(argv) == 1:
            digest, name = prepare()
            print("FINGERPRINT: %s" % digest)
            print("MACHINE: %s" % name)
        elif mode == "finish":
            print("REPORTER: READY (Session reporter · %s)" % finish(options(argv[1:])))
        elif mode == "status" and len(argv) == 1:
            print(status())
        else:
            sys.stderr.write("usage: reporter_credential.py prepare | finish --key-id <id> --org-id <id> "
                             "--org-slug <slug> --username <name> | status\n")
            return 2
    except Refused as error:
        sys.stderr.write("reporter_credential: %s\n" % error)
        return 2
    except OSError:
        sys.stderr.write("reporter_credential: the plugin's configuration folder cannot be written\n")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
