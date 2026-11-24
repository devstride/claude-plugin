#!/usr/bin/env python3
"""Whether a starting release waits a short, fixed time for work a peer says is nearly ready —
deterministic, standard library only, no network, no git.

The rules are in `skills/release/references/ship-plan.md`. Only the session that holds the
`release-train` claim runs `decide`; the plan it returns is stored on that claim (payload key `plan`,
phase `gathering`), so every session reads the same one. Reading declarations decides how long the
driver waits, never who drives.

  decide   stdin, one JSON object:
             {"now": "<ISO>",                         (optional; the clock when absent)
              "peerWaitMinutes": 15,                  (release.coordination.peerWaitMinutes; 0: never wait)
              "enabled": true,                        (release.coordination.enabled; absent: on)
              "train": "<the release train branch>",
              "me": {"holderDigests": ["<hex>"…], "sessionIds": ["<id>"…]},   (the driver itself)
              "claims": [<ship-intent claim rows, live AND released>] | {"error": "<NAME>"},
              "plan": <the plan already on the release-train claim, or null>,
              "held": ["I20130"…],                    (units under a release hold or waiting for the owner)
              "goNow": false}                         (the person said "go now")
           stdout: {"action": "go"|"wait", "waitUntil"?: "<ISO>", "plan": <plan or null>,
                    "reason": "<one plain line>", "message": "<one plain line, empty when nothing to say>"}
           A plan: {"startedAt", "waitUntil", "windowMinutes", "members": [{"unit", "declaration",
           "session", "machine", "stage", "readyBy", "result"?: "carried"|"missed"}],
           "minutesWaited"?: n}. `declaration` names the one declaration waited for (the store's
           row id), so a later one for the same unit never stands in for it. Once made a plan is
           never widened: no member is added and its end is never later than its start plus its
           window. One read back that cannot be validated is `go`, never a fresh wait; a finished
           one (results, minutes) is no plan. `go` with a plan carries each member's result and
           the minutes waited.
           `claims` may be the list or the store's `{"data": […]}` answer.
  peer     stdin {"unit": "I20130", "declaration"?: "<its row id>", "response": <the release-train
           claim row, or null>, "now", "tz"}
           -> {"member": bool, "message": "<one plain line, empty when not a member>"}
  marker   stdin <a finished plan> -> the one line for the train pull request body:
             <!-- devstride:release-gather waited <minutes> carried <units|none> missed <units|none> -->
  parse    stdin <a pull request body> -> {"waited": n, "carried": […], "missed": […]} or null

Bad input is exit 2 with one `ship-plan:` line on stderr.
"""
import importlib.util
import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone

ROUTES = ("train", "epic-release")      # what can land on the release train
NEARLY = ("verifying", "landing")       # nearly ready whatever the estimate says
UNIT = re.compile(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,199}")
MARKER = re.compile(r"^<!-- devstride:release-gather waited ([0-9]{1,4}) carried (\S+) missed (\S+) -->$", re.M)
MAX_MEMBERS = 20
MAX_WINDOW = 120


class Refused(Exception):
    pass


def story_claim():
    """story-claim.py: the one reader of claim times and holders."""
    sys.dont_write_bytecode = True
    skills = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    path = os.path.join(skills, "build-item/scripts/story-claim.py")
    spec = importlib.util.spec_from_file_location("story_claim", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def stamp(moment):
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def text(value, limit=120):
    return re.sub(r"[\x00-\x1f\x7f-\x9f\u2028\u2029]", " ", value).strip()[:limit] if isinstance(value, str) else ""


def a_unit(value):
    """A unit a plan and the marker can carry: the usual shape, never the marker's own empty word."""
    return isinstance(value, str) and bool(UNIT.fullmatch(value)) and "--" not in value and value != "none"


def live(row, now, parse):
    if not isinstance(row, dict) or row.get("releasedAt") or row.get("state") in ("released", "expired"):
        return False
    expires = parse(row.get("expiresAt"))
    return bool(expires and expires > now)


def mine(row, me):
    digests = me.get("holderDigests") if isinstance(me.get("holderDigests"), list) else []
    sessions = me.get("sessionIds") if isinstance(me.get("sessionIds"), list) else []
    session = row.get("session") if isinstance(row.get("session"), dict) else {}
    sid = session.get("sessionId", {}).get("value") if isinstance(session.get("sessionId"), dict) else None
    return row.get("holderDigest") in digests or (isinstance(sid, str) and sid in sessions)


def declaration(row):
    """What names ONE declaration, so a later one for the same unit never stands in for it: the
    store's own row id, else when it was taken. Never the holder."""
    for key in ("id", "takenAt", "claimedAt"):
        if isinstance(row.get(key), str) and row[key]:
            return text(row[key], 80)
    return ""


def unit_of(row):
    payload = row.get("payload") if isinstance(row.get("payload"), dict) else {}
    unit = payload.get("unit") if isinstance(payload.get("unit"), str) else row.get("key")
    return unit if a_unit(unit) else None


def rows_of(listed):
    """(the ship-intent rows, readable?) from a list answer, bare or wrapped as {"data": […]}."""
    if isinstance(listed, dict) and not listed.get("error") and isinstance(listed.get("data"), list):
        listed = listed["data"]
    if not isinstance(listed, list):
        return [], False
    return [r for r in listed if isinstance(r, dict) and r.get("kind", "ship-intent") == "ship-intent" and unit_of(r)], True


def read_plan(plan, parse):
    """("none" | "finished" | "invalid" | "live", the plan rebuilt from the keys a plan carries).
    A plan read back from a claim is never trusted as it stands, and never copied whole."""
    if plan is None:
        return "none", None
    if not isinstance(plan, dict):
        return "invalid", None
    members = plan.get("members")
    if "minutesWaited" in plan or (isinstance(members, list) and any(isinstance(m, dict) and "result" in m for m in members)):
        # Finished only when it reads as one; anything else that looks half-finished is invalid.
        waited = plan.get("minutesWaited")
        whole = (isinstance(waited, int) and not isinstance(waited, bool) and isinstance(members, list)
                 and all(isinstance(m, dict) and m.get("result") in ("carried", "missed") for m in members))
        return ("finished" if whole else "invalid"), None
    started, until, window = parse(plan.get("startedAt")), parse(plan.get("waitUntil")), plan.get("windowMinutes")
    members = plan.get("members")
    if (not started or not until or isinstance(window, bool) or not isinstance(window, int) or not 1 <= window <= MAX_WINDOW
            or not isinstance(members, list) or not members or len(members) > MAX_MEMBERS):
        return "invalid", None
    kept = []
    for member in members:
        if not isinstance(member, dict) or not a_unit(member.get("unit")) or not isinstance(member.get("declaration"), str) or not member["declaration"]:
            return "invalid", None
        kept.append({"unit": member["unit"], "declaration": text(member["declaration"], 80), "session": text(member.get("session")),
                     "machine": text(member.get("machine")), "stage": text(member.get("stage"), 20), "readyBy": text(member.get("readyBy"), 30)})
    # The end is never later than the start plus the window the plan was made with.
    until = min(until, started + timedelta(minutes=window))
    return "live", {"startedAt": stamp(started), "waitUntil": stamp(until), "windowMinutes": window, "members": kept}


def finish(plan, by_declaration, now, parse, why):
    """The plan with each member's result and the minutes waited: carried only when THAT
    declaration was released as landed."""
    members = []
    for member in plan["members"]:
        row = by_declaration.get((member["unit"], member["declaration"]))
        carried = bool(row and row.get("releasedAt") and row.get("outcome") == "landed")
        members.append(dict(member, result="carried" if carried else "missed"))
    started = parse(plan["startedAt"])
    waited = max(0, min(plan["windowMinutes"], int((now - started).total_seconds() // 60))) if now >= started else 0
    done = dict(plan, members=members, minutesWaited=waited)
    carried = [m["unit"] for m in members if m["result"] == "carried"]
    missed = [m["unit"] for m in members if m["result"] == "missed"]
    said = "Waited %d min for peers: carried %s; missed %s." % (waited, ", ".join(carried) or "none", ", ".join(missed) or "none")
    return {"action": "go", "plan": done, "reason": why, "message": said}


def decide(request):
    claims = story_claim()
    now = claims.parse(request.get("now")) or datetime.now(timezone.utc)
    window = request.get("peerWaitMinutes", 15)
    if isinstance(window, bool) or not isinstance(window, int) or not 0 <= window <= MAX_WINDOW:
        raise Refused("peerWaitMinutes must be a whole number from 0 to %d" % MAX_WINDOW)
    train = request.get("train")
    if not isinstance(train, str) or not train.strip():
        raise Refused("train must name the release train branch")
    me = request.get("me") if isinstance(request.get("me"), dict) else {}
    held = request.get("held", [])
    if not isinstance(held, list) or not all(isinstance(u, str) for u in held):
        raise Refused("held must be a list of units")
    held = set(held)
    rows, readable = rows_of(request.get("claims"))
    by_declaration = {(unit_of(r), declaration(r)): r for r in rows}
    state, plan = read_plan(request.get("plan"), claims.parse)

    if state == "invalid":
        # Never a reason to start a fresh wait: whatever was promised cannot be read any more.
        return {"action": "go", "plan": None, "reason": "the plan on the release-train claim could not be read",
                "message": "The plan to wait for peers could not be read back; starting without waiting."}
    if state == "live":
        # A plan that exists is only ever worked through, never widened.
        started, until = claims.parse(plan["startedAt"]), claims.parse(plan["waitUntil"])
        done = lambda why: finish(plan, by_declaration, now, claims.parse, why)
        if now < started:
            return done("this machine's clock is behind the plan's start")
        if request.get("goNow"):
            return done("told to go now")
        if request.get("enabled") is False or window == 0:
            return done("coordination was switched off")
        if not readable:
            return done("the declarations could not be read")
        if started + timedelta(minutes=window) < until:   # a lowered window shortens, never lengthens,
            until = started + timedelta(minutes=window)   # and the shorter end is the plan's from now on
            plan = dict(plan, waitUntil=stamp(until), windowMinutes=window)
        waiting = [m for m in plan["members"] if m["unit"] not in held
                   and live(by_declaration.get((m["unit"], m["declaration"])), now, claims.parse)]
        if not waiting:
            return done("every peer waited for has landed or dropped off")
        if now >= until:
            return done("the wait is over")
        names = ", ".join(m["unit"] for m in waiting)
        return {"action": "wait", "waitUntil": stamp(until), "plan": plan,
                "reason": "still waiting for %s" % names,
                "message": "Waiting for %s until %s." % (names, claims.local(until, request.get("tz")))}

    if request.get("enabled") is False:
        return {"action": "go", "plan": None, "reason": "coordination is switched off", "message": ""}
    if window == 0:
        return {"action": "go", "plan": None, "reason": "peerWaitMinutes is 0: this release never waits", "message": ""}
    if request.get("goNow"):
        return {"action": "go", "plan": None, "reason": "told to go now", "message": ""}
    if not readable:
        return {"action": "go", "plan": None, "reason": "the declarations could not be read",
                "message": "What other sessions are about to ship could not be read; starting without waiting."}
    cap = now + timedelta(minutes=window)
    newest = {}
    for row in rows:   # one live declaration per unit: the newest
        if live(row, now, claims.parse) and (unit_of(row) not in newest or declaration(row) > declaration(newest[unit_of(row)])):
            newest[unit_of(row)] = row
    members = []
    for unit in sorted(newest):
        row = newest[unit]
        payload = row.get("payload") if isinstance(row.get("payload"), dict) else {}
        ready = claims.parse(payload.get("readyBy"))
        stage = payload.get("stage")
        if mine(row, me) or unit in held or payload.get("route") not in ROUTES or payload.get("target") != train or not declaration(row):
            continue
        # Nearly ready: verifying or landing, or an estimate that falls inside the window. An
        # estimate already passed says nothing; it counts only with one of those two stages.
        inside = bool(ready and now <= ready <= cap)
        if not (stage in NEARLY or inside):
            continue
        members.append(({"unit": unit, "declaration": declaration(row), "session": text(row.get("sessionName")),
                         "machine": text(row.get("machine")), "stage": text(stage, 20), "readyBy": stamp(ready) if ready else ""},
                        ready if inside else cap))
    members = members[:MAX_MEMBERS]
    if not members:
        return {"action": "go", "plan": None, "reason": "nobody is nearly ready", "message": ""}
    until = min(cap, max(expected for _, expected in members))
    made = {"startedAt": stamp(now), "waitUntil": stamp(until), "windowMinutes": window, "members": [m for m, _ in members]}
    names = ", ".join(m["unit"] for m in made["members"])
    return {"action": "wait", "waitUntil": made["waitUntil"], "plan": made,
            "reason": "%d peer(s) nearly ready: %s" % (len(members), names),
            "message": "Waiting for %s until %s, then releasing with what is on the train." % (names, claims.local(until, request.get("tz")))}


def peer(request):
    claims = story_claim()
    now = claims.parse(request.get("now")) or datetime.now(timezone.utc)
    nothing = {"member": False, "message": ""}
    unit, row = request.get("unit"), request.get("response")
    if not a_unit(unit) or not isinstance(row, dict) or row.get("error"):
        return nothing
    row = row.get("claim") if isinstance(row.get("claim"), dict) else row
    payload = row.get("payload") if isinstance(row.get("payload"), dict) else {}
    state, plan = read_plan(payload.get("plan"), claims.parse)
    if row.get("kind") != "release-train" or row.get("phase") != "gathering" or not live(row, now, claims.parse) or state != "live":
        return nothing
    until = claims.parse(plan["waitUntil"])
    mine_is = request.get("declaration")
    member = next((m for m in plan["members"] if m["unit"] == unit and (not isinstance(mine_is, str) or m["declaration"] == mine_is)), None)
    if not member or until <= now or now < claims.parse(plan["startedAt"]):
        return nothing
    where = text(row.get("machine")) or "another machine"
    return {"member": True, "message": "The release on %s is waiting for this until %s." % (where, claims.local(until, request.get("tz")))}


def marker(plan):
    members = plan.get("members") if isinstance(plan, dict) else None
    waited = plan.get("minutesWaited") if isinstance(plan, dict) else None
    if not isinstance(members, list) or isinstance(waited, bool) or not isinstance(waited, int) or not 0 <= waited <= 9999:
        raise Refused("a finished plan carries members and minutesWaited")
    groups = {"carried": [], "missed": []}
    for member in members:
        unit, result = (member.get("unit"), member.get("result")) if isinstance(member, dict) else (None, None)
        if not a_unit(unit) or not isinstance(result, str) or result not in groups:
            raise Refused("every member needs a unit and a result (carried or missed)")
        groups[result].append(unit)
    return "<!-- devstride:release-gather waited %d carried %s missed %s -->" % (
        waited, ",".join(groups["carried"]) or "none", ",".join(groups["missed"]) or "none")


def parse_marker(body):
    """The LAST gather line that stands alone on its line: text quoted inside another line is not one."""
    found = MARKER.findall(body if isinstance(body, str) else "")
    if not found:
        return None
    units = lambda value: [] if value == "none" else [u for u in value.split(",") if a_unit(u)]
    return {"waited": int(found[-1][0]), "carried": units(found[-1][1]), "missed": units(found[-1][2])}


def main(argv):
    if len(argv) != 2 or argv[1] not in ("decide", "peer", "marker", "parse"):
        sys.stderr.write("usage: ship-plan.py decide|peer|marker|parse   (input on stdin)\n")
        return 2
    try:
        try:
            # UTF-8 whatever the code page, newlines as text mode reads them
            raw = sys.stdin.buffer.read().decode("utf-8").replace("\r\n", "\n").replace("\r", "\n")
        except ValueError as err:
            raise Refused("stdin is not text: %s" % err)
        if argv[1] == "parse":
            print(json.dumps(parse_marker(raw)))
            return 0
        try:
            request = json.loads(raw)
        except ValueError as err:
            raise Refused("stdin is not a JSON object: %s" % err)
        if not isinstance(request, dict):
            raise Refused("stdin is not a JSON object")
        try:
            if argv[1] == "marker":
                print(marker(request))
            else:
                print(json.dumps(decide(request) if argv[1] == "decide" else peer(request)))
        except (OverflowError, TypeError, AttributeError, KeyError) as err:
            raise Refused("the request could not be read (%s)" % type(err).__name__)
    except Refused as err:
        sys.stderr.write("ship-plan: %s\n" % err)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
