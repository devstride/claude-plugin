#!/usr/bin/env bash
# Wait for the registered cloud reviewers on a pull request — the ONE background poll
# `review` step 2 launches. Bash 3.2 does the argument parsing; python3 does the rest.
#
# Contract (skills/review/references/reviewer-latency.md holds the reasoning):
#   - Waits ONLY on the reviewers it is given, each identified by graphqlBotId, and only from the
#     created_at of that reviewer's review_requested event (resolved from the timeline when the
#     caller passes null). A reviewer with no such event is reported not-registered and never
#     waited on.
#   - Backs off 20 s → 90 s (×1.5, capped), so a 20-minute bound costs ≤ 16 ticks, not ≈ 40.
#     The last sleep is clamped to the bound, so a wait never overshoots it by a tick.
#   - Exits the tick every registered reviewer has posted a review from THIS cycle
#     (id > the high-water mark). A reviewer past its bound is a non-responder; when every
#     remaining one is, the result is proceed-p95 (a learned bound ended it) or timeout.
#   - The bound per reviewer is its learned p95 + slack, clamped to [window, timeout] — or the
#     full timeout when the cache is cold, corrupt, unreadable, has too few samples, or
#     --fixed-bound is given. The cache can only ever SHORTEN a wait, never lengthen it, and it
#     is never an error.
#   - Learns latency from SERVER timestamps only (submitted_at − registeredAt); never from the
#     tick that observed it, which would inflate its own p95 through the backoff.
#   - Prints one status line per tick and one final `RESULT {...}` JSON line, which is
#     authoritative. Exit 0 all-posted, 3 when any non-responder (incl. gh-unavailable), 2 usage.
#
# Usage:
#   wait-for-reviewers.sh --repo OWNER/REPO --pr N --reviewers-json FILE|- --timeout-minutes M
#     [--window-minutes 2] [--since-review-id N] [--fixed-bound]
#     [--min-samples 5] [--slack-seconds 120] [--first-tick 20] [--max-tick 90]
#     [--cache FILE] [--dry-run FIXTURE.json]
set -u
command -v python3 >/dev/null 2>&1 || { echo 'RESULT {"result":"usage-error","error":"python3 is required"}'; exit 2; }
REPO=""; PR=""; REVIEWERS=""; TIMEOUT=""; WINDOW=2; SINCE=""; FIXED=0; MINS=5; SLACK=120; FIRST=20; MAXT=90; CACHE=""; DRY=""
need() { [ $# -ge 2 ] || { echo "wait-for-reviewers: $1 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) need "$@"; REPO="$2"; shift 2 ;;
    --pr) need "$@"; PR="$2"; shift 2 ;;
    --reviewers-json) need "$@"; REVIEWERS="$2"; shift 2 ;;
    --timeout-minutes) need "$@"; TIMEOUT="$2"; shift 2 ;;
    --window-minutes) need "$@"; WINDOW="$2"; shift 2 ;;
    --since-review-id) need "$@"; SINCE="$2"; shift 2 ;;
    --fixed-bound) FIXED=1; shift ;;
    --min-samples) need "$@"; MINS="$2"; shift 2 ;;
    --slack-seconds) need "$@"; SLACK="$2"; shift 2 ;;
    --first-tick) need "$@"; FIRST="$2"; shift 2 ;;
    --max-tick) need "$@"; MAXT="$2"; shift 2 ;;
    --cache) need "$@"; CACHE="$2"; shift 2 ;;
    --dry-run) need "$@"; DRY="$2"; shift 2 ;;
    -h|--help) awk 'NR>1 && !/^#/{exit} NR>1{print}' "$0"; exit 0 ;;
    *) echo "wait-for-reviewers: unknown argument: $1" >&2; exit 2 ;;
  esac
done
for v in REPO PR REVIEWERS TIMEOUT; do eval "val=\${$v}"; [ -n "$val" ] || { echo "wait-for-reviewers: --$(echo "$v" | tr 'A-Z' 'a-z' | sed 's/reviewers/reviewers-json/; s/timeout/timeout-minutes/') is required" >&2; exit 2; }; done
[ -n "$CACHE" ] || CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/devstride-plugin/reviewer-latency.json"
# `-` means stdin — spool it to a file first, because the python block below is itself fed on stdin.
if [ "$REVIEWERS" = "-" ]; then REVIEWERS="$(mktemp)"; cat > "$REVIEWERS"; trap 'rm -f "$REVIEWERS"' EXIT; fi
export W_REPO="$REPO" W_PR="$PR" W_REVIEWERS="$REVIEWERS" W_TIMEOUT="$TIMEOUT" W_WINDOW="$WINDOW" W_SINCE="$SINCE" W_FIXED="$FIXED" W_MINS="$MINS" W_SLACK="$SLACK" W_FIRST="$FIRST" W_MAXT="$MAXT" W_CACHE="$CACHE" W_DRY="$DRY"
exec python3 - <<'PY'
import json, math, os, subprocess, sys, tempfile, time, datetime as dt

E = os.environ
REPO, PR, TIMEOUT = E["W_REPO"], E["W_PR"], float(E["W_TIMEOUT"]) * 60
WINDOW, SINCE = float(E["W_WINDOW"]) * 60, E["W_SINCE"]
FIXED, MINS, SLACK = E["W_FIXED"] == "1", int(E["W_MINS"]), float(E["W_SLACK"])
FIRST, MAXT, CACHE, DRY = float(E["W_FIRST"]), float(E["W_MAXT"]), E["W_CACHE"], E["W_DRY"]

def parse_ts(s):
    return dt.datetime.strptime(s.replace("Z", "+0000"), "%Y-%m-%dT%H:%M:%S%z").timestamp()
def iso(t): return dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
def result(obj, code):
    print("RESULT " + json.dumps(obj, separators=(",", ":"))); sys.stdout.flush(); sys.exit(code)

# --- inputs ---------------------------------------------------------------------------------
try:
    raw = open(E["W_REVIEWERS"], encoding="utf-8").read()
    reviewers = json.loads(raw)
    assert isinstance(reviewers, list) and all(r.get("graphqlBotId") for r in reviewers)
except Exception as ex:  # noqa: BLE001
    result({"result": "usage-error", "error": "reviewers-json: %s" % ex}, 2)

# --- clock + gh, real or canned ---------------------------------------------------------------
fixture = None
if DRY:
    try: fixture = json.load(open(DRY, encoding="utf-8"))
    except Exception as ex:  # noqa: BLE001
        result({"result": "usage-error", "error": "dry-run fixture: %s" % ex}, 2)
    clock = {"now": parse_ts(fixture["now"])}
    fail_ticks = set(fixture.get("failTicks", []))
    calls = {"n": 0}
    def now(): return clock["now"]
    def sleep(s): clock["now"] += s
    def gh_reviews():
        i = calls["n"]; calls["n"] += 1
        if i in fail_ticks: return None
        return [r for r in fixture.get("reviews", []) if parse_ts(r["submitted_at"]) <= now()]
    def gh_timeline(): return fixture.get("timeline", [])
else:
    calls = {"n": 0}
    def now(): return time.time()
    def sleep(s): time.sleep(s)
    def gh(*args):
        r = subprocess.run(["gh", "api"] + list(args), capture_output=True, text=True)
        if r.returncode != 0: return None
        try: return json.loads(r.stdout)
        except Exception: return None  # noqa: BLE001
    def gh_reviews():
        calls["n"] += 1
        pages = gh("repos/%s/pulls/%s/reviews" % (REPO, PR), "--paginate", "--slurp")
        if pages is None: return None
        return [x for page in pages for x in (page if isinstance(page, list) else [page])]
    def gh_timeline():
        pages = gh("repos/%s/issues/%s/timeline" % (REPO, PR), "--paginate", "--slurp") or []
        return [x for page in pages for x in (page if isinstance(page, list) else [page])]

# --- registration timestamps ------------------------------------------------------------------
timeline = None
active, not_registered = [], []
for r in reviewers:
    reg = r.get("registeredAt")
    if reg is None:
        if timeline is None: timeline = gh_timeline()
        evs = [e for e in timeline if e.get("event") == "review_requested" and (e.get("requested_reviewer") or {}).get("node_id") == r["graphqlBotId"]]
        reg = max((e["created_at"] for e in evs), default=None)
    if reg is None: not_registered.append(r["graphqlBotId"]); continue
    active.append({"id": r["graphqlBotId"], "name": r.get("name", r["graphqlBotId"]), "login": r.get("reviewsLogin"), "registeredAt": parse_ts(reg)})

# --- cache: advisory, never an error -----------------------------------------------------------
cache, cache_state = {"version": 1, "reviewers": {}}, "cold"
try:
    if os.path.exists(CACHE):
        loaded = json.load(open(CACHE, encoding="utf-8"))
        assert isinstance(loaded.get("reviewers"), dict)
        cache, cache_state = loaded, "warm"
except Exception:  # noqa: BLE001
    cache, cache_state = {"version": 1, "reviewers": {}}, "corrupt"

def p95(samples):
    s = sorted(samples); return s[max(0, math.ceil(0.95 * len(s)) - 1)]
for a in active:
    samples = [x.get("latencySeconds") for x in (cache["reviewers"].get(a["id"]) or {}).get("samples", []) if isinstance(x.get("latencySeconds"), (int, float))]
    if FIXED: a["bound"], a["source"], a["p95"], a["n"] = TIMEOUT, "fixed", None, len(samples)
    elif cache_state != "warm" or len(samples) < MINS: a["bound"], a["source"], a["p95"], a["n"] = TIMEOUT, "pollTimeoutMinutes", None, len(samples)
    else:
        a["p95"], a["n"] = p95(samples), len(samples)
        a["bound"], a["source"] = min(max(a["p95"] + SLACK, WINDOW), TIMEOUT), "learned-p95"

# --- high-water mark ------------------------------------------------------------------------
t0 = now()
since = None
if SINCE != "":
    # The caller just captured the high-water mark, so nothing before now is ours: the first
    # fetch waits one interval instead of firing immediately, which is what keeps a 20-minute
    # bound at 16 ticks.
    since = int(SINCE); pending = None
    sleep(max(0.0, min(FIRST, min(a["bound"] - (now() - a["registeredAt"]) for a in active) if active else FIRST)))
    interval0 = FIRST * 1.5
else:
    first = gh_reviews()
    if first is None: since = 0
    else: since = max([x.get("id", 0) for x in first] + [0])
    interval0 = FIRST
    pending = first  # that fetch IS the first tick's data — do not fetch twice at t0

# --- the loop ---------------------------------------------------------------------------------
responded, failures, tick, interval = {}, 0, 0, interval0
def matches(review, a):
    u = review.get("user") or {}
    return u.get("node_id") == a["id"] or (a["login"] and u.get("login") == a["login"])
while True:
    reviews = pending if pending is not None else gh_reviews(); pending = None
    tick += 1
    if reviews is None:
        failures += 1
        print("tick %d +%ds: gh unavailable (%d consecutive)" % (tick, int(now() - t0), failures))
        if failures >= 3:
            result({"result": "gh-unavailable", "elapsedSeconds": int(now() - t0), "pollCalls": calls["n"], "responded": [], "cacheState": cache_state,
                    "nonResponders": [{"graphqlBotId": a["id"], "name": a["name"], "waitedSeconds": int(now() - a["registeredAt"]), "boundSeconds": int(a["bound"]), "boundSource": "gh-unavailable"} for a in active if a["id"] not in responded],
                    "notRegistered": not_registered}, 3)
    else:
        failures = 0
        for a in active:
            if a["id"] in responded: continue
            mine = [x for x in reviews if x.get("id", 0) > since and matches(x, a) and x.get("submitted_at")]
            if mine:
                x = min(mine, key=lambda x: x["id"])
                responded[a["id"]] = {"graphqlBotId": a["id"], "reviewId": x["id"], "submittedAt": x["submitted_at"], "latencySeconds": int(round(parse_ts(x["submitted_at"]) - a["registeredAt"]))}
    waiting = [a for a in active if a["id"] not in responded]
    past = [a for a in waiting if now() - a["registeredAt"] >= a["bound"]]
    print("tick %d +%ds: " % (tick, int(now() - t0)) + (" | ".join(
        "%s %s (bound %ds, %s%s)" % (a["id"], "PAST BOUND" if a in past else "waiting", a["bound"], a["source"], (" p95 %ds n=%d" % (a["p95"], a["n"])) if a["p95"] is not None else "") for a in waiting) or "all posted"))
    if not waiting or len(past) == len(waiting): break
    # sleep until the next tick, but never past the nearest remaining bound
    remaining = min(a["bound"] - (now() - a["registeredAt"]) for a in waiting if a not in past)
    sleep(max(0.0, min(interval, remaining)))
    interval = min(interval * 1.5, MAXT)

# --- learn, from server timestamps only ---------------------------------------------------------
rejected = []
for a in active:
    r = responded.get(a["id"])
    if not r: continue
    lat = r["latencySeconds"]
    if lat < 0 or lat > 86400: rejected.append({"graphqlBotId": a["id"], "latencySeconds": lat}); print("rejected sample %s: %ds is outside [0, 86400]" % (a["id"], lat)); continue
    entry = cache["reviewers"].setdefault(a["id"], {"samples": []})
    entry["samples"] = (entry.get("samples") or [])[-19:] + [{"at": iso(now()), "latencySeconds": lat, "repo": REPO, "pr": int(PR) if str(PR).isdigit() else PR}]
    entry["updatedAt"] = iso(now())
if any(a["id"] in responded and a["id"] not in {x["graphqlBotId"] for x in rejected} for a in active):
    try:
        os.makedirs(os.path.dirname(CACHE), exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(CACHE), prefix=".reviewer-latency.")
        with os.fdopen(fd, "w", encoding="utf-8") as f: json.dump(cache, f, indent=1); f.write("\n")
        os.replace(tmp, CACHE)
    except Exception:  # noqa: BLE001
        cache_state = "unwritable"

non = [{"graphqlBotId": a["id"], "name": a["name"], "waitedSeconds": int(now() - a["registeredAt"]), "boundSeconds": int(a["bound"]), "boundSource": a["source"]} for a in active if a["id"] not in responded]
if not non: res = "all-posted"
elif any(x["boundSource"] == "learned-p95" for x in non): res = "proceed-p95"
else: res = "timeout"
result({"result": res, "elapsedSeconds": int(now() - t0), "pollCalls": calls["n"], "sinceReviewId": since,
        "responded": list(responded.values()), "nonResponders": non, "notRegistered": not_registered,
        "rejectedSamples": rejected, "cacheState": cache_state, "cache": CACHE}, 0 if res == "all-posted" else 3)
PY
