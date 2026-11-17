#!/usr/bin/env python3
"""Whether a session reports its live status, and through what — the one decision the presence
hook, its keeper, the built-in reporter, doctor and setup all share. Pure: no network, no clock,
nothing written. The contract: skills/setup/references/session-presence.md.

  effective(top, read_json, environ, ready) -> (settings, reason)

`settings` is None (nothing runs) or {"mode": "command" | "builtin", "command": str | None,
"intervalMinutes": int}; `reason` is one fixed word. In this order:

  1. DEVSTRIDE_PRESENCE set to 0, false, off or no (any case)  -> off, `machine-off`: nothing runs,
     a repository's own command included.
  2. `presence` present and null in <top>/.claude/ds-config.json -> off, `repo-null`; a config
     file that is there but cannot be read as a JSON object   -> off, `config-unreadable` (a
     broken file must never switch on what the repository switched off).
  3. a block with a `command` key: a non-blank string         -> the repository's command, `command`
     (interval default 5); anything else                      -> off, `command-blank`.
  4. otherwise (no repository, no file, no block, an empty block, a block with only
     `intervalMinutes`, a value that is not an object)        -> the built-in reporter, `builtin`
     (interval default 1); when `ready` is given and says the machine's DevStride connection
     carries no key                                           -> off, `no-key`.

`intervalMinutes` applies to both modes when it is an integer from 1 to 60; anything else reads as
the mode's default. `ready` is a function with no arguments, or None to skip that check.
"""
import os

OFF_WORDS = ("0", "false", "off", "no")
COMMAND_INTERVAL = 5
BUILTIN_INTERVAL = 1
SWITCH = "DEVSTRIDE_PRESENCE"


def interval_of(value, default):
    if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= 60:
        return default
    return value


def effective(top, read_json, environ, ready=None):
    if (environ.get(SWITCH) or "").strip().lower() in OFF_WORDS:
        return None, "machine-off"
    path = os.path.join(top, ".claude", "ds-config.json") if isinstance(top, str) and top else None
    config = read_json(path) if path else None
    if path and not isinstance(config, dict) and os.path.lexists(path):
        return None, "config-unreadable"
    block = None
    if isinstance(config, dict) and "presence" in config:
        block = config["presence"]
        if block is None:
            return None, "repo-null"
    block = block if isinstance(block, dict) else {}
    if "command" in block:
        command = block["command"]
        if not isinstance(command, str) or not command.strip():
            return None, "command-blank"
        return {"mode": "command", "command": command,
                "intervalMinutes": interval_of(block.get("intervalMinutes"), COMMAND_INTERVAL)}, "command"
    if ready is not None and not ready():
        return None, "no-key"
    return {"mode": "builtin", "command": None,
            "intervalMinutes": interval_of(block.get("intervalMinutes"), BUILTIN_INTERVAL)}, "builtin"
