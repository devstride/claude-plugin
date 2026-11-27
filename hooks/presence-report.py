#!/usr/bin/env python3
"""hooks/presence-report.py — the built-in session reporter: one report to DevStride, with the API
key the machine's DevStride connection already carries, else with the machine's session reporter
credential (skills/build-item/scripts/reporter_credential.py). hooks/presence.py runs it for every session
whose repository names no presence command of its own, and its `stop-sync` for every session,
whichever reporter it has (skills/setup/references/session-presence.md).

  (no argument)  send the report the PRESENCE_* variables describe: one call of the tool
                 `report_session_presence`, one attempt, 15 seconds at most. Prints nothing.
                 Exit 0: sent (the answers recorded, ended, stale and not-owner are all ordinary),
                 or nothing to send (no session id, an unknown event). Exit 3: refused for now (the
                 server has no such tool, HTTP 401 or 403, an address that is not DevStride's): the
                 hook waits 30 minutes. Exit 4: a failure that may pass (unreachable, a timeout,
                 HTTP 429 or 5xx, a redirect, any other error answer, no key found just now, a
                 session reporter credential DevStride no longer knows, now set aside so the next
                 DevStride skill registers a new one, or anything unexpected): the hook waits 2
                 minutes.
  check          no network, never a value. Line 1: `AGENT CONNECTION: READY (key from …)`,
                 `AGENT CONNECTION: READY (session reporter, registered for <username>)` or
                 `AGENT CONNECTION: NOT READY (…)`, the latter followed by a `Fix: …` line. Then
                 `PRESENCE: ON (built-in reporter | repository command)` or `PRESENCE: OFF (<reason>)`,
                 then `INTERVAL: <n> minute(s)` (`INTERVAL: none` when off). Always exit 0.
  prove          sends a start then an end for a throwaway session and prints one `PROOF: …` line.
                 Run only after the person's typed yes. Exit 0 only for `PROOF: ok`.
  stop-sync      ask once whether a person stopped the session PRESENCE_SESSION_ID names: one call
                 of the tool `sync_session_stop`, one attempt, 10 seconds at most. Prints nothing.
                 The answer is kept on this machine (skills/build-item/scripts/session_stop.py),
                 where hooks/stop-gate.py and the step runner read it: no stop removes the record;
                 a stop this machine does not hold is kept, and one more call at once tells the
                 server this machine heard it (`acknowledged`, the stop's id); a kept stop not yet
                 acknowledged is acknowledged by this call. Only a definite answer changes the
                 record: an error, a timeout or an answer this plugin does not know keeps it as it
                 is, so an unreachable server never stops a session and never lets one go on.
                 Exit codes as for a report: 0, 3 refused for now, 4 a failure that may pass.
  identity       prints `KEY USER: <username>`, the DevStride member the reporting key belongs to: for
                 the session reporter credential, the name stored with it (no network); for any
                 other key, the username one `whoami` call made with that key answers. `KEY USER:
                 unknown (<reason>)` when it cannot be told. Never a key or secret. Exit 0.

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
exit code. A recorded answer may also carry `stop`, a stop a person asked for on the Agent Fleet:
it is kept as the stop check keeps one, and only the stop check acknowledges or removes it.
The key is found by skills/build-item/scripts/devstride_connection.py and
goes only to a DevStride API host; a secret is never printed, logged, or taken from or put on a
command line (a key's public id alone opens nothing). python3 and the standard library only.
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
    import session_stop  # noqa: E402  the stop asked for on the Agent Fleet, kept for the gate and the step runner
    UNLOADED = None
except Exception as error:  # a helper this system cannot run: main() says so in its own words
    UNLOADED = type(error).__name__

TOOL = "report_session_presence"
STOP_TOOL = "sync_session_stop"
# Seconds one call may take. Tests shorten it; nothing else sets DEVSTRIDE_PRESENCE_TIMEOUT.
try:
    TIMEOUT = min(15.0, max(0.1, float(os.environ.get("DEVSTRIDE_PRESENCE_TIMEOUT") or 15)))
except ValueError:
    TIMEOUT = 15.0
STOP_TIMEOUT = min(10.0, TIMEOUT)  # seconds one stop check's call may take
EVENTS = ("start", "beat", "end")
STATES = ("starting", "working", "waiting")
OUTCOMES = ("recorded", "ended", "stale", "not-owner")
SESSION_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$")
STAMP = re.compile(r"^[0-9]{1,16}$")
CONTROL = re.compile(r"[\x00-\x1f\x7f]")
LONG, NAME, SHORT = 500, 200, 64
FIX = "Fix: /devstride:setup connect"
SOURCES = {"environment": "key from the environment", "connection-project": "key from the devstride connection, this project",
           "connection-user": "key from the devstride connection, user level", "session-reporter": "session reporter"}
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
    return connection.credentials(environ, connection.config_file(environ), places(environ)[1], reporter=True)


def reporter_user(environ):
    """The username stored with the session reporter credential, or None."""
    try:
        import reporter_credential
        stored = reporter_credential.read(environ)
    except Exception:
        return None
    return clean(stored["username"], NAME) if stored else None


# The hosted MCP address takes the organization's slug from the reporter's headers, so it checks no
# credential before the tool runs: a refused key comes back as the tool's own error text
# (packages/mcp/src/describe-error.ts, registry.ts), not as an HTTP 401. The API's authorizer refuses a
# key it does not know with the gateway's bare body, "Unauthorized" or "Forbidden", which the tool error
# opens with, followed by the organization line; an API refusal of a known key names its reason instead.
# A session reporter key asks only for what its policy allows (presence reports and stop checks), so for
# it a bare gateway refusal means DevStride no longer accepts the key.
TOOL_UNAUTHORIZED = re.compile(r"^(DevStride 401\b|(Unauthorized|Forbidden) \u2014 this session sends every request to\b)")


def unauthorized(error):
    """Whether DevStride said this key is not one it knows: HTTP 401 on the address, or the tool error a
    401 or the gateway's bare refusal opens with. An HTTP 403, or a refusal that names its reason, is
    not: the key is known, and the refusal is about what it asked for."""
    if isinstance(error, connection.Refused):
        return error.code == 401
    return isinstance(error, connection.Unavailable) and bool(TOOL_UNAUTHORIZED.match(error.detail or ""))


def drop_refused_reporter(creds, error, environ):
    """Set the session reporter credential aside when DevStride no longer knows it; True when it was."""
    if creds.get("source") != "session-reporter" or not unauthorized(error):
        return False
    import reporter_credential
    return reporter_credential.set_aside(environ)


def deliver(body, creds, environ=None):
    """Send one report; (the exit code the hook reads, the server's answer or None). A session
    reporter credential DevStride no longer knows is set aside, so the machine asks to register again
    instead of staying off the Fleet for good."""
    try:
        answer = connection.call_tool(TOOL, body, creds, timeout=TIMEOUT, attempts=1)
    except connection.Problem as error:
        # a credential set aside is not a refusal to wait out: the next DevStride skill registers a new
        # one, and a 30-minute quiet would keep running sessions off the Fleet after it does
        if drop_refused_reporter(creds, error, os.environ if environ is None else environ):
            return EXIT_TRANSIENT, None
        if isinstance(error, (connection.Absent, connection.Refused)):
            return EXIT_REFUSED, None
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


def keep_stop(body, answer):
    """Keep a stop a recorded answer carries, for the gate and the step runner; never raises. The
    stop check acknowledges it, and only the stop check removes one."""
    try:
        if not isinstance(answer, dict) or answer.get("outcome") != "recorded":
            return
        sid, stop = body["sessionId"], session_stop.stop_of(answer.get("stop"))
        if not stop:
            return
        kept = session_stop.read(sid)
        heard = bool(kept) and kept.get("id") == stop["id"] and kept.get("acknowledged") is True
        if kept != dict(stop, acknowledged=heard):
            session_stop.write(sid, stop, heard)
    except Exception:
        pass  # the stop check hears of it within seconds


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
    code, answer = deliver(body, creds, environ)
    if code == 0 or body["event"] == "end":  # an ended session waits on no rename, whatever the answer
        keep_rename(body, answer)
    if code == 0:
        keep_stop(body, answer)
    return code


def ask_stop(session, creds, acknowledged):
    """One `sync_session_stop` call. (0, the open stop or None) for a definite answer; otherwise
    (the exit code, None), and nothing may change."""
    body = {"sessionId": session}
    if acknowledged:
        body["acknowledged"] = acknowledged
    try:
        answer = connection.call_tool(STOP_TOOL, body, creds, timeout=STOP_TIMEOUT, attempts=1)
    except (connection.Absent, connection.Refused):
        return EXIT_REFUSED, None
    except connection.Problem:
        return EXIT_TRANSIENT, None
    if not isinstance(answer, dict) or "stop" not in answer:
        return EXIT_TRANSIENT, None
    if answer["stop"] is None:
        return 0, None
    stop = session_stop.stop_of(answer["stop"])
    return (0, stop) if stop else (EXIT_TRANSIENT, None)


def stop_sync(environ):
    """Ask whether a person stopped this session and keep the answer on this machine."""
    session = (environ.get("PRESENCE_SESSION_ID") or "").strip()
    if not session_stop.SESSION_ID.match(session):
        return 0  # no session a stop could be kept for
    try:
        creds = credentials(environ)
    except connection.BadAddress:
        return EXIT_REFUSED
    except connection.Problem:
        return EXIT_TRANSIENT
    kept = session_stop.read(session)
    known = kept.get("id") if kept else None  # an unreadable record names no stop
    heard = bool(known) and kept.get("acknowledged") is True
    for _ in range(2):  # a stop first heard of is kept, then acknowledged at once
        owed = known if known and not heard else None
        code, stop = ask_stop(session, creds, owed)
        if code:
            return code  # only a definite answer changes the record
        if stop is None:
            if kept is not None:  # a person allowed it to continue: the gate tells the session's model
                session_stop.note_lifted(session)
            session_stop.remove(session)  # no stop, or a person allowed the session to continue
            return 0
        # the server took the acknowledgement only for the stop it still holds
        heard = stop["id"] == known and (heard or owed is not None)
        if kept != dict(stop, acknowledged=heard):
            session_stop.write(session, stop, heard)  # also puts back a record removed by hand
        if heard:
            return 0
        kept, known = dict(stop, acknowledged=False), stop["id"]
    return 0


def reporter_fix(unsafe):
    """The Fix line for a session reporter credential that cannot be read safely: only a file, or a
    folder, that is too open is tightened; a link, a file or folder another user owns, or one that
    cannot be read is removed (never changed through a link: for a linked folder, the link itself),
    so the next DevStride skill run sets up a fresh one."""
    if unsafe.reason == "mode too open":
        return "Fix: chmod 600 %s" % unsafe.path
    if unsafe.reason == "folder open to others":
        return "Fix: chmod 700 %s" % os.path.dirname(unsafe.path)
    if unsafe.reason in ("folder not yours", "folder is a link"):
        return "Fix: remove %s; the next DevStride skill run sets up a new one" % os.path.dirname(unsafe.path)
    return "Fix: remove %s; the next DevStride skill run sets up a new one" % unsafe.path


def check(environ):
    top, where = places(environ)
    path = connection.config_file(environ)
    word = connection.readiness(environ, path, where, reporter=True)
    if word == "session-reporter":
        print("AGENT CONNECTION: READY (session reporter, registered for %s)" % (reporter_user(environ) or "unknown"))
    elif word in SOURCES:
        print("AGENT CONNECTION: READY (%s)" % SOURCES[word])
    elif word == "bad-address":
        print("AGENT CONNECTION: NOT READY (DEVSTRIDE_BASE_URL is not a DevStride API address)")
        print("Fix: unset DEVSTRIDE_BASE_URL, or set it to https://api.devstride.com")
    else:
        unsafe = connection.unsafe_reason(environ, path, where, reporter=True) if word == "unsafe-config" else None
        if unsafe is not None and unsafe.kind == "reporter":
            print("AGENT CONNECTION: NOT READY (the session reporter credential cannot be read safely: %s)" % unsafe.reason)
            print(reporter_fix(unsafe))
        elif unsafe is not None:
            print("AGENT CONNECTION: NOT READY (Claude Code's configuration file cannot be read safely: %s)" % unsafe.reason)
            print(FIX)
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


def identity(environ):
    """Who the reporting key belongs to: the stored name for a session reporter credential, else
    one `whoami` call made with the key."""
    try:
        creds = credentials(environ)
    except connection.Problem:
        print("KEY USER: unknown (no key)")
        return 0
    if creds["source"] == "session-reporter":
        print("KEY USER: %s" % (reporter_user(environ) or "unknown (the credential names no member)"))
        return 0
    try:
        answer = connection.call_tool("whoami", {"include": ["identity"]}, creds, timeout=TIMEOUT, attempts=1)
    except connection.Refused:
        print("KEY USER: unknown (the key was refused)")
        return 0
    except connection.Problem:
        print("KEY USER: unknown (DevStride could not be asked)")
        return 0
    who = answer.get("identity") if isinstance(answer, dict) else None
    name = clean(who.get("username"), NAME) if isinstance(who, dict) and isinstance(who.get("username"), str) else None
    print("KEY USER: %s" % (name or "unknown (the answer named no member)"))
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
    if argv == ["identity"]:
        print("KEY USER: unknown (the plugin's helpers could not load on this system: %s)" % UNLOADED)
        return 0
    return EXIT_TRANSIENT if argv in ([], ["stop-sync"]) else 2


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
        if argv == ["stop-sync"]:
            return stop_sync(os.environ)
        if argv == ["identity"]:
            return identity(os.environ)
        print("usage: presence-report.py [check|prove|stop-sync|identity]", file=sys.stderr)
        return 2
    except Exception:
        # nothing was sent: never recorded as a report that went, or as a stop check that answered
        return EXIT_TRANSIENT if argv in ([], ["stop-sync"]) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
