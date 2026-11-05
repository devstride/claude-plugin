#!/bin/bash
# Tests for skills/build-item/scripts/session_summary.py — every secret shape is redacted, ordinary
# paths and commit hashes survive, limits are enforced, unknown keys are dropped, and the required
# fields are checked. No network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/skills/build-item/scripts/session_summary.py"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }

OUT="$(python3 - "$HELPER" <<'PY'
import json, subprocess, sys
helper = sys.argv[1]
BASE = {"itemNumber": "I123", "sessionId": "s-1", "agent": {"name": "claude"}, "startedAt": "2026-01-01T00:00:00Z"}

def run(extra, base=BASE):
    p = subprocess.run([sys.executable, helper], input=json.dumps({**base, **extra}), capture_output=True, text=True)
    return p.returncode, (json.loads(p.stdout) if p.returncode == 0 else p.stderr)

def check(name, cond):
    print(("ok   " if cond else "FAIL ") + name)

# Secret shapes are redacted in prose (built from parts so this file holds no real-looking secret).
secrets = {
    "private key": "-----BEGIN RSA " + "PRIVATE KEY-----\nMIIabc\n-----END RSA " + "PRIVATE KEY-----",
    "url credentials": "clone https://user:hunter2@example.com/repo.git",
    "bearer": "Authorization: Bearer abc123def456ghi",
    "basic": "Basic dXNlcjpwYXNzMTIzNDU2",
    "github pat": "ghp_" + "a" * 36,
    "github fine grained": "github_pat_" + "A1b2" * 8,
    "aws key": "AKIA" + "ABCDEFGH12345678",
    "aws temp key": "ASIA" + "ABCDEFGH12345678",
    "sk key": "sk-" + "abcdEFGH1234" * 2,
    "stripe": "sk_" + "live_" + "abcdefgh12345678",
    "slack": "xoxb-" + "123456789012-abcdef",
    "jwt": "eyJhbGciOiJI.eyJzdWIiOiIx.SflKxwRJSMeKKF2QT4",
    "password assignment": "password=correcthorse",
    "token colon": "api_key: zzz999",
    "email": "ask bob@example.com about it",
    "long mixed word": "Abcdefghijklmnopqrstuvwxyz0123456789ABCD",
    "letters-only basic header": "Authorization: Basic dXNlcjpwYXNz",
    "lowercase bearer header": "authorization: bearer abcdefghijklmn",
    "token in backticks": "`Abcdefghijklmnopqrstuvwxyz0123456789ABCD`",
    "32-hex key": "0123456789abcdef" * 2,
    "any authorization scheme": "Authorization: ApiKey supersecretcredentialvalue",
    "digest header": 'Authorization: Digest username="u", response="6629fae49393a05397450978507c4ef1"',
    "secret_key assignment": "SECRET_KEY=hunter2",
}
for name, text in secrets.items():
    rc, o = run({"intent": "note: " + text + " end"})
    s = o["intent"] if rc == 0 else ""
    leaked = [frag for frag in ("hunter2", "abc123def456ghi", "dXNlcjpwYXNzMTIzNDU2", "a" * 20, "ABCDEFGH12345678",
              "abcdgh12345678", "123456789012", "SflKxwRJSMeKKF2QT4", "correcthorse", "zzz999", "bob@example.com",
              "MIIabc", "Abcdefghijklmnopqrstuvwxyz0123456789ABCD", "dXNlcjpwYXNz", "abcdefghijklmn",
              "0123456789abcdef" * 2, "supersecretcredentialvalue", "6629fae4") if frag in s]
    check("redacts " + name, rc == 0 and "[redacted]" in s and not leaked)

rc, o = run({"intent": "password=correcthorse and https://u:p@host.example/x"})
check("keeps the name and the host", "password=[redacted]" in o["intent"] and "https://[redacted]@host.example/x" in o["intent"])

# Things that must survive.
path = "skills/Build/References/AbcdefGhijklmnopqrstuvwxyz0123456789Zz.md"
sha = "0123456789abcdef0123456789abcdef01234567"
rc, o = run({"filesTouched": [path], "intent": "fixed in " + sha + " and see src/a-b.py", "branch": "phil/26-01-01/x"})
check("mixed-case long file path survives", o["filesTouched"] == [path])
check("40-hex sha survives in prose", sha in o["intent"] and "src/a-b.py" in o["intent"])
check("branch survives", o["branch"] == "phil/26-01-01/x")
prose = "Basic setup, then edit frontend/src/components/core/SelectChip2ComponentWithLongName.vue."
rc, o = run({"intent": prose})
check("ordinary prose and a long file path in prose survive", o["intent"] == prose)
rc, o = run({"directedBy": {"email": "dev@example.com", "username": "dev"}})
check("directedBy identity kept", o["directedBy"] == {"username": "dev", "email": "dev@example.com"})
rc, o = run({"reviewEngines": [{"name": "codex", "outcome": "clean " + "ghp_" + "b" * 36}]})
check("review outcome scrubbed", "ghp_" not in o["reviewEngines"][0]["outcome"])

# Bounds and shape.
rc, o = run({"intent": "x " * 800, "errorReason": "e" * 900, "filesTouched": ["f%d" % i for i in range(300)],
             "toolsTouched": ["t%d" % i for i in range(150)],
             "reviewEngines": [{"name": "e%d" % i} for i in range(20)]})
check("intent capped at 1000", len(o["intent"]) <= 1000)
check("errorReason capped at 500", len(o["errorReason"]) == 500)
check("filesTouched capped at 200", len(o["filesTouched"]) == 200)
check("toolsTouched capped at 100", len(o["toolsTouched"]) == 100)
check("reviewEngines capped at 10", len(o["reviewEngines"]) == 10)
rc, o = run({"mystery": 1, "agent": {"name": "claude", "extra": "x"}, "outcome": "weird", "pullRequest": {"number": 5, "foo": 1}})
check("unknown keys dropped", "mystery" not in o and o["agent"] == {"name": "claude"} and o["pullRequest"] == {"number": 5})
check("bad outcome dropped", "outcome" not in o)
rc, o = run({"outcome": "interrupted", "errorReason": "stopped"})
check("good outcome kept", o["outcome"] == "interrupted")
rc, o = run({"filesTouched": [], "intent": "   "})
check("empty values omitted", "filesTouched" not in o and "intent" not in o)

# Required fields and bad input.
rc, o = run({}, base={"itemNumber": "I1"})
check("missing required fields exit 1", rc == 1 and "sessionId" in o and "agent.name" in o)
p = subprocess.run([sys.executable, helper], input="[1]", capture_output=True, text=True)
check("non-object exits 1", p.returncode == 1)
p = subprocess.run([sys.executable, helper], input="not json", capture_output=True, text=True)
check("bad json exits 1", p.returncode == 1)
PY
)"
echo "$OUT"
echo "$OUT" | grep -q '^FAIL' && FAIL=1
[ -n "$OUT" ] || FAIL=1
[ "$FAIL" -eq 0 ]
