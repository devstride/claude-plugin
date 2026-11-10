#!/bin/bash
# Tests for skills/review/scripts/independent-review.py. A `gh` on PATH answers from a scenario file
# and logs every call, which proves when a review is started and when it is not. No network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/skills/review/scripts/independent-review.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'PY'
#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
open(os.environ["GH_LOG"], "a").write(" ".join(a)[:160] + "\n")
s = json.load(open(os.environ["GH_SCENARIO"]))
if a[:2] == ["workflow", "run"]:
    open(os.environ["GH_LOG"] + ".dispatched", "w").write("1")
    sys.exit(s.get("dispatchExit", 0))
dispatched = os.path.exists(os.environ["GH_LOG"] + ".dispatched")
if "check-runs" in a[1] and dispatched and s.get("failReads", 0):
    n = os.environ["GH_LOG"] + ".n"
    done = int(open(n).read()) if os.path.exists(n) else 0
    open(n, "w").write(str(done + 1))
    if done < s["failReads"]:
        sys.stderr.write("gh: HTTP 502\n"); sys.exit(1)
if "check-runs" in a[1]:
    print(json.dumps({"check_runs": s.get("after", []) if dispatched else s.get("before", [])})); sys.exit(0)
if "/runs" in a[1]:
    print(json.dumps({"workflow_runs": s.get("runs", [])})); sys.exit(0)
sys.exit(1)
PY
chmod +x "$WORK/bin/gh"
cat > "$WORK/on.json" <<'JSON'
{"review": {"independentReview": {"workflow": "independent-review.yaml", "ref": "master", "check": "independent-review", "reviewerApp": "reviewer-app", "timeoutMinutes": 0.02}}}
JSON
echo '{"review": {}}' > "$WORK/off.json"

OUT="$(PATH="$WORK/bin:$PATH" WORK="$WORK" HELPER="$HELPER" INDEPENDENT_REVIEW_POLL_SECONDS=0.05 INDEPENDENT_REVIEW_GRACE_SECONDS=0 python3 - <<'EOF'
import json, os, subprocess, sys, datetime
work, helper = os.environ["WORK"], os.environ["HELPER"]
H = "a" * 40
def check(conclusion="success", slug="reviewer-app", ident=1, title="Passed", text="", status="completed", name="independent-review"):
    return {"id": ident, "name": name, "status": status, "conclusion": conclusion, "app": {"slug": slug}, "output": {"title": title, "text": text}}
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
def run(scenario, cfg="on.json", args=None):
    log = os.path.join(work, "log")
    for f in (log, log + ".dispatched", log + ".n"):
        if os.path.exists(f):
            os.remove(f)
    path = os.path.join(work, "s.json"); json.dump(scenario, open(path, "w"))
    p = subprocess.run([sys.executable, helper] + (args or ["7", H, "--repo", "acme/widgets"]) + ["--config", os.path.join(work, cfg)],
                       capture_output=True, text=True, env=dict(os.environ, GH_SCENARIO=path, GH_LOG=log))
    calls = open(log).read() if os.path.exists(log) else ""
    return p.returncode, p.stdout, "workflow run" in calls, calls
def case(label, scenario, code, first, dispatched, cfg="on.json", contains=None, args=None):
    rc, out, sent, calls = run(scenario, cfg, args)
    good = rc == code and out.startswith(first) and sent == dispatched and (contains is None or contains in out)
    print(("ok   " if good else "FAIL ") + label + ("" if good else " -> rc=%d sent=%s %r" % (rc, sent, out[:200])))
    return calls
case("(1) not configured: OFF, nothing started", {}, 0, "OFF", False, cfg="off.json")
case("(2) a pass already on this commit is the answer, nothing started", {"before": [check()]}, 0, "PASS " + H, False)
case("(3) a withheld result stands until there is a new commit", {"before": [check("failure", title="Withheld", text="- P1 bug")]}, 2, "WITHHELD " + H, False, contains="- P1 bug")
calls = case("(4) no result: starts it at the configured branch, then reads a pass", {"after": [check()]}, 0, "PASS " + H, True)
print(("ok   " if "workflow run independent-review.yaml --repo acme/widgets --ref master -f pr_number=7" in calls else "FAIL ") + "(4b) it passes only the pull request number, at the production branch")
case("(5) started, then withheld: the findings come back", {"after": [check("failure", title="Withheld: 1", text="- P1 sql")]}, 2, "WITHHELD", True, contains="- P1 sql")
case("(6) another App's pass does not count", {"before": [check(slug="builder-app")], "after": [check()]}, 0, "PASS", True)
case("(7) another App's pass alone never passes", {"after": [check(slug="builder-app")]}, 1, "ERROR no result", True)
case("(8) a newer failure beats an older pass", {"before": [check(ident=1), check("failure", ident=2, title="Withheld")]}, 2, "WITHHELD", False)
case("(9) a run still in progress is not a result", {"before": [check(None, status="in_progress")], "after": [check()]}, 0, "PASS", True)
case("(10) the run ended with no result: ERROR, never a pass",
     {"runs": [{"status": "completed", "created_at": "2099-01-01T00:00:00Z", "html_url": "https://x/1"}]}, 1, "ERROR the review run ended", True, contains="https://x/1")
case("(11) no answer in time: ERROR", {}, 1, "ERROR no result", True)
case("(12) a dispatch GitHub refuses: ERROR", {"dispatchExit": 1}, 1, "ERROR gh workflow run", True)
case("(13) a malformed head is refused before anything runs", {}, 1, "ERROR usage", False, args=["7", "abc"])
case("(14) a malformed pull request number is refused", {}, 1, "ERROR usage", False, args=["7;x", H])
case("(15) a failed read or two while waiting is not the end", {"after": [check()], "failReads": 2}, 0, "PASS", True)
case("(16) GitHub staying unreadable: ERROR, never a pass", {"after": [check()], "failReads": 99}, 1, "ERROR gh api", True)
EOF
)"
echo "$OUT" | sed 's/^/  /'
FAIL=0; echo "$OUT" | grep -q '^FAIL' && FAIL=1
[ "$(echo "$OUT" | grep -c '^ok')" -ge 15 ] || { echo "  FAIL too few cases ran"; FAIL=1; }
exit $FAIL
