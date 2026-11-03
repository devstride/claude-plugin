#!/usr/bin/env python3
"""What a story-claim answer means for build-item — deterministic, standard library only, no network.

The rules are in `skills/build-item/references/story-claims.md`; Claude follows that document and any
other agent runs this file for the same answer.

  decide   reads one JSON object on stdin, writes one JSON object on stdout:
             {"mode": "select"|"named"|"resume"|"heartbeat",
              "item": "I20100",                       (optional, named in the message)
              "response": <see below>,
              "me": "<hex digest of my holder>",
              "now": "<ISO time>",
              "tz": "<IANA zone>"}                    (optional; the machine's local zone when absent)
           -> {"action": "proceed"|"skip"|"stop"|"takeover"|"reclaim"|"degrade",
               "message": "<one plain-English line>", "takeoverDigest"?: "<hex>"}
  digest   reads stdin, prints its sha256 in hex (the `me` value for a holder string).

`response` is one of: the claim_work / heartbeat_claim result as the server returned it; a commands
provider's answer `{"verdict": "WON"|"LOST"|"OK"|"NOT HOLDER"|…, "exitCode": n, "claim"?: {…}}`; or a
failure `{"error": "ABSENT"|"UNREACHABLE"|"FORBIDDEN"|"ERROR"}`. A claim row carries `holderDigest`,
`machine`, `sessionName`, `claimedAt`, `expiresAt` and `releasedAt`; the holder itself never appears.
"""
import hashlib
import json
import sys
from datetime import datetime, timezone

DEGRADE = {
    "ABSENT": "Claims are not available on this DevStride server yet; continuing without them.",
    "FORBIDDEN": "This DevStride key's user lacks the MANAGE_AGENT_CLAIMS permission; continuing without claims.",
    "UNREACHABLE": "DevStride claims could not be reached; continuing without them.",
    "ERROR": "DevStride claims returned an error; continuing without them.",
}
VERDICT_ERRORS = ("ABSENT", "FORBIDDEN", "UNREACHABLE", "ERROR")
VERDICTS = {"WON": "won", "LOST": "lost", "OK": "ok", "NOT HOLDER": "not_holder"}


def parse(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def local(moment, tz):
    """A time a person reads: local zone, with its abbreviation."""
    if tz:
        try:
            from zoneinfo import ZoneInfo
            moment = moment.astimezone(ZoneInfo(tz))
        except Exception:  # unknown zone name or no zone database: the machine's local zone
            moment = moment.astimezone()
    else:
        moment = moment.astimezone()
    return moment.strftime("%-I:%M %p %Z on %b %-d")


def who(claim, tz):
    claim = claim if isinstance(claim, dict) else {}
    session = claim.get("sessionName")
    machine = claim.get("machine")
    since = parse(claim.get("claimedAt"))
    parts = ["session %s" % session if session else "an unnamed session"]
    if machine:
        parts.append("on machine %s" % machine)
    if since:
        parts.append("since %s" % local(since, tz))
    return " ".join(parts)


def lapsed(claim, now):
    expires = parse(claim.get("expiresAt")) if isinstance(claim, dict) else None
    return bool(expires and now and expires <= now)


def normalise(response):
    """-> (kind, claim, flags) with kind in won, lost, ok, not_holder, error:<NAME>."""
    if not isinstance(response, dict):
        return "error:ERROR", None, {}
    if response.get("error"):
        name = str(response["error"]).upper()
        return "error:" + (name if name in VERDICT_ERRORS else "ERROR"), None, {}
    if "verdict" in response:
        # Only a verdict the commands contract names counts; an exit code alone never decides.
        verdict = str(response["verdict"]).upper()
        claim = response.get("claim")
        if verdict in VERDICT_ERRORS:
            return "error:" + verdict, None, {}
        kind = VERDICTS.get(verdict)
        if kind is None:
            return "error:ERROR", None, {}
        return kind, (response.get("current") or claim) if kind == "not_holder" else claim, {}
    if str(response.get("outcome", "")).upper() == "NOT_HOLDER":
        return "not_holder", response.get("current"), {}
    if "won" in response:
        flags = {k: bool(response.get(k)) for k in ("expired", "final", "takenOver", "renewed")}
        return ("won" if response["won"] else "lost"), response.get("claim"), flags
    if "holderDigest" in response:  # a bare claim row: a heartbeat that landed
        return "ok", response, {}
    return "error:ERROR", None, {}


def decide(request):
    mode = request.get("mode")
    item = request.get("item") or "this story"
    me = request.get("me")
    now = parse(request.get("now")) or datetime.now(timezone.utc)
    tz = request.get("tz")
    kind, claim, flags = normalise(request.get("response"))
    claim = claim if isinstance(claim, dict) else {}
    if kind.startswith("error:"):
        return {"action": "degrade", "message": DEGRADE[kind.split(":", 1)[1]]}

    if mode == "heartbeat":
        if kind in ("ok", "won"):
            return {"action": "proceed", "message": ""}
        if kind == "not_holder" or kind == "lost":
            gone = not claim or claim.get("releasedAt") is not None
            if gone:
                return {"action": "reclaim", "message": "The claim on %s lapsed and is free; claiming it again." % item}
            if lapsed(claim, now):
                return {"action": "takeover", "takeoverDigest": claim.get("holderDigest"),
                        "message": "The claim on %s lapsed and was left by %s; claiming it again." % (item, who(claim, tz))}
            return {"action": "stop", "message": "Stopping: %s is now held by %s." % (item, who(claim, tz))}

    elif mode in ("select", "named", "resume"):
        if kind in ("won", "ok"):
            if flags.get("takenOver"):
                return {"action": "proceed", "message": "Took over %s from a lapsed claim." % item}
            if flags.get("renewed") or (me and claim.get("holderDigest") == me and mode == "resume"):
                return {"action": "proceed", "message": "Claim on %s renewed; carrying on." % item}
            return {"action": "proceed", "message": "Claimed %s." % item}
        if kind == "lost":
            if flags.get("final") or (claim.get("releasedAt") and claim.get("outcome") == "done"):
                text = "%s was already finished by %s." % (item, who(claim, tz))
                return {"action": "skip" if mode == "select" else "stop", "message": text}
            if flags.get("expired") or lapsed(claim, now):
                return {"action": "takeover", "takeoverDigest": claim.get("holderDigest"),
                        "message": "The claim on %s lapsed (%s); taking it over." % (item, who(claim, tz))}
            held = "%s is held by %s" % (item, who(claim, tz))
            if mode == "select":
                return {"action": "skip", "message": held + "; skipping to the next candidate."}
            return {"action": "stop", "message": "Stopping: %s." % held}

    return {"action": "stop", "message": "Stopping: the claim answer for %s could not be read (mode %s)." % (item, mode)}


def main(argv):
    if len(argv) != 2 or argv[1] not in ("decide", "digest"):
        sys.stderr.write("usage: story-claim.py decide|digest   (input on stdin)\n")
        return 2
    raw = sys.stdin.read()
    if argv[1] == "digest":
        print(hashlib.sha256(raw.rstrip("\n").encode("utf-8")).hexdigest())
        return 0
    try:
        request = json.loads(raw)
        if not isinstance(request, dict):
            raise ValueError("not an object")
    except ValueError as err:
        sys.stderr.write("story-claim: stdin is not a JSON object: %s\n" % err)
        return 2
    print(json.dumps(decide(request)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
