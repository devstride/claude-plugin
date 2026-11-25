#!/usr/bin/env python3
"""hooks/presence-report.py — the built-in session reporter: one report to DevStride, with the API
key the machine's DevStride connection already carries. hooks/presence.py runs it for every session
whose repository names no presence command of its own (skills/setup/references/session-presence.md).

  (no argument)  send the report the PRESENCE_* variables describe: one call of the tool
                 `report_session_presence`, one attempt, 15 seconds at most. Prints nothing.
                 Exit 0: sent (the answers recorded, ended, stale and not-owner are all ordinary),
                 or nothing to send (no session id, an unknown event). Exit 3: refused for now (the
                 server has no such tool, HTTP 401 or 403, an address that is not DevStride's): the
                 hook waits 30 minutes. Exit 4: a failure that may pass (unreachable, a timeout,
                 HTTP 429 or 5xx, a redirect, any other error answer, no key found just now, or
                 anything unexpected): the hook waits 2 minutes.
  check          no network, never a value. Line 1: `AGENT CONNECTION: READY (key from …)` or
                 `AGENT CONNECTION: NOT READY (…)`, the latter followed by a `Fix: …` line. Then
                 `PRESENCE: ON (built-in reporter | repository command)` or `PRESENCE: OFF (<reason>)`,
                 then `INTERVAL: <n> minute(s)` (`INTERVAL: none` when off). Always exit 0.
  prove          sends a start then an end for a throwaway session and prints one `PROOF: …` line.
                 Run only after the person's typed yes. Exit 0 only for `PROOF: ok`.

What is sent, and nothing else: event, sessionId, state, machine, label (the session's own name),
branch, checkout (the folder's base name, never a path), item, pluginVersion, intervalMinutes,
reportedAt, activeAt, busySince, endReason, renameApplied. Never session text, a prompt, a file's
content, a path or the machine's address.

A rename someone asked for on the Agent Fleet comes back on a recorded answer as `rename` (the name
and when it was asked for). The reporter keeps it on this machine
(skills/build-item/scripts/session_rename.py), where hooks/session-title.py sets it as the session's
own title at the next prompt; once the session's name is the one asked for, or the title hook has
set it, every report carries the request's time as `renameApplied`, so the server stops asking. A recorded answer with no request
removes the kept one, and so does an end; any other answer keeps it. Keeping it never changes the
exit code. The key is found by skills/build-item/scripts/devstride_connection.py and
goes only to a DevStride API host; it is never printed, logged, or taken from or put on a command
line. python3 and the standard library only.
"""
import os
import re
import secrets
import sys

sys.dont_write_bytecode = True  # never leave compiled files in the installed plugin
HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "skills/build-item/scripts"))
sys.path.insert(0, HERE)
try:
    import claim_record  # noqa: E402
    import devstride_connection as connection  # noqa: E402
    import presence  # noqa: E402  hooks/presence.py: the owner-checking reader and the checkout's root
    import presence_settings  # noqa: E402
    import session_rename  # noqa: E402  the rename asked for on the Agent Fleet, kept for the title hook
    UNLOADED = None
except Exception as error:  # a helper this system cannot run: main() says so in its own words
    UNLOADED = type(error).__name__

TOOL = "report_session_presence"
# Seconds one call may take. Tests shorten it; nothing else sets DEVSTRIDE_PRESENCE_TIMEOUT.
try:
    TIMEOUT = min(15.0, max(0.1, float(os.environ.get("DEVSTRIDE_PRESENCE_TIMEOUT") or 15)))
except ValueError:
    TIMEOUT = 15.0
EVENTS = ("start", "beat", "end")
STATES = ("starting", "working", "waiting")
OUTCOMES = ("recorded", "ended", "stale", "not-owner")
SESSION_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$")
STAMP = re.compile(r"^[0-9]{1,16}$")
CONTROL = re.compile(r"[\x00-\x1f\x7f]")
LONG, NAME, SHORT = 500, 200, 64
FIX = "Fix: /devstride:setup connect"
SOURCES = {"environment": "key from the environment", "connection-project": "key from the devstride connection, this project",
           "connection-user": "key from the devstride connection, user level"}
EXIT_REFUSED, EXIT_TRANSIENT = 3, 4


def clean(value, limit):
    """Control characters become spaces, trimmed, cut to `limit`; None when nothing is left."""
    if not isinstance(value, str):
        return None
    return CONTROL.sub(" ", value).strip()[:limit].strip() or None


def body_from(environ):
    """The report the PRESENCE_* variables describe, or None when there is nothing to send. Pure."""
    event = (environ.get("PRESENCE_EVENT") or "").strip()
    session = (environ.get("PRESENCE_SESSION_ID") or "").strip()
    if event not in EVENTS or not SESSION_ID.match(session):
        return None
    body = {"event": event, "sessionId": session}
    state = (environ.get("PRESENCE_STATE") or "").strip()
    if event != "end" and state in STATES:
        body["state"] = state
    checkout = clean(environ.get("PRESENCE_CHECKOUT"), 4096)
    texts = (("machine", environ.get("PRESENCE_MACHINE"), NAME), ("label", claim_record.session_name(environ), NAME),
             ("branch", environ.get("PRESENCE_BRANCH"), LONG),
             ("checkout", os.path.basename(checkout.rstrip("/")) if checkout else None, LONG),
             ("item", environ.get("PRESENCE_ITEM"), SHORT), ("pluginVersion", environ.get("PRESENCE_PLUGIN_VERSION"), SHORT),
             ("endReason", environ.get("PRESENCE_END_REASON") if event == "end" else None, SHORT))
    for name, value, limit in texts:
        value = clean(value, limit)
        if value:
            body[name] = value
    interval = (environ.get("PRESENCE_INTERVAL_MINUTES") or "").strip()
    if interval.isdigit() and 1 <= int(interval) <= 60:
        body["intervalMinutes"] = int(interval)
    stamps = (("reportedAt", "PRESENCE_AT"), ("activeAt", "PRESENCE_ACTIVE_AT")) + (
        (("busySince", "PRESENCE_BUSY_SINCE"),) if event != "end" else ())
    for name, variable in stamps:
        value = (environ.get(variable) or "").strip()
        if STAMP.match(value):
            body[name] = int(value)
    return body


def places(environ):
    """(the repository root or None, the project keys to look under) for this process."""
    try:
        here = os.getcwd()
    except OSError:
        here = None  # the directory is gone
    start = environ.get("PRESENCE_CHECKOUT") or here
    top = presence.repo_top(start) if start else None
    return top, connection.project_places(top, here)


def credentials(environ):
    return connection.credentials(environ, connection.config_file(environ), places(environ)[1])


def deliver(body, creds):
    """Send one report; (the exit code the hook reads, the server's answer or None)."""
    try:
        answer = connection.call_tool(TOOL, body, creds, timeout=TIMEOUT, attempts=1)
    except (connection.Absent, connection.Refused):
        return EXIT_REFUSED, None
    except connection.Problem:
        return EXIT_TRANSIENT, None
    outcome = answer.get("outcome") if isinstance(answer, dict) else None
    return (0, answer) if outcome in OUTCOMES else (EXIT_TRANSIENT, None)


def with_rename_applied(body):
    """The body, carrying `renameApplied` when the session already has the name a kept request asked for."""
    try:
        if body["event"] != "end":
            kept = session_rename.read(body["sessionId"])
            # taken: the session carries the name, or the title hook set it (a person may have renamed it since)
            if kept and (session_rename.same(body.get("label"), kept["name"])
                         or session_rename.applied(body["sessionId"]) == kept["at"]):
                return dict(body, renameApplied=kept["at"])
    except Exception:
        pass  # the report stands without it
    return body


def keep_rename(body, answer):
    """Keep, replace or drop the session's waiting rename after an answer; never raises."""
    try:
        sid = body["sessionId"]
        if body["event"] == "end":
            session_rename.remove(sid)
            return
        if not isinstance(answer, dict) or answer.get("outcome") != "recorded":
            return  # an answer that is not a renewal says nothing about the request
        asked = session_rename.request_of(answer)
        if asked:
            session_rename.write(sid, asked[0], asked[1])
        else:
            session_rename.remove(sid)
    except Exception:
        pass  # a convenience for the session's name; the report stands without it


def report(environ):
    body = body_from(environ)
    if body is None:
        return 0
    try:
        creds = credentials(environ)
    except connection.BadAddress:
        return EXIT_REFUSED  # an address that is not DevStride's: nothing to try again soon
    except connection.Problem:
        return EXIT_TRANSIENT  # no key just now (a file being rewritten): the keeper leaves if it stays so
    body = with_rename_applied(body)
    code, answer = deliver(body, creds)
    if code == 0 or body["event"] == "end":  # an ended session waits on no rename, whatever the answer
        keep_rename(body, answer)
    return code


def check(environ):
    top, where = places(environ)
    path = connection.config_file(environ)
    word = connection.readiness(environ, path, where)
    if word in SOURCES:
        print("AGENT CONNECTION: READY (%s)" % SOURCES[word])
    elif word == "bad-address":
        print("AGENT CONNECTION: NOT READY (DEVSTRIDE_BASE_URL is not a DevStride API address)")
        print("Fix: unset DEVSTRIDE_BASE_URL, or set it to https://api.devstride.com")
    else:
        unsafe = connection.unsafe_reason(environ, path, where) if word == "unsafe-config" else None
        if unsafe is not None:
            print("AGENT CONNECTION: NOT READY (Claude Code's configuration file cannot be read safely: %s)" % unsafe.reason)
        else:
            print("AGENT CONNECTION: NOT READY (no API key: browser sign-in only, or no devstride connection)")
        print(FIX)
    conf, reason = presence_settings.effective(top, presence.read_json, environ, lambda: word in SOURCES)
    if conf:
        print("PRESENCE: ON (%s)" % ("repository command" if conf["mode"] == "command" else "built-in reporter"))
        print("INTERVAL: %d minute(s)" % conf["intervalMinutes"])
    else:
        print("PRESENCE: OFF (%s)" % reason)
        print("INTERVAL: none")
    return 0


def prove(environ):
    try:
        creds = credentials(environ)
    except connection.Missing:
        print("PROOF: NOT READY (the DevStride connection carries no API key)")
        return 1
    except connection.Problem as error:
        print("PROOF: FAILED (%s)" % connection.scrub(error.text))
        return 1
    hidden = [creds[name] for name in connection.CREDENTIAL_NAMES[:4] if creds.get(name)]
    hidden += [value.upper() for value in hidden] + [value.lower() for value in hidden]
    session = "setup-check-" + secrets.token_hex(4)
    base = {"sessionId": session, "machine": clean(claim_record.machine_name(environ), NAME) or "unknown"}
    try:
        for extra in ({"event": "start", "state": "starting"}, {"event": "end", "endReason": "setup-check"}):
            answer = connection.call_tool(TOOL, dict(base, **extra), creds, timeout=TIMEOUT, attempts=1)
            if not isinstance(answer, dict) or answer.get("outcome") not in OUTCOMES:
                print("PROOF: FAILED (the server gave an answer this plugin does not know)")
                return 1
    except connection.Absent:
        print("PROOF: NOT AVAILABLE (the server has no live status yet)")
        return 1
    except connection.Refused as error:
        print("PROOF: REFUSED (%s: the key, secret and organization id must belong together)" % error.text)
        return 1
    except connection.Unavailable as error:
        if error.unreachable:
            print("PROOF: UNREACHABLE")
        else:
            print("PROOF: FAILED (%s)" % connection.scrub(error.detail or error.text, hidden))
        return 1
    print("PROOF: ok")
    return 0


def unloaded(argv):
    """What each mode answers when the plugin's own helpers could not load on this system."""
    if argv == ["check"]:
        print("AGENT CONNECTION: NOT READY (the plugin's helpers could not load on this system: %s)" % UNLOADED)
        print("Fix: update the devstride plugin")
        print("PRESENCE: OFF (helpers-unavailable)")
        print("INTERVAL: none")
        return 0
    if argv == ["prove"]:
        print("PROOF: FAILED (the plugin's helpers could not load on this system: %s)" % UNLOADED)
        return 1
    return EXIT_TRANSIENT if not argv else 2


def main(argv):
    try:
        if UNLOADED:
            return unloaded(argv)
        if not argv:
            return report(os.environ)
        if argv == ["check"]:
            return check(os.environ)
        if argv == ["prove"]:
            return prove(os.environ)
        print("usage: presence-report.py [check|prove]", file=sys.stderr)
        return 2
    except Exception:
        return EXIT_TRANSIENT if not argv else 1  # nothing was sent: never recorded as a report that went


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
