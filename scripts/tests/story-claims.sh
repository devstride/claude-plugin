#!/bin/bash
# Tests for skills/build-item/scripts/story-claim.py — two agent sessions pick from one ready-set
# against an in-memory stand-in for claim_work, and every answer goes through `decide`: a lost
# claim is skipped, a named story held by someone else stops, an expired claim is taken over, a
# missing or refused claims service degrades once, a heartbeat that is no longer the holder's
# stops, and the holder string never appears in any output. No network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/skills/build-item/scripts/story-claim.py"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }

OUT="$(python3 - "$HELPER" <<'PY'
import hashlib, json, subprocess, sys
from datetime import datetime, timedelta, timezone
helper = sys.argv[1]
T0 = datetime(2026, 1, 15, 18, 0, tzinfo=timezone.utc)   # 12:00 PM CST
iso = lambda d: d.strftime("%Y-%m-%dT%H:%M:%SZ")
digest = lambda s: hashlib.sha256(s.encode()).hexdigest()

class Store:
    """The claim_work / heartbeat_claim / release_claim rules, in memory."""
    def __init__(self): self.rows = {}
    def claim(self, key, holder, machine, session, now, minutes=240, takeover=None):
        row, me = self.rows.get(key), digest(holder)
        new = {"kind": "story", "key": key, "holderDigest": me, "machine": machine, "sessionName": session,
               "claimedAt": iso(now), "heartbeatAt": iso(now), "expiresAt": iso(now + timedelta(minutes=minutes)),
               "releasedAt": None, "outcome": None}
        if row is None or (row["releasedAt"] and row["outcome"] != "done"):
            self.rows[key] = new; return {"won": True, "claim": new}
        if row["releasedAt"]:
            return {"won": False, "final": True, "claim": row}
        if row["holderDigest"] == me:
            row.update(heartbeatAt=iso(now), expiresAt=iso(now + timedelta(minutes=minutes)))
            return {"won": True, "renewed": True, "claim": row}
        if datetime.fromisoformat(row["expiresAt"].replace("Z", "+00:00")) <= now:
            if takeover == row["holderDigest"]:
                self.rows[key] = new; return {"won": True, "takenOver": True, "claim": new}
            return {"won": False, "expired": True, "claim": row}
        return {"won": False, "claim": row}
    def heartbeat(self, key, holder, now):
        row = self.rows.get(key)
        if row and not row["releasedAt"] and row["holderDigest"] == digest(holder):
            row["expiresAt"] = iso(now + timedelta(minutes=240)); return row
        return {"outcome": "NOT_HOLDER", "current": row}
    def release(self, key, holder, outcome):
        row = self.rows.get(key)
        if row and row["holderDigest"] == digest(holder):
            row.update(releasedAt="x", outcome=outcome); return {"released": True, "claim": row}
        return {"outcome": "NOT_HOLDER", "current": row}

SEEN = []
def decide(mode, response, holder, now, item="I1", tz="America/Chicago"):
    req = {"mode": mode, "item": item, "response": response, "me": digest(holder), "now": iso(now), "tz": tz}
    p = subprocess.run([sys.executable, helper, "decide"], input=json.dumps(req), capture_output=True, text=True)
    SEEN.append(p.stdout + p.stderr)
    return p.returncode, json.loads(p.stdout) if p.returncode == 0 else {"action": "crash", "message": p.stderr}

def select(store, ready, holder, machine, session, now):
    """Step 0 as the skill runs it: claim the first candidate, drop it when lost, take the next."""
    for story in ready:
        res = store.claim(story, holder, machine, session, now)
        _, d = decide("select", res, holder, now, story)
        if d["action"] == "takeover":
            res = store.claim(story, holder, machine, session, now, takeover=d["takeoverDigest"])
            _, d = decide("select", res, holder, now, story)
        if d["action"] == "proceed":
            return story, d
    return None, d

def check(label, good, detail=""):
    print(("  ok   " if good else "  FAIL ") + label + ("" if good else "  " + str(detail)))

A, B = "claude:session-a-secret", "claude:session-b-secret"
store, ready = Store(), ["S1", "S2", "S3"]

got, d = select(store, ready, A, "mac-one", "alpha", T0)
check("(1) session A claims S1 first", got == "S1" and d["action"] == "proceed", d)
res = store.claim("S1", B, "mac-two", "beta", T0)
_, d = decide("select", res, B, T0, "S1")
check("(2) B's claim on S1 is lost, so B skips it, naming the holder", d["action"] == "skip" and "alpha" in d["message"] and "mac-one" in d["message"], d)
got, d = select(store, ready, B, "mac-two", "beta", T0)
check("(3) B then takes S2", got == "S2" and d["action"] == "proceed", (got, d))

res = store.claim("S1", B, "mac-two", "beta", T0 + timedelta(minutes=5))
_, d = decide("named", res, B, T0 + timedelta(minutes=5), "S1")
check("(4) a NAMED S1 held by A stops, naming session, machine and a local time with its zone",
      d["action"] == "stop" and "alpha" in d["message"] and "mac-one" in d["message"] and "CST" in d["message"] and "12:00 PM" in d["message"], d)
res = store.claim("S1", A, "mac-one", "alpha", T0 + timedelta(minutes=10))
_, d = decide("resume", res, A, T0 + timedelta(minutes=10), "S1")
check("(5) a resumed S1 that A already holds is renewed and carries on", d["action"] == "proceed" and "renewed" in d["message"], d)

late = T0 + timedelta(minutes=10 + 241)
res = store.claim("S1", B, "mac-two", "beta", late)
_, d = decide("select", res, B, late, "S1")
check("(6) an expired S1 is a takeover carrying A's digest", d["action"] == "takeover" and d["takeoverDigest"] == digest(A), d)
res = store.claim("S1", B, "mac-two", "beta", late, takeover=d["takeoverDigest"])
_, d2 = decide("select", res, B, late, "S1")
check("(7) the takeover claim then wins for B", d2["action"] == "proceed" and "Took over" in d2["message"], d2)

for err, needle in (("ABSENT", "not available"), ("FORBIDDEN", "MANAGE_AGENT_CLAIMS"), ("UNREACHABLE", "could not be reached")):
    _, d = decide("select", {"error": err}, A, T0)
    check("(8) %s degrades with a one-line message" % err, d["action"] == "degrade" and needle in d["message"] and "\n" not in d["message"], d)

_, d = decide("heartbeat", store.heartbeat("S1", B, late), B, late, "S1")
check("(9) a heartbeat by the holder proceeds", d["action"] == "proceed", d)
_, d = decide("heartbeat", store.heartbeat("S1", A, late), A, late, "S1")
check("(10) a heartbeat after another agent took the story stops, naming it", d["action"] == "stop" and "beta" in d["message"], d)
_, d = decide("heartbeat", store.heartbeat("S9", A, late), A, late, "S9")
check("(11) a heartbeat on a claim nobody holds asks to claim again", d["action"] == "reclaim", d)

res = store.release("S2", B, "done")
check("(12) release with outcome done", res.get("released") is True and store.rows["S2"]["outcome"] == "done", res)
res = store.claim("S2", A, "mac-one", "alpha", late)
_, d = decide("select", res, A, late, "S2")
check("(13) a finished story is skipped when selecting", d["action"] == "skip" and "finished" in d["message"], d)
_, d = decide("named", res, A, late, "S2")
check("(14) a finished story that was named stops", d["action"] == "stop", d)

# commands-provider answers: verdict plus exit code
_, d = decide("select", {"verdict": "LOST", "exitCode": 2, "claim": store.rows["S3"] if "S3" in store.rows else {"sessionName": "gamma", "machine": "m3", "claimedAt": iso(T0), "expiresAt": iso(late + timedelta(hours=1)), "holderDigest": digest("x")}}, A, late, "S3")
check("(15) a commands LOST skips like a lost claim_work", d["action"] == "skip", d)
_, d = decide("heartbeat", {"verdict": "NOT HOLDER", "exitCode": 4, "claim": {"sessionName": "gamma", "machine": "m3", "claimedAt": iso(T0), "expiresAt": iso(late + timedelta(hours=1)), "holderDigest": digest("x")}}, A, late, "S3")
check("(16) a commands NOT HOLDER stops", d["action"] == "stop", d)
_, d = decide("select", {"verdict": "FORBIDDEN", "exitCode": 1}, A, late, "S3")
check("(17) a commands FORBIDDEN degrades naming the permission", d["action"] == "degrade" and "MANAGE_AGENT_CLAIMS" in d["message"], d)
_, d = decide("select", {"verdict": "BUSY", "exitCode": 2}, A, late, "S3")
_, e = decide("select", {"verdict": "", "exitCode": 0}, A, late, "S3")
_, f = decide("heartbeat", {"verdict": "NOT_HOLDER", "exitCode": 1}, A, late, "S3")
check("(17a) a verdict the contract does not name degrades, whatever the exit code", all(x["action"] == "degrade" for x in (d, e, f)), (d, e, f))

check("(18) no holder string appears in anything decide printed", not any("secret" in s for s in SEEN))
p = subprocess.run([sys.executable, helper, "digest"], input="claude:session-a-secret\n", capture_output=True, text=True)
check("(19) digest prints the sha256 of stdin", p.stdout.strip() == digest(A), p.stdout)
p = subprocess.run([sys.executable, helper, "decide"], input="not json", capture_output=True, text=True)
check("(20) bad input exits 2 with one line, no traceback", p.returncode == 2 and "Traceback" not in p.stderr, p.stderr)
PY
)"
printf '%s\n' "$OUT"
printf '%s\n' "$OUT" | grep -q "^  FAIL" && FAIL=1
[ "$(printf '%s\n' "$OUT" | grep -c '^  ok')" -ge 20 ] || { bad "fewer than 20 checks passed"; }
exit "$FAIL"
