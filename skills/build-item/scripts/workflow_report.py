#!/usr/bin/env python3
"""The shared rules for what a workflow run tells DevStride: the one canonical form and hash of a
definition, the repository's name, the limits every line of text is cut to, and the one off switch.
Standard library only, no network, no state. The step runner keeps the run's history with these
rules and sends it itself; the rule is in `skills/build-item/references/workflow-reports.md`.

A module first and a command line second. Importing it runs nothing, reads no state, no clock and
no environment variable; the step runner and the checks load it by file path and call these
functions directly:

  canonical_json(obj) -> bytes            definition_hash(definition) -> str
  normalize_repository(url) -> str|None   clean_verdict(s) -> str
  clean_evidence(lines) -> list[str]      clean_links(links) -> dict
  clean_text(value, limit) -> str         clip(value, limit) -> str
  switched_off(config, env) -> bool       read_repository(folder) -> str|None

Commands (JSON out on stdout; exit 0, or 2 with one `workflow-report:` line on stderr for bad input):

  workflow_report.py repository [--dir <path>]            {"repository": "host/owner/name" | null}
  workflow_report.py definition [--file <path>] [--canonical]   {"id", "version", "hash", "bytes"}
"""
import hashlib
import json
import math
import os
import re
import subprocess
import sys

MAX_SAFE_INTEGER = 2 ** 53 - 1
MAX_ATTEMPT = 50
VERDICT_MAX = 200
EVIDENCE_LINE_MAX = 1000
EVIDENCE_MAX_LINES = 40
EVIDENCE_MAX_BYTES = 8192
EVIDENCE_DROPPED = "… more evidence not sent"
BRANCH_MAX = 300
LINK_MAX = 500
REPOSITORY_MAX = 300
OFF_WORDS = ("0", "false", "off", "no")
LINK_KEYS = ("pullRequest", "commit", "comment")

CONTROL = re.compile(r"[\x00-\x1f\x7f]")
SEGMENT = re.compile(r"^[a-z0-9._-]+$")
ITEM = re.compile(r"^I[0-9]+$")
ISO = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$")
LINK = re.compile(r"^https?://([A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?)(?::([0-9]{1,5}))?(?:[/?#]\S*)?$", re.I)
SCHEME = re.compile(r"^([a-z][a-z0-9+.-]*)://(.*)$", re.I)
SCP = re.compile(r"^(?:[^@/\s]+@)?([^:/\s@]{2,}):(.+)$")
HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
DEFAULT_DEFINITION = os.path.join(PLUGIN_ROOT, "workflows", "build.json")


# --- pure functions -------------------------------------------------------------------------

def _refuse_numbers(value, path="$"):
    if isinstance(value, bool) or value is None or isinstance(value, str):
        return
    if isinstance(value, float):
        raise ValueError("%s: a %s is not allowed; use whole numbers" % (
            path, "non-finite number" if not math.isfinite(value) else "float"))
    if isinstance(value, int):
        if abs(value) > MAX_SAFE_INTEGER:
            raise ValueError("%s: an integer above 2^53-1 is not allowed" % path)
        return
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str):
                raise ValueError("%s: every key must be a string" % path)
            _refuse_numbers(item, "%s.%s" % (path, key))
        return
    if isinstance(value, (list, tuple)):
        for index, item in enumerate(value):
            _refuse_numbers(item, "%s[%d]" % (path, index))
        return
    raise ValueError("%s: not a JSON value" % path)


def canonical_json(obj):
    """The canonical form: keys sorted by code point, no spaces, non-ASCII left as it is, UTF-8."""
    _refuse_numbers(obj)
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def definition_hash(definition):
    """Lower-case hex sha256 of the canonical form: the one name of a workflow definition."""
    return hashlib.sha256(canonical_json(definition)).hexdigest()


def normalize_repository(url):
    """`host/owner/name` in lower case from a git remote address, or None for anything refused.
    No scheme, no user or password, no port, no trailing `.git` or slash."""
    if not isinstance(url, str):
        return None
    text = url.strip()
    if not text or CONTROL.search(text) or " " in text:
        return None
    scheme = SCHEME.match(text)
    if scheme:
        if scheme.group(1).lower() not in ("https", "http", "ssh", "git", "git+ssh"):
            return None
        authority, _, path = scheme.group(2).partition("/")
        host = authority.rsplit("@", 1)[-1]
        host = re.sub(r":[0-9]*$", "", host)
    else:
        scp = SCP.match(text)
        if not scp or text.startswith((".", "~")) or re.match(r"^[A-Za-z]:\\", text):
            return None
        host, path = scp.group(1), scp.group(2)
    path = re.sub(r"\.git$", "", path.strip("/").lower())
    segments = [host.lower()] + [part for part in path.split("/")]
    if not 3 <= len(segments) <= 6 or not all(SEGMENT.match(part) and part.strip(".") for part in segments):
        return None
    name = "/".join(segments)
    return name if len(name) <= REPOSITORY_MAX else None


def _one_line(value):
    """One line of plain text: control characters and half-characters gone, white space collapsed."""
    value = value.encode("utf-8", "replace").decode("utf-8")
    return re.sub(r"\s+", " ", CONTROL.sub(" ", value)).strip()


def _units(value):
    """Length as the receiving side counts it: UTF-16 code units, where an emoji is two."""
    return len(value.encode("utf-16-le")) // 2


def _clip(value, limit):
    while _units(value) > limit:
        value = value[:-1]
    return value


def _cut(value, limit):
    return value if _units(value) <= limit else _clip(value, limit - 1).rstrip() + "…"


def clip(value, limit):
    """Text cut to `limit` characters as the receiving side counts them, half-characters gone."""
    return _clip(value.encode("utf-8", "replace").decode("utf-8"), limit) if isinstance(value, str) else ""


def clean_text(value, limit):
    """One line of plain text, cut to `limit`: what every short field of a run's history carries."""
    return _clip(_one_line(value), limit) if isinstance(value, str) else ""


def clean_verdict(s):
    """The first line, control characters turned into spaces, white space collapsed, at most 200."""
    if not isinstance(s, str):
        return ""
    for line in re.split(r"[\r\n]+", s):
        cleaned = _one_line(line)
        if cleaned:
            return _cut(cleaned, VERDICT_MAX)
    return ""


def clean_evidence(lines):
    """At most 40 lines of at most 1000 characters and 8,192 UTF-8 bytes in all; when anything is
    dropped the last kept line says so."""
    if isinstance(lines, str):
        lines = [lines]
    if not isinstance(lines, (list, tuple)):
        return []
    cleaned = [_cut(_one_line(line), EVIDENCE_LINE_MAX) for line in lines if isinstance(line, str)]
    cleaned = [line for line in cleaned if line]
    kept, used = [], 0
    for line in cleaned:
        size = len(line.encode("utf-8"))
        if len(kept) == EVIDENCE_MAX_LINES or used + size > EVIDENCE_MAX_BYTES:
            break
        kept.append(line)
        used += size
    if len(kept) < len(cleaned):
        marker = len(EVIDENCE_DROPPED.encode("utf-8"))
        while kept and (len(kept) >= EVIDENCE_MAX_LINES or used + marker > EVIDENCE_MAX_BYTES):
            used -= len(kept.pop().encode("utf-8"))
        kept.append(EVIDENCE_DROPPED)
    return kept


def _clean_link(value):
    if not isinstance(value, str) or CONTROL.search(value) or value != _one_line(value) or _units(value) > LINK_MAX:
        return None
    match = LINK.match(value)
    if not match or "\\" in value or (match.group(2) and int(match.group(2)) > 65535):
        return None
    host = match.group(1)
    if re.match(r"^[0-9.]+$", host) and not (re.match(r"^[0-9]{1,3}(\.[0-9]{1,3}){3}$", host) and all(int(p) <= 255 for p in host.split("."))):
        return None
    return value


def clean_links(links):
    """Web addresses the step produced (http or https, no user or password, at most 500) and its
    branch name (at most 300). Anything else is dropped."""
    out = {}
    if not isinstance(links, dict):
        return out
    for key in LINK_KEYS:
        link = _clean_link(links.get(key))
        if link:
            out[key] = link
    branch = links.get("branch")
    if isinstance(branch, str) and _one_line(branch):
        out["branch"] = _clip(_one_line(branch), BRANCH_MAX)
    return out


# --- the command line: the environment and git live only below ------------------------------

class Usage(Exception):
    pass


def _read_definition(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except OSError as error:
        raise Usage("cannot read %s: %s" % (path, error.strerror or error))
    except (ValueError, RecursionError):
        raise Usage("%s is not JSON" % path)


def read_repository(folder="."):
    """The remote named origin, else the only remote, normalized; None when there is none."""
    def git(*args):
        try:
            out = subprocess.run(["git", "-C", folder] + list(args), capture_output=True, text=True, encoding="utf-8",
                                 errors="replace", timeout=5)
        except Exception:
            return None
        return out.stdout.strip() if out.returncode == 0 else None
    remotes = (git("remote") or "").split()
    name = "origin" if "origin" in remotes else (remotes[0] if len(remotes) == 1 else None)
    return normalize_repository(git("remote", "get-url", name)) if name else None


def switched_off(config, env):
    """The one switch for everything a workflow run tells DevStride. `config` is the `workflows` value
    of .claude/ds-config.json ({} when the key is absent): null or false is off, and so is the
    machine variable DEVSTRIDE_WORKFLOWS set to 0, false, off or no."""
    return config is None or config is False or (env.get("DEVSTRIDE_WORKFLOWS") or "").strip().lower() in OFF_WORDS


def command_definition(argv):
    path, canonical = DEFAULT_DEFINITION, False
    while argv:
        flag = argv.pop(0)
        if flag == "--file" and argv:
            path = argv.pop(0)
        elif flag == "--canonical":
            canonical = True
        else:
            raise Usage("usage: workflow_report.py definition [--file <path>] [--canonical]")
    document = _read_definition(path)
    try:
        text = canonical_json(document)
    except (ValueError, UnicodeError, RecursionError) as error:
        raise Usage(str(error))
    described = document if isinstance(document, dict) else {}
    out = {"id": described.get("id"), "version": described.get("version"),
           "hash": definition_hash(document), "bytes": len(text)}
    if canonical:
        out["canonical"] = text.decode("utf-8")
    return out


def main(argv, env=None):
    env = os.environ if env is None else env
    command, rest = (argv[0] if argv else None), list(argv[1:])
    try:
        if command == "repository" and (not rest or (len(rest) == 2 and rest[0] == "--dir")):
            out = {"repository": read_repository(rest[1] if rest else ".")}
        elif command == "definition":
            out = command_definition(rest)
        else:
            raise Usage("usage: workflow_report.py repository [--dir <path>] | definition [--file <path>] [--canonical]")
    except Usage as error:
        print("workflow-report: %s" % error, file=sys.stderr)
        return 2
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
