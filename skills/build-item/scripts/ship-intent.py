#!/usr/bin/env python3
"""What a session says it is about to ship — deterministic, standard library only, no network.

The rules are in `skills/build-item/references/ship-intent.md`; Claude follows that document and any
other agent or tool runs this file for the same answer. A declaration is information: it is never
permission and never a lock, so no answer here ever stops a build, a landing or a release.

  record   reads one JSON object on stdin, writes the claim to make on stdout:
             {"lane": "train"|"epic-release"|"develop-pr"|"hotfix",
              "unit": "I20130",          (the item, the release unit, or a hotfix's branch name)
              "branch": "<head branch>", "target": "<branch it will merge into>",
              "stage": "building"|"reviewing"|"verifying"|"landing",
              "class": "light"|"full"|"unknown",      (optional; unknown when absent)
              "now": "<ISO time>",                    (optional; the clock when absent)
              "expiryMinutes": 20}                    (optional; claims.expiryMinutes ship-intent)
           -> {"kind": "ship-intent", "key": "<unit>", "phase": "<stage>", "expiryMinutes": n,
               "payload": {"lane", "unit", "branch", "target", "class", "stage", "readyBy"}}
           A key it does not know, or a value outside the lists above, is refused (exit 2).
  decide   reads one JSON object on stdin, writes one JSON object on stdout:
             {"mode": "declare"|"update"|"release", "unit": "I20130", "response": <see story-claim.py>,
              "now": "<ISO time>", "tz": "<IANA zone>"}
           -> {"action": "proceed"|"takeover"|"declare"|"carry-on"|"degrade",
               "message": "<one plain-English line, empty when there is nothing to say>",
               "takeoverDigest"?: "<hex>"}
           proceed: done. takeover: declare again, ONCE, with `takeoverDigest` as the expected
           holder digest. declare: an update found no live declaration of this session's; declare
           again, ONCE. A second takeover or declare answer for the same step is a carry-on.
           carry-on: another session declared the unit; say the line, declare nothing.
           degrade: claims cannot be used; say the line ONCE per session, declare nothing more.
"""
import importlib.util
import json
import os
import sys
from datetime import datetime, timedelta, timezone

LANES = ("train", "epic-release", "develop-pr", "hotfix")
CLASSES = ("light", "full", "unknown")
# Minutes from a stage's record until the work is expected on its target. Estimates, shown as such;
# record once per stage, since each record restarts the estimate.
STAGE_MINUTES = {"building": 90, "reviewing": 40, "verifying": 15, "landing": 5}
RECORD_KEYS = ("lane", "unit", "branch", "target", "stage", "class", "now", "expiryMinutes")
DEFAULT_EXPIRY_MINUTES = 20
DEGRADE = {
    "ABSENT": "Claims are not available on this DevStride server yet; not saying what this session is about to ship.",
    "FORBIDDEN": "This DevStride key's user lacks the MANAGE_AGENT_CLAIMS permission; not saying what this session is about to ship.",
    "UNREACHABLE": "DevStride claims could not be reached; not saying what this session is about to ship.",
    "ERROR": "DevStride claims returned an error; not saying what this session is about to ship.",
}


def story_claim():
    """The one reader of a claim answer (story-claim.py beside this file)."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "story-claim.py")
    sys.dont_write_bytecode = True  # leave no compiled file in the plugin directory
    spec = importlib.util.spec_from_file_location("story_claim", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Refused(Exception):
    pass


def text(request, key):
    value = request.get(key)
    if not isinstance(value, str) or not value.strip() or len(value) > 300:
        raise Refused("%s must be a non-empty string of at most 300 characters" % key)
    return value.strip()


def record(request):
    unknown = sorted(k for k in request if k not in RECORD_KEYS)
    if unknown:
        raise Refused("unknown key %s (a declaration carries no other key)" % ", ".join(unknown))
    lane, stage = request.get("lane"), request.get("stage")
    if not isinstance(lane, str) or lane not in LANES:
        raise Refused("lane must be one of %s" % ", ".join(LANES))
    if not isinstance(stage, str) or stage not in STAGE_MINUTES:
        raise Refused("stage must be one of %s" % ", ".join(STAGE_MINUTES))
    klass = request.get("class", "unknown")
    if not isinstance(klass, str) or klass not in CLASSES:
        raise Refused("class must be one of %s" % ", ".join(CLASSES))
    expiry = request.get("expiryMinutes", DEFAULT_EXPIRY_MINUTES)
    if isinstance(expiry, bool) or not isinstance(expiry, int) or not 1 <= expiry <= 1440:
        raise Refused("expiryMinutes must be a whole number from 1 to 1440")
    now = datetime.now(timezone.utc)
    if "now" in request:
        now = story_claim().parse(request["now"])
        if now is None:
            raise Refused("now must be an ISO time")
    try:
        ready = (now + timedelta(minutes=STAGE_MINUTES[stage])).astimezone(timezone.utc)
    except (OverflowError, ValueError):
        raise Refused("now must be an ISO time")
    unit = text(request, "unit")
    return {
        "kind": "ship-intent",
        "key": unit,
        "phase": stage,
        "expiryMinutes": expiry,
        "payload": {
            "lane": lane,
            "unit": unit,
            "branch": text(request, "branch"),
            "target": text(request, "target"),
            "class": klass,
            "stage": stage,
            "readyBy": ready.strftime("%Y-%m-%dT%H:%M:%SZ"),
        },
    }


def decide(request):
    claims = story_claim()
    mode = request.get("mode")
    if mode not in ("declare", "update", "release"):
        raise Refused("mode must be declare, update or release")
    unit = request.get("unit") or "this work"
    now = claims.parse(request.get("now")) or datetime.now(timezone.utc)
    tz = request.get("tz")
    response = request.get("response")
    # The release verb's own answer ({"released": true|false, …}) is not a claim answer: either way
    # nothing of this session's is left listed.
    if mode == "release" and isinstance(response, dict) and "released" in response and not response.get("error"):
        return {"action": "proceed", "message": ""}
    kind, claim, flags = claims.normalise(response)
    claim = claim if isinstance(claim, dict) else {}
    if kind.startswith("error:"):
        return {"action": "degrade", "message": DEGRADE[kind.split(":", 1)[1]]}
    if kind in ("won", "ok"):
        return {"action": "proceed", "message": ""}
    if mode == "release":  # nothing of this session's to release: it lapsed, or was never declared
        return {"action": "proceed", "message": ""}
    gone = not claim or claim.get("releasedAt") is not None
    if gone:
        if mode == "update":
            return {"action": "declare", "message": ""}
        return {"action": "carry-on", "message": "%s could not be declared; carrying on without saying so." % unit}
    # The store's own word on expiry wins over this machine's clock, which may run ahead of it.
    told = isinstance(response, dict) and "expired" in response
    if flags.get("expired") if told else claims.lapsed(claim, now):
        return {"action": "takeover", "takeoverDigest": claim.get("holderDigest"), "message": ""}
    return {"action": "carry-on",
            "message": "%s is already declared as about to ship by %s; carrying on without declaring it." % (unit, claims.who(claim, tz))}


def main(argv):
    if len(argv) != 2 or argv[1] not in ("record", "decide"):
        sys.stderr.write("usage: ship-intent.py record|decide   (input on stdin)\n")
        return 2
    try:
        try:
            request = json.loads(sys.stdin.read())
        except ValueError as err:
            raise Refused("stdin is not a JSON object: %s" % err)
        if not isinstance(request, dict):
            raise Refused("stdin is not a JSON object")
        print(json.dumps(record(request) if argv[1] == "record" else decide(request)))
    except Refused as err:
        sys.stderr.write("ship-intent: %s\n" % err)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
