#!/usr/bin/env python3
"""hooks/stop-gate.py — a session someone stopped from DevStride runs no tool and takes no prompt.

A PreToolUse and UserPromptSubmit hook, first in both lists. It only reads the stop record the
session's stop check keeps on this machine (skills/build-item/scripts/session_stop.py; the check is
hooks/presence-report.py stop-sync, run by the session's keeper): no network, no other file.

  - No record: exit 0, nothing printed.
  - A record, on PreToolUse: one JSON object on stdout that refuses the call and ends the turn,
    {"continue": false, "stopReason": <line>, "hookSpecificOutput": {"hookEventName": "PreToolUse",
    "permissionDecision": "deny", "permissionDecisionReason": <line>}}. A helper agent's call
    carries its session's id, so it is refused the same way.
  - A record, on UserPromptSubmit: exit 2 with the line and "Your prompt was not sent." on stderr,
    which is what the person sees; the prompt is discarded.

The line is session_stop.line(): who stopped the session, when (this machine's time), why, and
that a person allows it to continue on Agents → Fleet. A record that exists but cannot be read
counts as a stop. The session is the payload's session_id (else CLAUDE_CODE_SESSION_ID, for a
payload that cannot be read); the event is the payload's hook_event_name (else the first argument).

FAILS OPEN on everything else: a helper that cannot load, no session id, any error. A stop this
machine has not heard of blocks nothing. The contract: skills/setup/references/session-presence.md.
python3 and the standard library only.
"""
import json
import os
import sys

sys.dont_write_bytecode = True  # never leave compiled files in the installed plugin
PAYLOAD_LIMIT = 4 * 1048576   # a prompt hook's payload carries the whole prompt
EVENTS = ("PreToolUse", "UserPromptSubmit")


def stopped(argv):
    """(the event, the line to print) for a stopped session, else None."""
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "skills/build-item/scripts"))
    import portable
    import session_stop
    try:
        payload = json.loads(portable.stdin_text(PAYLOAD_LIMIT) or "{}")
    except Exception:
        payload = None  # cut short or not JSON: the environment still names the session
    payload = payload if isinstance(payload, dict) else {}
    event = payload.get("hook_event_name") or (argv[0] if argv else None)
    session = payload.get("session_id") or os.environ.get("CLAUDE_CODE_SESSION_ID")
    if event not in EVENTS:
        return None
    stop = session_stop.read(session)
    return None if stop is None else (event, session_stop.line(stop))


def main(argv):
    try:
        found = stopped(argv)
    except Exception:
        found = None
    if not found:
        return 0
    event, line = found
    if event == "UserPromptSubmit":
        try:
            sys.stderr.reconfigure(encoding="utf-8", errors="replace")  # the line holds an arrow
        except Exception:
            pass
        sys.stderr.write("devstride: %s Your prompt was not sent.\n" % line)
        return 2
    sys.stdout.write(json.dumps({"continue": False, "stopReason": line, "hookSpecificOutput": {
        "hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": line}}) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
