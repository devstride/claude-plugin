#!/usr/bin/env python3
"""library_skill.py — the machine's cache of the organization's library skills, verified by fingerprint.

The plugin never makes a network call. The agent fetches a pinned skill version through its own DevStride
connection and hands the answer to `put`, which stores it only when its bytes match the fingerprint the
workflow named. Every `check` hashes the stored bytes again; nothing is trusted because it was verified once.

  check   stdin {"organizationId", "name", "version", "hash"}        -> {"status": "hit"|"miss", ...}
  put     stdin one JSON line {"organizationId", "expect", "answer"}, then the skill text byte for byte
  list    stdin {} or {"organizationId"}                              -> {"entries", "totalBytes", "failing"}
  remove  stdin {"organizationId", "name", "version"}                 -> {"removed": true|false}

Answers are JSON on stdout. A refusal is exit 2 with one stderr line starting "library-skill: ". Exit 1 is
anything unexpected. Standard library only.
"""
import hashlib
import json
import os
import re
import sys
import time

MAX_BODY = 65536
MAX_VERSION = 1000000000
ORG_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
NAME_RE = re.compile(r"^[a-z][a-z0-9]*(-[a-z0-9]+)*$")
HASH_RE = re.compile(r"^[0-9a-f]{64}$")
FIELDS = ("name", "version", "implements", "hash")


class Refusal(Exception):
    pass


def cache_root():
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    return os.path.join(base, "devstride-plugin", "skill-library")


def check_org(value):
    if not isinstance(value, str) or not ORG_RE.match(value):
        raise Refusal("the organization id is not valid")
    return value


def check_name(value):
    if not isinstance(value, str) or not 3 <= len(value) <= 64 or not NAME_RE.match(value):
        raise Refusal("the skill name is not valid")
    return value


def check_version(value):
    if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= MAX_VERSION:
        raise Refusal("the skill version must be a whole number from 1 to 1000000000")
    return value


def check_hash(value):
    if not isinstance(value, str) or not HASH_RE.match(value):
        raise Refusal("the fingerprint must be 64 lower-case hex characters")
    return value


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def safe_root(create):
    """The cache root, resolved. A root that resolves elsewhere (a symbolic link pointing outside) is refused."""
    root = cache_root()
    if os.path.islink(root):
        raise Refusal("the skill cache folder is a symbolic link; refusing to use it")
    if create:
        os.makedirs(root, mode=0o700, exist_ok=True)
        os.chmod(root, 0o700)
    return root


def entry_dir(org, name, create):
    """The entry folder <root>/<org>/<name>, every part checked: no symbolic link, and inside the root."""
    root = safe_root(create)
    real_root = os.path.realpath(root)
    folder = root
    for part in (org, name):
        folder = os.path.join(folder, part)
        if os.path.islink(folder):
            raise Refusal("a skill cache folder is a symbolic link; refusing to use it")
        if create and not os.path.isdir(folder):
            os.makedirs(folder, mode=0o700, exist_ok=True)
            os.chmod(folder, 0o700)
    real = os.path.realpath(folder)
    if not real.startswith(real_root + os.sep):
        raise Refusal("the skill cache entry is outside the cache folder")
    return folder


def paths(folder, version):
    return os.path.join(folder, "%d.md" % version), os.path.join(folder, "%d.json" % version)


def atomic_write(path, data):
    folder = os.path.dirname(path)
    temporary = os.path.join(folder, ".%s.%d.%d.tmp" % (os.path.basename(path), os.getpid(), int(time.time() * 1e6)))
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.chmod(temporary, 0o600)
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except BaseException:
        if os.path.exists(temporary):
            os.unlink(temporary)
        raise


def remove_files(*names):
    for name in names:
        if os.path.lexists(name):
            os.unlink(name)


def read_object(text):
    try:
        value = json.loads(text)
    except ValueError:
        raise Refusal("the request is not JSON")
    if not isinstance(value, dict):
        raise Refusal("the request must be one JSON object")
    return value


def command_check(raw):
    request = read_object(raw.decode("utf-8", "replace"))
    org = check_org(request.get("organizationId"))
    name = check_name(request.get("name"))
    version = check_version(request.get("version"))
    want = check_hash(request.get("hash"))
    root = cache_root()
    if not os.path.lexists(root):
        return {"status": "miss", "reason": "absent"}
    folder = entry_dir(org, name, create=False)
    body, meta = paths(folder, version)
    if not os.path.isfile(body) or os.path.islink(body):
        return {"status": "miss", "reason": "absent"}
    with open(body, "rb") as handle:
        data = handle.read()
    if sha256(data) != want:
        remove_files(body, meta)
        return {"status": "miss", "reason": "corrupt", "removed": True}
    return {"status": "hit", "path": body, "hash": want, "size": len(data)}


def command_put(raw):
    line, separator, body = raw.partition(b"\n")
    if not separator:
        raise Refusal("the skill text is missing after the first line")
    request = read_object(line.decode("utf-8", "replace"))
    org = check_org(request.get("organizationId"))
    expect, answer = request.get("expect"), request.get("answer")
    if not isinstance(expect, dict) or not isinstance(answer, dict):
        raise Refusal("the request needs expect and answer objects")
    name = check_name(expect.get("name"))
    version = check_version(expect.get("version"))
    want = check_hash(expect.get("hash"))
    implements = expect.get("implements")
    if not isinstance(implements, str) or not implements:
        raise Refusal("expect.implements must name the step kind")
    for field in FIELDS:
        if answer.get(field) != expect.get(field) or type(answer.get(field)) is not type(expect.get(field)):
            raise Refusal("the skill answer's %s does not match the workflow's manifest" % field)
    if not body:
        raise Refusal("the skill text is missing after the first line")
    candidates = [body]
    if body.endswith(b"\n"):
        candidates.append(body[:-1])  # the here-document's own final line feed
    chosen = next((c for c in candidates if sha256(c) == want), None)
    if chosen is None:
        if all(len(c) > MAX_BODY for c in candidates):
            raise Refusal("the skill text is larger than 65536 bytes")
        raise Refusal("the skill text does not match its fingerprint")
    if len(chosen) > MAX_BODY:
        raise Refusal("the skill text is larger than 65536 bytes")
    if b"\x00" in chosen:
        raise Refusal("the skill text contains a NUL byte")
    try:
        chosen.decode("utf-8")
    except UnicodeDecodeError:
        raise Refusal("the skill text is not valid UTF-8")
    folder = entry_dir(org, name, create=True)
    body_path, meta_path = paths(folder, version)
    atomic_write(body_path, chosen)
    meta = {"name": name, "version": version, "hash": want, "implements": implements, "size": len(chosen),
            "storedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    atomic_write(meta_path, (json.dumps(meta, sort_keys=True) + "\n").encode("utf-8"))
    return {"status": "stored", "path": body_path, "hash": want, "size": len(chosen)}


def entry_valid(body_path, meta_path):
    try:
        with open(meta_path, "r", encoding="utf-8") as handle:
            meta = json.load(handle)
        with open(body_path, "rb") as handle:
            return isinstance(meta, dict) and sha256(handle.read()) == meta.get("hash")
    except (OSError, ValueError):
        return False


def command_list(raw):
    request = read_object(raw.decode("utf-8", "replace") or "{}")
    only = request.get("organizationId")
    if only is not None:
        check_org(only)
    root = cache_root()
    entries = []
    if os.path.isdir(root) and not os.path.islink(root):
        for org in sorted(os.listdir(root)):
            if (only is not None and org != only) or not ORG_RE.match(org):
                continue
            org_dir = os.path.join(root, org)
            if os.path.islink(org_dir) or not os.path.isdir(org_dir):
                continue
            for name in sorted(os.listdir(org_dir)):
                folder = os.path.join(org_dir, name)
                if not NAME_RE.match(name) or os.path.islink(folder) or not os.path.isdir(folder):
                    continue
                for file_name in sorted(os.listdir(folder)):
                    match = re.match(r"^([1-9][0-9]{0,9})\.md$", file_name)
                    if not match:
                        continue
                    version = int(match.group(1))
                    body_path, meta_path = paths(folder, version)
                    entries.append({"organizationId": org, "name": name, "version": version,
                                    "size": os.path.getsize(body_path), "valid": entry_valid(body_path, meta_path)})
    return {"entries": entries, "totalBytes": sum(e["size"] for e in entries),
            "failing": sum(1 for e in entries if not e["valid"])}


def command_remove(raw):
    request = read_object(raw.decode("utf-8", "replace"))
    org = check_org(request.get("organizationId"))
    name = check_name(request.get("name"))
    version = check_version(request.get("version"))
    if not os.path.lexists(cache_root()):
        return {"removed": False}
    folder = entry_dir(org, name, create=False)
    body, meta = paths(folder, version)
    found = os.path.lexists(body) or os.path.lexists(meta)
    remove_files(body, meta)
    return {"removed": found}


COMMANDS = {"check": command_check, "put": command_put, "list": command_list, "remove": command_remove}


def run(argv, raw):
    """Run one command on raw stdin bytes: (exit code, answer or refusal text)."""
    if len(argv) != 1 or argv[0] not in COMMANDS:
        return 2, "library-skill: name one command: check, put, list or remove"
    try:
        return 0, COMMANDS[argv[0]](raw)
    except Refusal as refusal:
        return 2, "library-skill: %s" % refusal


def main(argv):
    try:
        code, answer = run(argv, sys.stdin.buffer.read())
    except Exception as error:  # anything unexpected: one line, exit 1
        sys.stderr.write("library-skill: unexpected error: %s\n" % _one_line(error))
        return 1
    if code:
        sys.stderr.write(answer + "\n")
        return code
    sys.stdout.write(json.dumps(answer, sort_keys=True) + "\n")
    return 0


def _one_line(error):
    return " ".join(str(error).split())[:300]


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
