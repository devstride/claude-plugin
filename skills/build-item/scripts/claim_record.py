#!/usr/bin/env python3
"""Who is claiming: the record every story claim carries, and the machine and session names every
claim this plugin writes uses — standard library only, no network. The naming rules are here;
`skills/build-item/references/story-claims.md` § The record says when the record is sent.

  python3 claim_record.py [--dir <path>]   prints one JSON object:
      {"machine": "<name>", "sessionName": "<name>" (only when known),
       "payload": {"sessionId": …, "checkout": …, "branch": …, "pluginVersion": …}}
      every payload key always present, null when unknown. Exit 1 (one line on stderr) when the
      machine has no usable name.
  python3 claim_record.py machine          prints the machine name alone.

The machine name is DEVSTRIDE_MACHINE_NAME (the fleet name a repository's machine setup records),
else the hostname without a trailing `.local`; either is lower-cased, every run of characters other
than letters, digits and hyphens becomes one hyphen, and leading or trailing hyphens are dropped —
the same rule the product's own command line uses, so both spell a machine the same way. The session
name is the Claude Code session's own name (the one `/rename` sets), else DEVSTRIDE_SESSION.
"""
import json
import os
import re
import socket
import subprocess
import sys

NAME_MAX = 200
UNSAFE = re.compile(r"[\x00-\x1f\x7f|]")
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
PLUGIN_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))


def machine_name(env=None, hostname=None):
    env = os.environ if env is None else env
    raw = env.get("DEVSTRIDE_MACHINE_NAME") or re.sub(r"\.local$", "", hostname if hostname is not None else socket.gethostname())
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9-]+", "-", raw.lower()))


def displayable(value):
    if not isinstance(value, str):
        return None
    cleaned = re.sub(r"\s+", " ", UNSAFE.sub(" ", value)).strip()[:NAME_MAX].strip()
    return cleaned or None


def session_id(env):
    return env.get("CLAUDE_CODE_SESSION_ID") or env.get("CODEX_THREAD_ID") or None


def session_name(env, home=None):
    """The Claude Code session's name from its own record (~/.claude/sessions/<pid>.json), the one
    for CLAUDE_PID first, then any naming this session id; else DEVSTRIDE_SESSION."""
    sid = env.get("CLAUDE_CODE_SESSION_ID")
    if sid:
        folder = os.path.join(home or os.path.expanduser("~"), ".claude", "sessions")
        pid = env.get("CLAUDE_PID") or ""
        try:
            entries = sorted(e for e in os.listdir(folder) if e.endswith(".json"))
        except OSError:
            entries = []
        first = [pid + ".json"] if re.match(r"^[0-9]+$", pid) else []
        for entry in first + [e for e in entries if e not in first]:
            try:
                with open(os.path.join(folder, entry)) as handle:
                    record = json.load(handle)
            except (OSError, ValueError):
                continue
            if isinstance(record, dict) and record.get("sessionId") == sid:
                name = displayable(record.get("name"))
                if name:
                    return name
    return displayable(env.get("DEVSTRIDE_SESSION"))


def git(folder, *args):
    try:
        out = subprocess.run(["git", "-C", folder] + list(args), capture_output=True, text=True, timeout=5)
        return (out.stdout.strip() or None) if out.returncode == 0 else None
    except Exception:
        return None


def plugin_version(root=PLUGIN_ROOT):
    try:
        with open(os.path.join(root, ".claude-plugin", "plugin.json")) as handle:
            version = json.load(handle).get("version")
    except (OSError, ValueError, AttributeError):
        return None
    return version if isinstance(version, str) and SEMVER.match(version) else None


def record(folder=".", env=None, home=None):
    env = os.environ if env is None else env
    machine = machine_name(env)
    if not machine:
        raise ValueError("cannot work out this machine's name — set DEVSTRIDE_MACHINE_NAME")
    top = git(folder, "rev-parse", "--show-toplevel")
    out = {"machine": machine}
    name = session_name(env, home)
    if name:
        out["sessionName"] = name
    out["payload"] = {
        "sessionId": session_id(env),
        "checkout": os.path.basename(top) if top else None,
        "branch": git(top, "symbolic-ref", "--short", "-q", "HEAD") if top else None,
        "pluginVersion": plugin_version(),
    }
    return out


def main(argv):
    try:
        if argv[:1] == ["machine"] and len(argv) == 1:
            name = machine_name()
            if not name:
                raise ValueError("cannot work out this machine's name — set DEVSTRIDE_MACHINE_NAME")
            print(name)
            return 0
        if argv and argv[0] != "--dir" or len(argv) not in (0, 2):
            print("claim-record: usage: claim_record.py [--dir <path>] | machine", file=sys.stderr)
            return 2
        print(json.dumps(record(argv[1] if argv else ".")))
        return 0
    except ValueError as error:
        print("claim-record: %s" % error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
