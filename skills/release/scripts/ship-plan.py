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
           A plan: {"startedAt", "waitUntil", "members": [{"unit", "session", "machine", "stage",
           "readyBy", "result"?: "carried"|"missed"}], "minutesWaited"?: n}. Once made it is never
           widened: no member is added and waitUntil never moves later. `go` with a plan carries each
           member's result and the minutes waited.
  peer     stdin {"unit": "I20130", "response": <the release-train claim row, or null>, "now", "tz"}
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
MARKER = re.compile(r"<!--\s*devstride:release-gather waited ([0-9]{1,4}) carried (\S+) missed (\S+)\s*-->")
MAX_MEMBERS = 20


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
    return re.sub(r"[\x00-\x1f\x7f-\x9f  ]", " ", value).strip()[:limit] if isinstance(value, str) else ""


def live(row, now, parse):
    if not isinstance(row, dict) or row.get("releasedAt") or row.get("state") in ("released", "expired"):
        return False
    expires = parse(row.get("expiresAt"))
    return bool(expires and expires > now)


def mine(row, me):
    session = row.get("session") if isinstance(row.get("session"), dict) else {}
    sid = session.get("sessionId", {}).get("value") if isinstance(session.get("sessionId"), dict) else None
    return row.get("holderDigest") in (me.get("holderDigests") or []) or (sid and sid in (me.get("sessionIds") or []))


def unit_of(row):
    payload = row.get("payload") if isinstance(row.get("payload"), dict) else {}
    unit = payload.get("unit") if isinstance(payload.get("unit"), str) else row.get("key")
    return unit if isinstance(unit, str) and UNIT.fullmatch(unit) else None


def finish(plan, rows, now, parse, why):
    """The plan with each member's result and the minutes waited: carried only when its own
    declaration was released as landed."""
    done = dict(plan)
    members = []
    for member in plan.get("members", []):
        row = rows.get(member.get("unit"))
        carried = bool(row and row.get("releasedAt") and row.get("outcome") == "landed")
        members.append(dict(member, result="carried" if carried else "missed"))
    started = parse(plan.get("startedAt")) or now
    done["members"] = members
    done["minutesWaited"] = max(0, int((now - started).total_seconds() // 60))
    carried = [m["unit"] for m in members if m["result"] == "carried"]
    missed = [m["unit"] for m in members if m["result"] == "missed"]
    said = "Waited %d min for peers: carried %s; missed %s." % (
        done["minutesWaited"], ", ".join(carried) or "none", ", ".join(missed) or "none")
    return {"action": "go", "plan": done, "reason": why, "message": said}


def decide(request):
    claims = story_claim()
    now = claims.parse(request.get("now")) or datetime.now(timezone.utc)
    window = request.get("peerWaitMinutes", 15)
    if isinstance(window, bool) or not isinstance(window, int) or not 0 <= window <= 120:
        raise Refused("peerWaitMinutes must be a whole number from 0 to 120")
    train = request.get("train")
    if not isinstance(train, str) or not train.strip():
        raise Refused("train must name the release train branch")
    me = request.get("me") if isinstance(request.get("me"), dict) else {}
    held = set(u for u in request.get("held") or [] if isinstance(u, str))
    plan = request.get("plan") if isinstance(request.get("plan"), dict) and isinstance(request["plan"].get("members"), list) else None
    listed = request.get("claims")
    unreadable = not isinstance(listed, list)
    rows = {}
    for row in [] if unreadable else listed:
        unit = unit_of(row) if isinstance(row, dict) and row.get("kind", "ship-intent") == "ship-intent" else None
        if unit and (unit not in rows or live(row, now, claims.parse)):
            rows[unit] = row   # a unit's live row wins over an older released one

    if plan is not None:
        # A plan that exists is only ever worked through, never widened.
        until = claims.parse(plan.get("waitUntil")) or now
        if request.get("goNow"):
            return finish(plan, rows, now, claims.parse, "told to go now")
        if request.get("enabled") is False or window == 0:
            return finish(plan, rows, now, claims.parse, "coordination was switched off")
        if unreadable:
            return finish(plan, rows, now, claims.parse, "the declarations could not be read")
        waiting = [m for m in plan["members"] if isinstance(m, dict) and m.get("unit") not in held
                   and live(rows.get(m.get("unit")), now, claims.parse)]
        if not waiting:
            return finish(plan, rows, now, claims.parse, "every peer waited for has landed or dropped off")
        if now >= until:
            return finish(plan, rows, now, claims.parse, "the wait is over")
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
    if unreadable:
        return {"action": "go", "plan": None, "reason": "the declarations could not be read",
                "message": "What other sessions are about to ship could not be read; starting without waiting."}
    cap = now + timedelta(minutes=window)
    members = []
    for unit in sorted(rows):
        row = rows[unit]
        payload = row.get("payload") if isinstance(row.get("payload"), dict) else {}
        ready = claims.parse(payload.get("readyBy"))
        stage = payload.get("stage")
        if (not live(row, now, claims.parse) or mine(row, me) or unit in held
                or payload.get("route") not in ROUTES or payload.get("target") != train):
            continue
        if not (stage in NEARLY or (ready and ready <= cap)):
            continue
        # An estimate already passed says nothing about when: such a peer gets the whole window.
        expected = ready if ready and now < ready <= cap else cap
        members.append(({"unit": unit, "session": text(row.get("sessionName")), "machine": text(row.get("machine")),
                         "stage": text(stage, 20), "readyBy": stamp(ready) if ready else ""}, expected))
    members = members[:MAX_MEMBERS]
    if not members:
        return {"action": "go", "plan": None, "reason": "nobody is nearly ready", "message": ""}
    until = min(cap, max(expected for _, expected in members))
    made = {"startedAt": stamp(now), "waitUntil": stamp(until), "members": [m for m, _ in members]}
    names = ", ".join(m["unit"] for m in made["members"])
    return {"action": "wait", "waitUntil": made["waitUntil"], "plan": made,
            "reason": "%d peer(s) nearly ready: %s" % (len(members), names),
            "message": "Waiting for %s until %s, then releasing with what is on the train." % (names, claims.local(until, request.get("tz")))}


def peer(request):
    claims = story_claim()
    now = claims.parse(request.get("now")) or datetime.now(timezone.utc)
    row = request.get("response")
    row = row.get("claim") if isinstance(row, dict) and isinstance(row.get("claim"), dict) else row
    payload = row.get("payload") if isinstance(row, dict) and isinstance(row.get("payload"), dict) else {}
    plan = payload.get("plan") if isinstance(payload.get("plan"), dict) else {}
    until = claims.parse(plan.get("waitUntil"))
    units = [m.get("unit") for m in plan.get("members") or [] if isinstance(m, dict) and "result" not in m]
    if (not live(row, now, claims.parse) or row.get("phase") != "gathering" or not until or until <= now
            or request.get("unit") not in units):
        return {"member": False, "message": ""}
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
        if not isinstance(unit, str) or not UNIT.fullmatch(unit) or result not in groups:
            raise Refused("every member needs a unit and a result (carried or missed)")
        groups[result].append(unit)
    return "<!-- devstride:release-gather waited %d carried %s missed %s -->" % (
        waited, ",".join(groups["carried"]) or "none", ",".join(groups["missed"]) or "none")


def parse_marker(body):
    found = MARKER.search(body if isinstance(body, str) else "")
    if not found:
        return None
    units = lambda value: [] if value == "none" else [u for u in value.split(",") if UNIT.fullmatch(u)]
    return {"waited": int(found.group(1)), "carried": units(found.group(2)), "missed": units(found.group(3))}


def main(argv):
    if len(argv) != 2 or argv[1] not in ("decide", "peer", "marker", "parse"):
        sys.stderr.write("usage: ship-plan.py decide|peer|marker|parse   (input on stdin)\n")
        return 2
    raw = sys.stdin.read()
    try:
        if argv[1] == "parse":
            print(json.dumps(parse_marker(raw)))
            return 0
        try:
            request = json.loads(raw)
        except ValueError as err:
            raise Refused("stdin is not a JSON object: %s" % err)
        if not isinstance(request, dict):
            raise Refused("stdin is not a JSON object")
        if argv[1] == "marker":
            print(marker(request))
        else:
            print(json.dumps(decide(request) if argv[1] == "decide" else peer(request)))
    except Refused as err:
        sys.stderr.write("ship-plan: %s\n" % err)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
