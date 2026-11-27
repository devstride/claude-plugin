#!/bin/bash
# Tests for skills/build-item/scripts/plan-slot.py — eight agent sessions race for the slots of one
# plan against an in-memory stand-in for claim_work, every answer going through `decide`: exactly
# as many win as the limit allows and the rest are told the plan is full, naming the agents
# building and a local time with its zone; an expired slot is taken over with its holder's digest;
# a session keeps its own slot through `mine` after the limit is lowered, and `room` holds back a
# new session while one above the lowered limit still builds, even with a low slot free; `free` drops stories
# other live agents hold and keeps this session's own; an older server without the limit degrades;
# where checkouts share one local environment, a second agent on the same machine is told the
# machine is busy, and two that both looked before claiming settle on the lower slot; two sessions racing for one epic release leave one winner (story-claim.py, the shared reader);
# the holder string never appears; bad input exits 2 with one line and no traceback. No network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/skills/build-item/scripts/plan-slot.py"
CLAIM="$ROOT/skills/build-item/scripts/story-claim.py"
FAIL=0; bad() { echo "  FAIL $1"; FAIL=1; }
export PYTHONDONTWRITEBYTECODE=1

OUT="$(python3 - "$HELPER" "$CLAIM" <<'PY'
import hashlib, json, subprocess, sys
from datetime import datetime, timedelta, timezone
helper, claim_helper = sys.argv[1], sys.argv[2]
T0 = datetime(2026, 1, 15, 15, 14, tzinfo=timezone.utc)   # 9:14 AM CST
iso = lambda d: d.strftime("%Y-%m-%dT%H:%M:%SZ")
digest = lambda s: hashlib.sha256(s.encode()).hexdigest()

class Store:
    """The claim_work rules, in memory: one row per (kind, key), one winner per key."""
    def __init__(self): self.rows = {}
    def claim(self, kind, key, holder, machine, session, now, minutes=240, takeover=None):
        row, me = self.rows.get((kind, key)), digest(holder)
        new = {"kind": kind, "key": key, "holderDigest": me, "machine": machine, "sessionName": session,
               "takenAt": iso(now), "expiresAt": iso(now + timedelta(minutes=minutes)), "releasedAt": None,
               "outcome": None, "state": "live"}
        if row is None or (row["releasedAt"] and row["outcome"] != "done"):
            self.rows[(kind, key)] = new; return {"won": True, "claim": new}
        if row["holderDigest"] == me:
            row.update(expiresAt=iso(now + timedelta(minutes=minutes))); return {"won": True, "renewed": True, "claim": row}
        if datetime.fromisoformat(row["expiresAt"].replace("Z", "+00:00")) <= now:
            if takeover == row["holderDigest"]:
                self.rows[(kind, key)] = new; return {"won": True, "takenOver": True, "claim": new}
            return {"won": False, "expired": True, "claim": row}
        return {"won": False, "claim": row}
    def release(self, kind, key):
        self.rows[(kind, key)].update(releasedAt=iso(T0), outcome="released", state="released")
    def listing(self, kind, prefix=""):
        return [dict(r) for (k, key), r in self.rows.items() if k == kind and key.startswith(prefix)]

SEEN = []
def run(command, request, script=None):
    p = subprocess.run([sys.executable, script or helper, command], input=json.dumps(request), capture_output=True, text=True)
    SEEN.append(p.stdout + p.stderr)
    return p.returncode, (json.loads(p.stdout) if p.returncode == 0 else {"stderr": p.stderr})

def take(store, root, limit, holder, machine, session, now):
    """Step 0 as the skill runs it: renew our own slot, else try 1..limit."""
    me = digest(holder)
    _, mine = run("mine", {"root": root, "rows": store.listing("plan-slot", root + "#"), "me": me})
    if mine["key"]:
        res = store.claim("plan-slot", mine["key"], holder, machine, session, now)
        _, d = run("decide", {"mode": "renew", "root": root, "slot": mine["slot"], "limit": limit, "response": res, "me": me, "now": iso(now), "tz": "America/Chicago"})
        if d["action"] == "proceed":
            return mine["slot"], d
    _, r = run("room", {"root": root, "limit": limit, "rows": [x for x in store.listing("plan-slot", root + "#") if not x["releasedAt"]], "me": me, "now": iso(now), "tz": "America/Chicago"})
    if r["verdict"] == "full":
        return None, {"action": "full", "message": r["message"]}
    n = 1
    while True:
        res = store.claim("plan-slot", "%s#%d" % (root, n), holder, machine, session, now)
        _, d = run("decide", {"mode": "take", "root": root, "slot": n, "limit": limit, "response": res, "me": me, "now": iso(now), "tz": "America/Chicago"})
        if d["action"] == "takeover":
            res = store.claim("plan-slot", "%s#%d" % (root, n), holder, machine, session, now, takeover=d["takeoverDigest"])
            _, d = run("decide", {"mode": "take", "root": root, "slot": n, "limit": limit, "response": res, "me": me, "now": iso(now), "tz": "America/Chicago"})
        if d["action"] == "next":
            n = d["nextSlot"]; continue
        return (n if d["action"] == "proceed" else None), d

def check(label, good, detail=""):
    print(("  ok   " if good else "  FAIL ") + label + ("" if good else "  " + str(detail)))

store, root = Store(), "I20100"
names = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"]
holders = {n: "claude:%s-secret" % n for n in names}
results = {n: take(store, root, 3, holders[n], "mac-one" if i % 2 == 0 else "mac-two", n, T0) for i, n in enumerate(names)}
won = [n for n in names if results[n][0]]
check("(1) eight sessions, limit 3: exactly three proceed, on three different slots",
      len(won) == 3 and sorted(results[n][0] for n in won) == [1, 2, 3], results)
check("(2) the other five are told the plan is full", all(results[n][1]["action"] == "full" for n in names if n not in won), results)
_, f = run("full", {"root": root, "limit": 3, "rows": store.listing("plan-slot", root + "#"), "now": iso(T0), "tz": "America/Chicago"})
m = f["message"]
check("(3) the full message names the plan, the limit, each agent and machine, a local time with its zone, and the setting",
      "This plan (I20100) already has 3 agents building" in m and "alpha on mac-one since 9:14 AM CST" in m and "beta on mac-two" in m
      and "gamma on mac-one" in m and "Nothing was started" in m and "Parallel building under Agents, Fleet" in m, m)

store.release("plan-slot", root + "#2")
got, d = take(store, root, 3, holders["delta"], "mac-two", "delta", T0 + timedelta(minutes=1))
check("(4) a released slot is won by the next caller", got == 2 and d["action"] == "proceed", (got, d))

late = T0 + timedelta(minutes=241)
store.rows[("plan-slot", root + "#1")]["expiresAt"] = iso(T0 + timedelta(minutes=240))
store.rows[("plan-slot", root + "#2")]["expiresAt"] = iso(late + timedelta(minutes=240))
store.rows[("plan-slot", root + "#3")]["expiresAt"] = iso(late + timedelta(minutes=240))
res = store.claim("plan-slot", root + "#1", holders["eta"], "mac-one", "eta", late)
_, d = run("decide", {"mode": "take", "root": root, "slot": 1, "limit": 3, "response": res, "me": digest(holders["eta"]), "now": iso(late), "tz": "America/Chicago"})
check("(5) an expired slot is a takeover carrying its holder's digest", d["action"] == "takeover" and d["takeoverDigest"] == digest(holders["alpha"]), d)
got, d = take(store, root, 3, holders["eta"], "mac-one", "eta", late)
check("(6) the takeover then wins that slot", got == 1 and "Took over" in d["message"], (got, d))

got, d = take(store, root, 2, holders["gamma"], "mac-one", "gamma", late)
check("(7) a limit lowered to 2 under slot 3: its holder renews it through mine", got == 3 and "renewed" in d["message"], (got, d))
got, d = take(store, root, 2, holders["zeta"], "mac-two", "zeta", late)
check("(8) while a new session is told full", got is None and d["action"] == "full", (got, d))
lowered, t = Store(), T0
for i, n in enumerate(("alpha", "beta", "gamma")):
    take(lowered, "I20111", 3, holders[n], "mac-one", n, t)
lowered.release("plan-slot", "I20111#1")
got, d = take(lowered, "I20111", 2, holders["delta"], "mac-two", "delta", t + timedelta(minutes=1))
check("(8a) limit lowered from 3 to 2 and slot 1 freed while slots 2 and 3 still build: a new session is told full",
      got is None and d["action"] == "full" and "2 agents building" in d["message"], (got, d))
_, r = run("room", {"root": "I20111", "limit": 3, "rows": [x for x in lowered.listing("plan-slot", "I20111#") if not x["releasedAt"]], "me": digest(holders["delta"]), "now": iso(t)})
check("(8b) room under the old limit of 3 with two building", r["verdict"] == "room", r)
_, r = run("room", {"root": "I20111", "limit": 1, "rows": [x for x in lowered.listing("plan-slot", "I20111#") if not x["releasedAt"]], "me": digest(holders["delta"]), "now": iso(t)})
check("(8c) limit lowered to 1 with two still building: the full message counts the two", r["verdict"] == "full" and "2 agents building" in r["message"], r)
got, d = take(store, "I20110", 3, holders["zeta"], "mac-two", "zeta", late)
check("(9) another plan root has slots of its own", got == 1 and d["action"] == "proceed", (got, d))

_, d = run("decide", {"mode": "take", "root": root, "slot": 1, "limit": None, "response": {"won": True}, "me": digest("x"), "now": iso(late)})
check("(10) an older server without the limit degrades with one line", d["action"] == "degrade" and "no limit" in d["message"] and "\n" not in d["message"], d)
_, d = run("decide", {"mode": "take", "root": root, "slot": 1, "limit": 3, "response": {"error": "ABSENT"}, "me": digest("x"), "now": iso(late)})
check("(11) a claims service that is not there degrades", d["action"] == "degrade", d)

stories = Store()
stories.claim("story", "I20101", holders["alpha"], "mac-one", "alpha", T0)
stories.claim("story", "I20103", holders["beta"], "mac-two", "beta", T0)
_, f = run("free", {"candidates": ["I20101", "I20102", "I20103"], "rows": stories.listing("story"), "me": digest(holders["beta"]), "now": iso(T0 + timedelta(minutes=5)), "tz": "America/Chicago"})
check("(12) free drops a story another live agent holds, naming it, and keeps this session's own",
      f["free"] == ["I20102", "I20103"] and f["held"][0]["item"] == "I20101" and "alpha on mac-one" in f["held"][0]["by"], f)
_, f = run("free", {"candidates": ["I20101"], "rows": stories.listing("story"), "me": digest(holders["beta"]), "now": iso(T0 + timedelta(minutes=5)), "tz": "America/Chicago", "waiting": [{"item": "I20104", "on": "I20101"}]})
check("(13) nothing free says how many are held and how many wait, and on what",
      f["free"] == [] and f["message"].startswith("Nothing is free right now: 1 held by other agents") and "I20104 (on I20101)" in f["message"], f)
_, f = run("free", {"candidates": ["I20101"], "rows": stories.listing("story"), "me": digest(holders["beta"]), "now": iso(T0 + timedelta(minutes=300))})
check("(14) a lapsed story claim does not hold its story", f["free"] == ["I20101"], f)

releases, answers = Store(), []
for n in ("alpha", "beta"):
    res = releases.claim("epic-release", "I20110", holders[n], "mac-one", n, T0)
    _, d = run("decide", {"mode": "select", "item": "I20110", "response": res, "me": digest(holders[n]), "now": iso(T0), "tz": "America/Chicago"}, claim_helper)
    answers.append(d["action"])
check("(15) two sessions race for one epic release: one proceeds, the other skips", answers == ["proceed", "skip"], answers)

rows = store.listing("plan-slot", root + "#")
mac_one = [r for r in rows if r["machine"] == "mac-one" and not r["releasedAt"]][0]
_, m = run("machine", {"root": root, "rows": rows, "me": digest("claude:newcomer-secret"), "machine": "mac-one", "shared": True, "now": iso(late), "tz": "America/Chicago"})
check("(15a) shared checkouts: a live slot from the same machine makes a second agent there busy, naming it",
      m["verdict"] == "busy" and mac_one["sessionName"] in m["message"] and "Nothing was started" in m["message"], m)
_, m = run("machine", {"root": root, "rows": rows, "me": digest("claude:newcomer-secret"), "machine": "mac-three", "shared": True, "now": iso(late)})
check("(15b) shared checkouts: another machine is ok", m["verdict"] == "ok", m)
_, m = run("machine", {"root": root, "rows": rows, "me": digest("claude:newcomer-secret"), "machine": "mac-one", "shared": False, "now": iso(late)})
check("(15c) a checkout with its own instance is ok beside another agent on the machine", m["verdict"] == "ok", m)
_, m = run("machine", {"root": root, "rows": [mac_one], "me": mac_one["holderDigest"], "machine": "mac-one", "shared": True, "now": iso(late)})
check("(15d) this session's own slot never makes it busy", m["verdict"] == "ok", m)
race = Store()
for n in ("alpha", "beta"):
    race.claim("plan-slot", "I20130#%d" % (1 if n == "alpha" else 2), holders[n], "mac-one", n, T0)
live_rows = race.listing("plan-slot", "I20130#")
_, a = run("machine", {"root": "I20130", "rows": live_rows, "me": digest(holders["alpha"]), "machine": "mac-one", "shared": True, "slot": 1, "now": iso(T0)})
_, b = run("machine", {"root": "I20130", "rows": live_rows, "me": digest(holders["beta"]), "machine": "mac-one", "shared": True, "slot": 2, "now": iso(T0)})
check("(15e) two sessions on one machine that both claimed: the lower slot stays, the higher backs out",
      a["verdict"] == "ok" and b["verdict"] == "busy", (a, b))
check("(16) no holder string appears in anything printed", not any("secret" in s for s in SEEN))
for command, text in (("decide", "not json"), ("decide", "[1]"), ("mine", '{"root": "x", "rows": [], "me": "y"}'),
                      ("full", '{"root": "I20100", "limit": 0, "rows": []}'),
                      ("room", '{"root": "I20100", "limit": 21, "rows": [], "me": "%s"}' % digest("x")),
                      ("machine", '{"root": "I20100", "rows": [], "me": "%s", "machine": "m"}' % digest("x")), ("decide", '{"mode": "take", "root": "I20100", "slot": 1, "limit": 21, "me": "%s"}' % digest("x"))):
    p = subprocess.run([sys.executable, helper, command], input=text, capture_output=True, text=True)
    check("(17) bad input to %s exits 2 with one line and no traceback" % command,
          p.returncode == 2 and "Traceback" not in p.stderr and p.stderr.count("\n") == 1, (p.returncode, p.stderr))
p = subprocess.run([sys.executable, helper, "nonsense"], input="{}", capture_output=True, text=True)
check("(18) an unknown command exits 2", p.returncode == 2, p.stderr)
PY
)"
printf '%s\n' "$OUT"
printf '%s\n' "$OUT" | grep -q "^  FAIL" && FAIL=1
[ "$(printf '%s\n' "$OUT" | grep -c '^  ok')" -ge 31 ] || bad "fewer than 31 checks passed"
exit "$FAIL"
