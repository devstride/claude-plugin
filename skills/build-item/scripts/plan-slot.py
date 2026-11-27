#!/usr/bin/env python3
"""How many agents build one plan at once: what a plan-slot answer means for build-item —
deterministic, standard library only, no network.

The rules are in `skills/build-item/references/parallel-building.md`; Claude follows that document
and any other agent runs this file for the same answer. A claim answer is read by `story-claim.py`
(loaded beside this file, never copied), so both read claims the same way.

  decide  stdin {"mode": "take"|"renew", "root": "I20100", "slot": n, "limit": L,
                 "response": <claim_work answer>, "me": "<my holder digest>", "now"?, "tz"?}
          -> {"action": "proceed"|"next"|"takeover"|"full"|"degrade", "message": "...",
              "nextSlot"?: n, "takeoverDigest"?: "<hex>"}
          `take`: the claim on key <root>#<slot> while looking for a free slot (1..limit).
          `renew`: the claim on this session's own key, found by `mine`; `limit` may be null.
          A `limit` that is null in `take` (an older server without the setting) degrades.
  mine    stdin {"root", "rows": [list_claims rows], "me"}
          -> {"key": "<root>#<n>"|null, "slot": n|null}
  free    stdin {"candidates": ["I20101", ...] in rule order, "rows": [live story claim rows],
                 "me", "now"?, "tz"?, "waiting"?: [{"item", "on"}]}
          -> {"free": [...], "held": [{"item", "by"}], "message": "..."}
  full    stdin {"root", "limit", "rows": [list_claims rows], "now"?, "tz"?}
          -> {"message": "..."}
  room    stdin {"root", "limit", "rows": [live plan-slot rows], "me", "now"?, "tz"?}
          -> {"verdict": "room"|"full", "message": "..."}
          Other holders' live slots counted, whatever their number: a lowered limit holds back new
          agents while one above it still builds (a freed low slot is no room).
  machine stdin {"root", "rows": [live plan-slot rows], "me", "machine", "shared": bool, "slot"?: n,
                 "now"?, "tz"?}
          -> {"verdict": "ok"|"busy", "message": "..."}
          `shared` is true when this repository's checkouts share one local environment (its
          `localEnvironment.instanceBoundTo` is not `directory`): then another holder's live slot on
          this plan from the same machine makes it `busy`, since two agents would test on one database.
          With `slot` (this session's, just won) only a same-machine holder of a LOWER slot counts, so
          two sessions that both looked before claiming settle on one: the higher slot backs out.

A row carries `kind`, `key`, `holderDigest`, `machine`, `sessionName`, `takenAt` (or `claimedAt`),
`expiresAt`, `releasedAt` and `state`; the holder itself never appears, and nothing here prints it.
Bad input exits 2 with one line on stderr and no traceback.
"""
import importlib.util
import json
import os
import re
import sys
from datetime import datetime, timezone

KIND = "plan-slot"
LIMITS = (1, 20)
NUMBER = re.compile(r"^[A-Za-z][0-9]+$")


class Refused(Exception):
    pass


def story_claim():
    """story-claim.py: the one reader of claim answers, times and holders."""
    sys.dont_write_bytecode = True
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "story-claim.py")
    spec = importlib.util.spec_from_file_location("story_claim", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SC = story_claim()


def root_of(request):
    root = request.get("root")
    if not isinstance(root, str) or not NUMBER.match(root):
        raise Refused("root must be an item number such as I20100")
    return root


def key_of(root, slot):
    return "%s#%d" % (root, slot)


def slot_of(key, root):
    if isinstance(key, str) and key.startswith(root + "#") and key[len(root) + 1:].isdigit():
        return int(key[len(root) + 1:])
    return None


def rows_of(request):
    rows = request.get("rows")
    if not isinstance(rows, list) or not all(isinstance(r, dict) for r in rows):
        raise Refused("rows must be a list of claim rows")
    return rows


def a_digest(value):
    if not isinstance(value, str) or not re.match(r"^[a-f0-9]{64}$", value):
        raise Refused("me must be this session's holder digest (64 hex characters)")
    return value


def taken(row):
    return SC.parse(row.get("takenAt") or row.get("claimedAt"))


def live(row, now):
    if row.get("releasedAt") or row.get("state") in ("released", "expired"):
        return False
    return not SC.lapsed(row, now)


def who(row, tz):
    """'alpha on mac-one since 9:14 AM CST on Nov 25': never the holder."""
    name = row.get("sessionName") or "an unnamed session"
    text = name + (" on %s" % row["machine"] if row.get("machine") else "")
    since = taken(row)
    return text + (" since %s" % SC.local(since, tz) if since else "")


def clock(request):
    now = request.get("now")
    if now is not None and SC.parse(now) is None:
        raise Refused("now must be an ISO date-time")
    return SC.parse(now) or datetime.now(timezone.utc)


def decide(request):
    mode = request.get("mode")
    if mode not in ("take", "renew"):
        raise Refused("mode must be take or renew")
    root = root_of(request)
    slot = request.get("slot")
    if not isinstance(slot, int) or isinstance(slot, bool) or slot < 1:
        raise Refused("slot must be a whole number from 1")
    limit = request.get("limit")
    if limit is not None and (not isinstance(limit, int) or isinstance(limit, bool) or not LIMITS[0] <= limit <= LIMITS[1]):
        raise Refused("limit must be a whole number from 1 to 20, or null")
    me = a_digest(request.get("me"))
    now, tz = clock(request), request.get("tz")
    if mode == "take" and limit is None:
        return {"action": "degrade",
                "message": "This DevStride server does not store a parallel-building limit yet; building with no limit."}
    kind, claim, flags = SC.normalise(request.get("response"))
    claim = claim if isinstance(claim, dict) else {}
    if kind.startswith("error:"):
        return {"action": "degrade", "message": SC.DEGRADE[kind.split(":", 1)[1]]}
    of = " of %d" % limit if limit else ""
    if kind in ("won", "ok"):
        if flags.get("takenOver"):
            return {"action": "proceed", "message": "Took over plan slot %d%s under %s from a lapsed claim." % (slot, of, root)}
        if flags.get("renewed") or mode == "renew" or claim.get("holderDigest") == me:
            return {"action": "proceed", "message": "Plan slot %d%s under %s renewed; carrying on." % (slot, of, root)}
        return {"action": "proceed", "message": "Took plan slot %d%s under %s." % (slot, of, root)}
    if kind in ("lost", "not_holder"):
        if not flags.get("final") and claim and (flags.get("expired") or SC.lapsed(claim, now)):
            return {"action": "takeover", "takeoverDigest": claim.get("holderDigest"),
                    "message": "Plan slot %d under %s lapsed (%s); taking it over." % (slot, root, who(claim, tz))}
        if mode == "renew":
            return {"action": "next", "nextSlot": 1,
                    "message": "This session's plan slot under %s is now %s; looking for another." % (
                        root, "held by " + who(claim, tz) if claim else "gone")}
        if slot < limit:
            return {"action": "next", "nextSlot": slot + 1, "message": ""}
        return {"action": "full", "message": "Every plan slot under %s is taken (%d of %d)." % (root, limit, limit)}
    return {"action": "degrade", "message": "The plan slot answer could not be read; building with no limit."}


def mine(request):
    root, rows, me = root_of(request), rows_of(request), a_digest(request.get("me"))
    own = sorted(slot_of(r.get("key"), root) for r in rows
                 if r.get("kind", KIND) == KIND and r.get("holderDigest") == me and not r.get("releasedAt")
                 and r.get("state") != "released" and slot_of(r.get("key"), root))
    return {"key": key_of(root, own[0]), "slot": own[0]} if own else {"key": None, "slot": None}


def free(request):
    candidates = request.get("candidates")
    if not isinstance(candidates, list) or not all(isinstance(c, str) for c in candidates):
        raise Refused("candidates must be a list of item numbers")
    rows, me, now, tz = rows_of(request), a_digest(request.get("me")), clock(request), request.get("tz")
    waiting = request.get("waiting") or []
    if not isinstance(waiting, list) or not all(isinstance(w, dict) for w in waiting):
        raise Refused("waiting must be a list of {item, on}")
    holders = {}
    for row in rows:
        if row.get("kind", "story") == "story" and live(row, now) and row.get("holderDigest") != me:
            holders.setdefault(row.get("key"), row)
    out = {"free": [c for c in candidates if c not in holders],
           "held": [{"item": c, "by": who(holders[c], tz)} for c in candidates if c in holders]}
    if out["free"]:
        out["message"] = ""
    else:
        held = "; ".join("%s (%s)" % (h["by"], h["item"]) for h in out["held"]) or "none"
        wait = "; ".join("%s (on %s)" % (w.get("item"), w.get("on")) for w in waiting) or "none"
        out["message"] = ("Nothing is free right now: %d held by other agents: %s. %d waiting on stories those "
                          "agents are building: %s." % (len(out["held"]), held, len(waiting), wait))
    return out


def full(request):
    root, rows, now, tz = root_of(request), rows_of(request), clock(request), request.get("tz")
    limit = request.get("limit")
    if not isinstance(limit, int) or isinstance(limit, bool) or not LIMITS[0] <= limit <= LIMITS[1]:
        raise Refused("limit must be a whole number from 1 to 20")
    building = sorted((r for r in rows if r.get("kind", KIND) == KIND and slot_of(r.get("key"), root) and live(r, now)),
                      key=lambda r: slot_of(r.get("key"), root))
    names = ", ".join(who(r, tz) for r in building) or "no live agent could be read"
    count = max(limit, len(building))  # a lowered limit can leave more building than it allows
    agents = "1 agent" if count == 1 else "%d agents" % count
    return {"message": (
        "This plan (%s) already has %s building, which is the most your organization allows. Nothing was "
        "started. Building now: %s. To allow more, raise Parallel building under Agents, Fleet in DevStride "
        "(it needs the permission to manage organization settings), or run this again when one of them "
        "finishes." % (root, agents, names))}


def room(request):
    root, rows, me, now = root_of(request), rows_of(request), a_digest(request.get("me")), clock(request)
    limit = request.get("limit")
    if not isinstance(limit, int) or isinstance(limit, bool) or not LIMITS[0] <= limit <= LIMITS[1]:
        raise Refused("limit must be a whole number from 1 to 20")
    others = {r.get("key") for r in rows if r.get("kind", KIND) == KIND and slot_of(r.get("key"), root)
              and live(r, now) and r.get("holderDigest") != me}
    if len(others) < limit:
        return {"verdict": "room", "message": ""}
    return {"verdict": "full", "message": full(request)["message"]}


def machine(request):
    root, rows, me, now, tz = root_of(request), rows_of(request), a_digest(request.get("me")), clock(request), request.get("tz")
    here, shared = request.get("machine"), request.get("shared")
    if not isinstance(here, str) or not here or not isinstance(shared, bool):
        raise Refused("machine must be this machine's name and shared true or false")
    mine_slot = request.get("slot")
    if mine_slot is not None and (not isinstance(mine_slot, int) or isinstance(mine_slot, bool) or mine_slot < 1):
        raise Refused("slot must be a whole number from 1, or absent")
    if not shared:
        return {"verdict": "ok", "message": ""}
    others = [r for r in rows if r.get("kind", KIND) == KIND and slot_of(r.get("key"), root) and live(r, now)
              and r.get("holderDigest") != me and r.get("machine") == here
              and (mine_slot is None or slot_of(r.get("key"), root) < mine_slot)]
    if not others:
        return {"verdict": "ok", "message": ""}
    return {"verdict": "busy", "message": (
        "Another agent is already building this plan (%s) on this machine: %s. This repository's checkouts "
        "share one local environment, test database included, so a second agent here would run its tests "
        "on the same one. Nothing was started. Run this on another machine, or again when that agent "
        "finishes." % (root, who(others[0], tz)))}


COMMANDS = {"decide": decide, "mine": mine, "free": free, "full": full, "room": room, "machine": machine}


def main(argv):
    if len(argv) != 2 or argv[1] not in COMMANDS:
        sys.stderr.write("usage: plan-slot.py decide|mine|free|full|room|machine   (input on stdin)\n")
        return 2
    try:
        request = json.loads(sys.stdin.read())
        if not isinstance(request, dict):
            raise ValueError("not an object")
    except ValueError as err:
        sys.stderr.write("plan-slot: stdin is not a JSON object: %s\n" % str(err).splitlines()[0])
        return 2
    try:
        print(json.dumps(COMMANDS[argv[1]](request)))
    except Refused as err:
        sys.stderr.write("plan-slot: %s\n" % err)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
