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
else, on macOS, the Mac's own local name (`scutil --get LocalHostName`, which stays the same on every
network, where the hostname follows the network a Mac joins), else the hostname without a trailing
`.local`; any of them is lower-cased, every run of characters other
than letters, digits and hyphens becomes one hyphen, and leading or trailing hyphens are dropped —
the same spelling rule the product's own command line uses (which names a Mac by its hostname, so
setting DEVSTRIDE_MACHINE_NAME keeps the two the same there). The session
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


_MAC_NAME = []  # the Mac's local name, looked up once per process ("" when it could not be)


def mac_local_name(run=subprocess.run, platform=None):
    """The Mac's LocalHostName (the name it keeps on every network), looked up once per process with
    a 2-second limit; "" off macOS or when the look-up fails."""
    if _MAC_NAME:
        return _MAC_NAME[0]
    if (platform or sys.platform) != "darwin":
        return ""
    if not _MAC_NAME:
        try:
            found = run(["scutil", "--get", "LocalHostName"], capture_output=True, text=True, timeout=2)
            name = found.stdout.strip() if found.returncode == 0 else ""
        except (OSError, subprocess.SubprocessError, ValueError):
            name = ""
        _MAC_NAME.append(name)
    return _MAC_NAME[0]


def machine_name(env=None, hostname=None):
    env = os.environ if env is None else env
    if hostname is None:
        hostname = mac_local_name() or socket.gethostname()
    raw = env.get("DEVSTRIDE_MACHINE_NAME") or re.sub(r"\.local$", "", hostname)
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9-]+", "-", raw.lower()))


def displayable(value):
    if not isinstance(value, str):
        return None
    cleaned = re.sub(r"\s+", " ", UNSAFE.sub(" ", value)).strip()[:NAME_MAX].strip()
    return cleaned or None


def session_id(env):
    return env.get("CLAUDE_CODE_SESSION_ID") or env.get("CODEX_THREAD_ID") or None


def session_name(env, home=None):
    """The Claude Code session's name from its own record (<CLAUDE_CONFIG_DIR, else ~/.claude>/sessions/
    <pid>.json), the one for CLAUDE_PID first, then any naming this session id; else DEVSTRIDE_SESSION."""
    sid = env.get("CLAUDE_CODE_SESSION_ID")
    if sid:
        config = env.get("CLAUDE_CONFIG_DIR") or os.path.join(home or os.path.expanduser("~"), ".claude")
        folder = os.path.join(config, "sessions")
        pid = env.get("CLAUDE_PID") or ""
        try:
            entries = sorted(e for e in os.listdir(folder) if e.endswith(".json"))
        except OSError:
            entries = []
        first = [pid + ".json"] if re.match(r"^[0-9]+$", pid) else []
        for entry in first + [e for e in entries if e not in first]:
            try:
                with open(os.path.join(folder, entry), encoding="utf-8") as handle:
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
        out = subprocess.run(["git", "-C", folder] + list(args), capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=5)
        return (out.stdout.strip() or None) if out.returncode == 0 else None
    except Exception:
        return None


def plugin_version(root=PLUGIN_ROOT):
    try:
        with open(os.path.join(root, ".claude-plugin", "plugin.json"), encoding="utf-8") as handle:
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
