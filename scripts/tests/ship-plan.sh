#!/bin/bash
# Tests for skills/release/scripts/ship-plan.py through its own command line. No network, no git.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/skills/release/scripts/ship-plan.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
# The runner prints to a file: bash 3.2 cannot parse a here-document holding apostrophes inside $( ).
python3 - "$HELPER" > "$WORK/out" <<'PY'
import json, subprocess, sys
helper = sys.argv[1]
NOW = "2026-03-14T15:00:00Z"
TRAIN = "train/release"

def run(verb, data, raw=False):
    p = subprocess.run([sys.executable, helper, verb], input=data if raw else json.dumps(data), capture_output=True, text=True)
    try:
        return p.returncode, json.loads(p.stdout), p
    except ValueError:
        return p.returncode, p.stdout.strip(), p

def say(good, label, extra=""):
    print(("ok   " if good else "FAIL ") + label + ("" if good else " -> " + str(extra)))

def at(minutes):
    return "2026-03-14T%02d:%02d:00Z" % (15 + (minutes // 60), minutes % 60) if minutes >= 0 else "2026-03-14T14:%02d:00Z" % (60 + minutes)

def row(unit, ready=10, stage="reviewing", route="train", target=TRAIN, digest="peer", session="other", **extra):
    base = {"kind": "ship-intent", "key": unit, "id": "d-" + unit, "state": "live", "holderDigest": digest, "machine": "studio", "sessionName": "build-two",
            "expiresAt": at(20), "releasedAt": None, "session": {"sessionId": {"value": session}},
            "payload": {"route": route, "unit": unit, "branch": "b", "target": target, "class": "light", "stage": stage, "readyBy": at(ready)}}
    base.update(extra)
    return base

def ask(claims, **extra):
    request = {"now": NOW, "peerWaitMinutes": 15, "train": TRAIN, "tz": "UTC", "me": {"holderDigests": ["me"], "sessionIds": ["mine"]}, "claims": claims}
    request.update(extra)
    return run("decide", request)

def units(out):
    return [m["unit"] for m in (out.get("plan") or {}).get("members", [])]

rc, out, p = ask([])
say(rc == 0 and out == {"action": "go", "plan": None, "reason": "nobody is nearly ready", "message": ""}, "no declarations: go, no plan", p.stdout + p.stderr)
rc, out, p = ask([row("I20130", ready=8)])
say(out.get("action") == "wait" and out["waitUntil"] == at(8) and units(out) == ["I20130"] and out["plan"]["startedAt"] == NOW
    and out["plan"]["members"][0] == {"unit": "I20130", "declaration": "d-I20130", "session": "build-two", "machine": "studio", "stage": "reviewing", "readyBy": at(8)}
    and out["plan"]["windowMinutes"] == 15
    and "until 3:08 PM UTC" in out["message"], "one member ready inside the window: wait until its estimate", p.stdout)
rc, out, p = ask([row("I20130", ready=40)])
say(out.get("action") == "go" and out["plan"] is None, "a peer beyond the window: go, not a member", p.stdout)
rc, out, p = ask([row("I20130", ready=4), row("I20131", ready=12), row("I20110", ready=9)])
say(out.get("action") == "wait" and out["waitUntil"] == at(12) and units(out) == ["I20110", "I20130", "I20131"], "several members: wait until the latest", p.stdout)
rc, out, p = ask([row("I20130", ready=4), row("I20131", ready=40, stage="landing")])
say(out.get("action") == "wait" and out["waitUntil"] == at(15) and units(out) == ["I20130", "I20131"], "a peer already landing whose estimate is beyond the window: a member, capped at the window", p.stdout)
rc, out, p = ask([row("I20130", ready=-5, stage="verifying")])
say(out.get("action") == "wait" and out["waitUntil"] == at(15), "an estimate that has already passed gets the whole window, never an instant go", p.stdout)
rc, out, p = ask([row("I20130", ready=5)], peerWaitMinutes=0)
say(out.get("action") == "go" and out["plan"] is None and "never waits" in out["reason"], "peerWaitMinutes 0: go", p.stdout)
rc, out, p = ask([row("I20130", ready=5)], enabled=False)
say(out.get("action") == "go" and out["plan"] is None, "coordination disabled: go", p.stdout)
rc, out, p = ask([row("I20130", ready=5)], goNow=True)
say(out.get("action") == "go" and out["plan"] is None, "told to go now: go", p.stdout)
rc, out, p = ask({"error": "UNREACHABLE"})
say(out.get("action") == "go" and out["plan"] is None and out["message"].startswith("What other sessions are about to ship could not be read"), "unreadable declarations: go, said", p.stdout)
for label, claim in (("the driver's own declaration, by holder", row("I20130", ready=5, digest="me")),
                     ("the driver's own declaration, by session", row("I20130", ready=5, session="mine")),
                     ("a hotfix", row("I20130", ready=5, route="hotfix", target="main")),
                     ("a pull request into the base branch", row("I20130", ready=5, route="develop-pr", target="develop")),
                     ("an epic-branch story that is not heading for the train", row("I20130", ready=5, route="epic-release", target="jane/26-03-14/epic-x")),
                     ("a declaration that lapsed", row("I20130", ready=5, expiresAt=at(-1))),
                     ("a declaration marked expired", row("I20130", ready=5, state="expired")),
                     ("one already released", row("I20130", ready=5, releasedAt=at(-2), outcome="landed")),
                     ("a row of another kind", row("I20130", ready=5, kind="story")),
                     ("a unit that is not a usable name", row("bad unit!", ready=5))):
    rc, out, p = ask([claim])
    say(out.get("action") == "go" and out.get("plan") is None, "never a member: " + label, p.stdout + p.stderr)
rc, out, p = ask([row("I20130", ready=5), row("I20131", ready=6)], held=["I20130"])
say(units(out) == ["I20131"], "a held unit is never a member", p.stdout)
rc, out, p = ask([row("I20104", ready=5, route="epic-release")])
say(units(out) == ["I20104"], "an epic release heading for the train is a member", p.stdout)

# an existing plan is worked through, never widened
PLAN = {"startedAt": NOW, "waitUntil": at(10), "windowMinutes": 15,
        "members": [{"unit": "I20130", "declaration": "d-I20130", "session": "build-two", "machine": "studio", "stage": "reviewing", "readyBy": at(8)},
                    {"unit": "I20131", "declaration": "d-I20131", "session": "s", "machine": "m", "stage": "landing", "readyBy": at(10)}]}
later = dict(now=at(4), plan=PLAN)
rc, out, p = ask([row("I20130"), row("I20131"), row("I20110", ready=1, stage="landing")], **later)
say(out.get("action") == "wait" and out["waitUntil"] == at(10) and units(out) == ["I20130", "I20131"] and out["plan"] == PLAN, "an existing plan plus a new nearly-ready peer: not added, waitUntil unchanged", p.stdout)
rc, out, p = ask([row("I20130", ready=60), row("I20131", ready=60)], **later)
say(out.get("action") == "wait" and out["waitUntil"] == at(10), "a member moving its estimate later never moves the wait", p.stdout)
landed = lambda unit: row(unit, releasedAt=at(3), outcome="landed", state="released")
rc, out, p = ask([landed("I20130"), landed("I20131")], **later)
say(out.get("action") == "go" and [m["result"] for m in out["plan"]["members"]] == ["carried", "carried"] and out["plan"]["minutesWaited"] == 4
    and out["message"] == "Waited 4 min for peers: carried I20130, I20131; missed none.", "every member landed early: go early, each carried", p.stdout)
rc, out, p = ask([landed("I20130"), row("I20131")], **later)
say(out.get("action") == "wait" and "I20131" in out["reason"] and "I20130" not in out["reason"], "one landed, one still coming: wait for the one", p.stdout)
rc, out, p = ask([landed("I20130"), row("I20131")], now=at(10), plan=PLAN)
say(out.get("action") == "go" and [m["result"] for m in out["plan"]["members"]] == ["carried", "missed"] and out["plan"]["minutesWaited"] == 10, "waitUntil reached with one member missing: go, that member missed", p.stdout)
rc, out, p = ask([landed("I20130"), row("I20131", expiresAt=at(3))], **later)
say(out.get("action") == "go" and [m["result"] for m in out["plan"]["members"]] == ["carried", "missed"], "a member whose declaration lapsed is dropped: go", p.stdout)
rc, out, p = ask([row("I20130", releasedAt=at(3), outcome="stopped", state="released"), landed("I20131")], **later)
say(out.get("action") == "go" and out["plan"]["members"][0]["result"] == "missed", "a member released without landing is missed, never carried", p.stdout)
rc, out, p = ask([row("I20130"), row("I20131")], held=["I20130", "I20131"], **later)
say(out.get("action") == "go", "members that became held are no longer waited for", p.stdout)
for label, extra in (("told to go now", {"goNow": True}), ("switched off", {"enabled": False}), ("the window set to 0", {"peerWaitMinutes": 0})):
    rc, out, p = ask([row("I20130"), row("I20131")], **dict(later, **extra))
    say(out.get("action") == "go" and out["plan"]["minutesWaited"] == 4 and [m["result"] for m in out["plan"]["members"]] == ["missed", "missed"], "mid-wait, %s: go with the record kept" % label, p.stdout)
rc, out, p = ask({"error": "UNREACHABLE"}, **later)
say(out.get("action") == "go" and out["plan"]["minutesWaited"] == 4, "mid-wait, declarations unreadable: go, never a longer wait", p.stdout)
rc, out, p = ask([landed("I20130"), row("I20130", ready=2, stage="landing", id="d-again"), landed("I20131")], **later)
say(out.get("action") == "go" and [m["result"] for m in out["plan"]["members"]] == ["carried", "carried"], "a new declaration for a unit that already landed is not the one waited for: go, carried", p.stdout)
rc, out, p = ask([row("I20130", id="d-older", releasedAt=at(-30), outcome="landed", state="released"), row("I20130", releasedAt=at(3), outcome="stopped", state="released"), landed("I20131")], **later)
say(out["plan"]["members"][0]["result"] == "missed", "an older landed declaration of the same unit never makes this one carried", p.stdout)
rc, out, p = ask({"data": [row("I20130", ready=8)], "meta": {"cursor": None}})
say(out.get("action") == "wait" and units(out) == ["I20130"], "the store's wrapped list answer is read", p.stdout)
rc, out, p = ask([row("I20130", ready=-120, stage="building")])
say(out.get("action") == "go" and out["plan"] is None, "a build long past its estimate is not nearly ready", p.stdout)
rc, out, p = ask([row("I20130", ready=5, id="")])
say(out.get("action") == "go", "a declaration that cannot be told from a later one is not waited for", p.stdout)

# a plan read back from the claim is validated, bounded and rebuilt
far = dict(PLAN, waitUntil="2030-01-01T00:00:00Z")
rc, out, p = ask([row("I20130"), row("I20131")], now=at(4), plan=far)
say(out.get("action") == "wait" and out["waitUntil"] == at(15), "an end far beyond the window is cut to the start plus the window", p.stdout)
rc, out, p = ask([row("I20130"), row("I20131")], now=at(16), plan=far)
say(out.get("action") == "go" and out["plan"]["minutesWaited"] == 15, "and past that the release goes, having waited the window at most", p.stdout)
rc, out, p = ask([row("I20130"), row("I20131")], now=at(4), plan=dict(PLAN, waitUntil=at(14)), peerWaitMinutes=5)
say(out.get("action") == "wait" and out["waitUntil"] == at(5), "a window lowered since the plan was made shortens the wait", p.stdout)
say(out["plan"]["waitUntil"] == at(5) and out["plan"]["windowMinutes"] == 5, "and the shorter end is kept in the plan, so raising the window again cannot bring the old one back", p.stdout)
rc, again, p = ask([row("I20130"), row("I20131")], now=at(4), plan=out["plan"], peerWaitMinutes=15)
say(again["waitUntil"] == at(5), "the plan as stored stays at the shorter end", p.stdout)
for label, bad in (("a read that failed", {"error": "UNREACHABLE"}), ("something half-finished", {"minutesWaited": None, "members": 7}), ("a result that is not one", dict(PLAN, members=[dict(PLAN["members"][0], result="maybe")]))):
    rc, out2, p = ask([row("I20130", stage="verifying"), row("I20110", stage="verifying")], now=at(4), plan=bad)
    say(out2.get("action") == "go" and out2.get("plan") is None and "could not be read" in out2.get("reason", ""), "a plan read back as %s: go, never a fresh wait" % label, p.stdout + p.stderr)
rc, out, p = ask([row("I20130"), row("I20131")], now=at(4), plan=PLAN, peerWaitMinutes=60)
say(out["waitUntil"] == at(10), "a window raised since never lengthens it", p.stdout)
for label, bad in (("no start", {k: v for k, v in PLAN.items() if k != "startedAt"}), ("no window", {k: v for k, v in PLAN.items() if k != "windowMinutes"}),
                   ("members that are not a list", dict(PLAN, members=None)), ("a member that is not an object", dict(PLAN, members=[None])),
                   ("a member with no declaration", dict(PLAN, members=[{"unit": "I20130"}])), ("a unit that is a list", dict(PLAN, members=[{"unit": [], "declaration": "x"}])),
                   ("no members", dict(PLAN, members=[])), ("a plan that is a string", "soon")):
    rc, out, p = ask([row("I20130", stage="verifying"), row("I20110", stage="verifying")], now=at(4), plan=bad)
    say(rc == 0 and out.get("action") == "go" and out.get("plan") is None and "could not be read" in out.get("reason", ""), "a plan read back with %s: go, never a fresh wait" % label, p.stdout + p.stderr)
rc, out, p = ask([row("I20130", stage="verifying", expiresAt=at(320))], now=at(300), plan=dict(PLAN, minutesWaited=7, members=[dict(m, result="carried") for m in PLAN["members"]]))
say(out.get("action") == "wait" and out["plan"]["startedAt"] == at(300), "a finished plan left on the claim by an earlier release is no plan: this release decides afresh", p.stdout)
rc, out, p = ask([row("I20130"), row("I20131")], now=at(-30), plan=PLAN)
say(out.get("action") == "go" and out["plan"]["minutesWaited"] == 0, "a clock behind the plan's start ends the wait", p.stdout)
rc, out, p = ask([row("I20130"), row("I20131")], now=at(4), plan=dict(PLAN, holder="stray-holder", holderDigest="abc", members=[dict(m, holderDigest="abc") for m in PLAN["members"]]))
say("stray-holder" not in p.stdout and "holderDigest" not in p.stdout and out.get("action") == "wait", "keys a plan does not carry are never passed on", p.stdout)
rc, out, p = ask([row("I20130", ready=5)], me={"holderDigests": "peer-and-more", "sessionIds": "other-x"})
say(units(out) == ["I20130"], "a driver identity that is not a list excludes nothing by accident", p.stdout)

# the peer's side
claim = {"kind": "release-train", "key": "acme/widgets", "machine": "studio", "phase": "gathering", "expiresAt": at(30), "releasedAt": None, "payload": {"plan": PLAN}}
for label, request in (("a failed read that still carries a row", {"unit": "I20130", "response": {"error": "UNREACHABLE", "claim": claim}}),
                       ("a claim of another kind", {"unit": "I20130", "response": dict(claim, kind="story")}),
                       ("no unit asked about", {"response": claim}), ("another declaration of the same unit", {"unit": "I20130", "declaration": "d-again", "response": claim}),
                       ("a plan that cannot be validated", {"unit": "I20130", "response": dict(claim, payload={"plan": dict(PLAN, members=[{"unit": "I20130"}])})})):
    rc, out, p = run("peer", dict(request, now=at(4), tz="UTC"))
    say(rc == 0 and out == {"member": False, "message": ""}, "the peer is told nothing: " + label, p.stdout + p.stderr)
rc, out, p = run("peer", {"unit": "I20130", "declaration": "d-I20130", "response": claim, "now": at(4), "tz": "UTC"})
say(out.get("member") is True, "the declaration the plan names is a member", p.stdout)
rc, out, p = run("peer", {"unit": "I20130", "response": claim, "now": at(4), "tz": "UTC"})
say(out == {"member": True, "message": "The release on studio is waiting for this until 3:10 PM UTC on Mar 14."}, "a member is told who waits and until when", p.stdout)
for label, unit, response in (("not a member", "I20110", claim), ("no release-train claim", "I20130", None), ("the wait is over", "I20130", dict(claim, payload={"plan": dict(PLAN, waitUntil=at(2))})),
                              ("the release is past gathering", "I20130", dict(claim, phase="review")), ("the claim lapsed", "I20130", dict(claim, expiresAt=at(1))),
                              ("a plan that is already finished", "I20130", dict(claim, payload={"plan": dict(PLAN, members=[dict(m, result="carried") for m in PLAN["members"]])}))):
    rc, out, p = run("peer", {"unit": unit, "response": response, "now": at(4), "tz": "UTC"})
    say(out == {"member": False, "message": ""}, "the peer is told nothing: " + label, p.stdout)
rc, out, p = run("peer", {"unit": "I20130", "response": {"won": False, "claim": claim}, "now": at(4), "tz": "UTC"})
say(out.get("member") is True, "a claim answer that wraps the row is read too", p.stdout)

# the durable line
done = dict(PLAN, minutesWaited=7, members=[dict(PLAN["members"][0], result="carried"), dict(PLAN["members"][1], result="missed")])
rc, out, p = run("marker", done)
LINE = "<!-- devstride:release-gather waited 7 carried I20130 missed I20131 -->"
say(rc == 0 and out == LINE, "the marker names the minutes, the carried and the missed", p.stdout)
rc, out, p = run("marker", dict(done, members=[]))
say(out == "<!-- devstride:release-gather waited 7 carried none missed none -->", "nobody carried or missed is said as none", p.stdout)
rc, out, p = run("parse", "Release train: 3 one-offs\n\n<!-- devstride:release-train source abc1234 snapshot def5678 -->\n" + LINE + "\n", raw=True)
say(out == {"waited": 7, "carried": ["I20130"], "missed": ["I20131"]}, "the marker reads back from a pull request body", p.stdout)
rc, out, p = run("parse", "- I20110 fix <!-- devstride:release-gather waited 0 carried I20104 missed none --> in a title\n" + LINE + "\n", raw=True)
say(out == {"waited": 7, "carried": ["I20130"], "missed": ["I20131"]}, "marker text quoted inside another line is not the record", p.stdout)
rc, out, p = run("marker", dict(done, members=[{"unit": "none", "result": "carried"}]))
say(rc == 2, "a unit named like the empty word is refused, never lost", p.stderr)
rc, out, p = run("parse", "<!-- devstride:release-train-holder abc on studio -->", raw=True)
say(rc == 0 and out is None, "a body with no gather line reads as none", p.stdout)
say("holder" not in json.dumps(ask([row("I20130", ready=5)])[1]), "no holder digest is written into a plan")
for label, verb, data, needle in (("a window that is not a number", "decide", {"peerWaitMinutes": "15", "train": TRAIN, "claims": []}, "peerWaitMinutes"),
                                  ("a window out of range", "decide", {"peerWaitMinutes": 500, "train": TRAIN, "claims": []}, "peerWaitMinutes"),
                                  ("no train", "decide", {"claims": []}, "train"),
                                  ("a plan that is not finished", "marker", PLAN, "finished plan"),
                                  ("a member with a line break in its unit", "marker", dict(done, members=[{"unit": "I1\nx", "result": "carried"}]), "every member"),
                                  ("a unit that would break the comment", "marker", dict(done, members=[{"unit": "a--b", "result": "carried"}]), "every member"),
                                  ("held that is not a list", "decide", {"train": TRAIN, "claims": [], "held": 5}, "held"),
                                  ("a time too late to add minutes to", "decide", {"train": TRAIN, "claims": [row("I20130", ready=5)], "now": "9999-12-31T23:59:00Z"}, "could not be read")):
    rc, out, p = run(verb, data)
    say(rc == 2 and p.stdout == "" and p.stderr.startswith("ship-plan: ") and needle in p.stderr, "refuses: " + label, p.stderr)
rc, out, p = run("decide", "[", raw=True)
say(rc == 2 and p.stderr.startswith("ship-plan: "), "refuses: not JSON", p.stderr)
p = subprocess.run([sys.executable, helper, "go"], input="{}", capture_output=True, text=True)
say(p.returncode == 2 and p.stderr.startswith("usage: "), "refuses: an unknown subcommand", p.stderr)
print("ran to the end")
PY
RC=$?
OUT="$(cat "$WORK/out")"
echo "$OUT"
[ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q '^ran to the end$' || { echo "ship-plan: the runner itself failed (exit $RC)"; exit 1; }
FAILS=$(printf '%s\n' "$OUT" | grep -c '^FAIL')
[ "$FAILS" -eq 0 ] || { echo "ship-plan: $FAILS failed"; exit 1; }
