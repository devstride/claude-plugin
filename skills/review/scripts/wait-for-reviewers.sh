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
case "$FIRST$MAXT$TIMEOUT" in *[!0-9.]*) echo "wait-for-reviewers: --first-tick, --max-tick and --timeout-minutes must be numbers" >&2; exit 2 ;; esac
export W_REPO="$REPO" W_PR="$PR" W_REVIEWERS="$REVIEWERS" W_TIMEOUT="$TIMEOUT" W_WINDOW="$WINDOW" W_SINCE="$SINCE" W_FIXED="$FIXED" W_MINS="$MINS" W_SLACK="$SLACK" W_FIRST="$FIRST" W_MAXT="$MAXT" W_CACHE="$CACHE" W_DRY="$DRY"
python3 - <<'PY'
import json, math, os, subprocess, sys, tempfile, time, datetime as dt, re

E = os.environ
CACHE, DRY, REPO, PR = os.path.abspath(E["W_CACHE"]), E["W_DRY"], E["W_REPO"], E["W_PR"]
def result(obj, code):
    base = {"result": None, "elapsedSeconds": 0, "pollCalls": 0, "sinceReviewId": None, "responded": [], "nonResponders": [],
            "notRegistered": [], "rejectedSamples": [], "cacheState": "cold", "cache": CACHE}
    base.update(obj); print("RESULT " + json.dumps(base, separators=(",", ":"))); sys.stdout.flush(); sys.exit(code)
def usage(msg): result({"result": "usage-error", "error": msg}, 2)

# --- numeric inputs, validated ------------------------------------------------------------------
try:
    TIMEOUT = float(E["W_TIMEOUT"]) * 60; WINDOW = float(E["W_WINDOW"]) * 60
    MINS = int(E["W_MINS"]); SLACK = float(E["W_SLACK"]); FIRST = float(E["W_FIRST"]); MAXT = float(E["W_MAXT"])
    SINCE = int(E["W_SINCE"]) if E["W_SINCE"] != "" else None
    assert TIMEOUT > 0 and WINDOW >= 0 and MINS >= 1 and SLACK >= 0 and FIRST >= 1 and MAXT >= FIRST
except Exception as ex:  # noqa: BLE001
    usage("numeric option out of range or not a number (timeout > 0, min-samples >= 1, first-tick >= 1, max-tick >= first-tick): %s" % ex)
FIXED = E["W_FIXED"] == "1"

def parse_ts(s):
    """GitHub ISO-8601: `Z` or `+00:00`, optional fractional seconds."""
    s = re.sub(r"\.\d+", "", str(s).strip()).replace("Z", "+00:00")
    return dt.datetime.strptime(s, "%Y-%m-%dT%H:%M:%S%z").timestamp()
def iso(t): return dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

try:
    reviewers = json.loads(open(E["W_REVIEWERS"], encoding="utf-8").read())
    assert isinstance(reviewers, list) and all(isinstance(r, dict) and r.get("graphqlBotId") for r in reviewers)
except Exception as ex:  # noqa: BLE001
    usage("reviewers-json: %s" % ex)

# --- clock + gh, real or canned ---------------------------------------------------------------
calls = {"n": 0}
if DRY:
    try: fixture = json.load(open(DRY, encoding="utf-8")); clock = {"now": parse_ts(fixture["now"])}
    except Exception as ex:  # noqa: BLE001
        usage("dry-run fixture: %s" % ex)
    fail_ticks = set(fixture.get("failTicks", [])); tl = {"fails": int(fixture.get("timelineFails", 0))}
    def now(): return clock["now"]
    def sleep(s): clock["now"] += s
    def gh_reviews():
        i = calls["n"]; calls["n"] += 1
        if i in fail_ticks: return None
        return [r for r in fixture.get("reviews", []) if parse_ts(r["submitted_at"]) <= now()]
    def gh_timeline():
        if tl["fails"] > 0: tl["fails"] -= 1; return None
        return fixture.get("timeline", [])
else:
    def now(): return time.time()
    def sleep(s): time.sleep(s)
    def gh(*args):
        try: r = subprocess.run(["gh", "api"] + list(args), capture_output=True, text=True, timeout=60)
        except (subprocess.TimeoutExpired, OSError): return None
        if r.returncode != 0: return None
        try: v = json.loads(r.stdout)
        except Exception: return None  # noqa: BLE001
        if not isinstance(v, list): return None
        out = []
        for page in v:
            for x in (page if isinstance(page, list) else [page]):
                if isinstance(x, dict): out.append(x)
        return out
    def gh_reviews(): calls["n"] += 1; return gh("repos/%s/pulls/%s/reviews" % (REPO, PR), "--paginate", "--slurp")
    def gh_timeline(): return gh("repos/%s/issues/%s/timeline" % (REPO, PR), "--paginate", "--slurp")

t0 = now()
def unavailable(active, since, responded, cache_state, extra=None):
    o = {"result": "gh-unavailable", "elapsedSeconds": int(now() - t0), "pollCalls": calls["n"], "sinceReviewId": since,
         "responded": list(responded.values()), "cacheState": cache_state,
         "nonResponders": [{"graphqlBotId": a["id"], "name": a["name"], "waitedSeconds": int(now() - a["registeredAt"]), "boundSeconds": int(a["bound"]), "boundSource": "gh-unavailable"} for a in active if a["id"] not in responded],
         "notRegistered": [r["graphqlBotId"] for r in reviewers if r["graphqlBotId"] not in {a["id"] for a in active}]}
    if extra: o.update(extra)
    return o

# --- registration timestamps (a timeline failure is an outage, never "not registered") ----------
timeline = None
active, not_registered = [], []
for r in reviewers:
    reg = r.get("registeredAt") or r.get("created_at")
    if reg is None:
        if timeline is None:
            for attempt in range(3):
                timeline = gh_timeline()
                if timeline is not None: break
                print("timeline fetch failed (%d/3)" % (attempt + 1)); sleep(min(FIRST, 20))
            if timeline is None:
                result(unavailable([], None, {}, "cold", {"error": "could not read the timeline to resolve registeredAt"}), 3)
        evs = [e for e in timeline if isinstance(e, dict) and e.get("event") == "review_requested" and ((e.get("requested_reviewer") or {}).get("node_id") == r["graphqlBotId"])]
        reg = max((e["created_at"] for e in evs), default=None)
    if reg is None: not_registered.append(r["graphqlBotId"]); continue
    try: regts = parse_ts(reg)
    except Exception as ex:  # noqa: BLE001
        usage("registeredAt for %s: %s" % (r["graphqlBotId"], ex))
    active.append({"id": r["graphqlBotId"], "name": r.get("name", r["graphqlBotId"]), "login": r.get("reviewsLogin"), "registeredAt": regts})
if not active:
    result({"result": "nothing-registered", "elapsedSeconds": 0, "pollCalls": calls["n"], "notRegistered": not_registered}, 3)

# --- cache: advisory, never an error -----------------------------------------------------------
def load_cache():
    try:
        if not os.path.exists(CACHE): return {"version": 1, "reviewers": {}}, "cold"
        loaded = json.load(open(CACHE, encoding="utf-8"))
        assert isinstance(loaded.get("reviewers"), dict)
        return loaded, "warm"
    except Exception:  # noqa: BLE001
        return {"version": 1, "reviewers": {}}, "corrupt"
cache, cache_state = load_cache()
def ring(botid):
    try:
        entry = cache["reviewers"].get(botid) or {}
        return [x for x in entry.get("samples", []) if isinstance(x, dict) and isinstance(x.get("latencySeconds"), (int, float)) and not isinstance(x.get("latencySeconds"), bool)]
    except Exception:  # noqa: BLE001
        return None
def p95(samples):
    s = sorted(samples); return s[max(0, math.ceil(0.95 * len(s)) - 1)]
for a in active:
    samples = ring(a["id"])
    if samples is None: cache_state = "corrupt"; samples = []
    lat = [x["latencySeconds"] for x in samples]
    if FIXED: a["bound"], a["source"], a["p95"], a["n"] = TIMEOUT, "fixed", None, len(lat)
    elif cache_state != "warm" or len(lat) < MINS: a["bound"], a["source"], a["p95"], a["n"] = TIMEOUT, "pollTimeoutMinutes", None, len(lat)
    else: a["p95"], a["n"] = p95(lat), len(lat); a["bound"], a["source"] = min(max(a["p95"] + SLACK, WINDOW), TIMEOUT), "learned-p95"

# --- high-water mark ------------------------------------------------------------------------
pending, interval0 = None, FIRST
if SINCE is not None:
    since = SINCE
    sleep(max(1.0, min(FIRST, min(a["bound"] - (now() - a["registeredAt"]) for a in active))))
    interval0 = FIRST * 1.5
else:
    first = None
    for attempt in range(3):
        first = gh_reviews()
        if first is not None: break
        print("baseline fetch failed (%d/3)" % (attempt + 1)); sleep(min(FIRST, 20))
    if first is None:
        result(unavailable(active, None, {}, cache_state, {"error": "could not establish the review-id high-water mark"}), 3)
    since = max([x.get("id", 0) for x in first if isinstance(x.get("id"), int)] + [0])
    pending = first

# --- the loop ---------------------------------------------------------------------------------
responded, expired, failures, tick, interval, outage = {}, {}, 0, 0, interval0, False
def matches(review, a):
    u = review.get("user") or {}
    return u.get("node_id") == a["id"] or (a["login"] and u.get("login") == a["login"])
while True:
    reviews = pending if pending is not None else gh_reviews(); pending = None
    tick += 1
    if reviews is None:
        failures += 1
        print("tick %d +%ds: gh unavailable (%d consecutive)" % (tick, int(now() - t0), failures))
        if failures >= 3: outage = True; break
    else:
        failures = 0
        for a in active:
            if a["id"] in responded: continue
            mine = [x for x in reviews if isinstance(x.get("id"), int) and x["id"] > since and matches(x, a) and x.get("submitted_at")]
            mine = [x for x in mine if parse_ts(x["submitted_at"]) >= a["registeredAt"]]  # a review posted before the request cannot answer it
            if mine:
                x = min(mine, key=lambda x: x["id"])
                responded[a["id"]] = {"graphqlBotId": a["id"], "reviewId": x["id"], "submittedAt": x["submitted_at"], "latencySeconds": int(round(parse_ts(x["submitted_at"]) - a["registeredAt"]))}
                if a["id"] in expired: expired[a["id"]]["respondedLate"] = {"reviewId": x["id"], "latencySeconds": responded[a["id"]]["latencySeconds"]}
        # A reviewer is frozen as a non-responder only on a tick that actually LOOKED and found nothing past its bound.
        for a in active:
            if a["id"] not in responded and a["id"] not in expired and now() - a["registeredAt"] >= a["bound"]:
                expired[a["id"]] = {"graphqlBotId": a["id"], "name": a["name"], "waitedSeconds": int(now() - a["registeredAt"]), "boundSeconds": int(a["bound"]), "boundSource": a["source"]}
    waiting = [a for a in active if a["id"] not in responded and a["id"] not in expired]
    print("tick %d +%ds: " % (tick, int(now() - t0)) + (" | ".join(
        "%s waiting (bound %ds, %s%s)" % (a["id"], a["bound"], a["source"], (" p95 %ds n=%d" % (a["p95"], a["n"])) if a["p95"] is not None else "") for a in waiting)
        or ("all posted" if not expired else "every remaining reviewer is past its bound")))
    if not waiting: break
    remaining = min(a["bound"] - (now() - a["registeredAt"]) for a in waiting)
    sleep(max(1.0, min(interval, remaining)) if remaining > 0 else 1.0)
    interval = min(interval * 1.5, MAXT)

# --- learn, from server timestamps only; merge under a lock so two runs do not lose a sample ---
rejected, new_samples = [], {}
for a in active:
    r = responded.get(a["id"])
    if not r: continue
    if r["latencySeconds"] < 0 or r["latencySeconds"] > 86400:
        rejected.append({"graphqlBotId": a["id"], "latencySeconds": r["latencySeconds"]}); print("rejected sample %s: %ds is outside [0, 86400]" % (a["id"], r["latencySeconds"])); continue
    new_samples[a["id"]] = {"at": iso(now()), "latencySeconds": r["latencySeconds"], "repo": REPO, "pr": int(PR) if str(PR).isdigit() else PR, "reviewId": r["reviewId"]}
if new_samples:
    lock = CACHE + ".lock"; got = False
    try:
        os.makedirs(os.path.dirname(CACHE), exist_ok=True)
        for _ in range(50):
            try: os.close(os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)); got = True; break
            except FileExistsError: time.sleep(0.1)
        latest, _state = load_cache()  # re-read under the lock: another run may have written since we started
        for botid, sample in new_samples.items():
            entry = latest["reviewers"].setdefault(botid, {"samples": []})
            existing = [x for x in (entry.get("samples") or []) if isinstance(x, dict)]
            if any(x.get("reviewId") == sample["reviewId"] and x.get("repo") == REPO and x.get("pr") == sample["pr"] for x in existing): continue
            entry["samples"] = (existing + [sample])[-20:]; entry["updatedAt"] = iso(now())
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(CACHE), prefix=".reviewer-latency.")
        with os.fdopen(fd, "w", encoding="utf-8") as f: json.dump(latest, f, indent=1); f.write("\n")
        os.replace(tmp, CACHE)
    except Exception:  # noqa: BLE001
        cache_state = "unwritable"
    finally:
        if got:
            try: os.remove(lock)
            except OSError: pass

non = list(expired.values()) + [{"graphqlBotId": a["id"], "name": a["name"], "waitedSeconds": int(now() - a["registeredAt"]), "boundSeconds": int(a["bound"]), "boundSource": "gh-unavailable" if outage else a["source"]} for a in active if a["id"] not in responded and a["id"] not in expired]
if outage: res = "gh-unavailable"
elif not non: res = "all-posted"
elif any(x["boundSource"] in ("pollTimeoutMinutes", "fixed") for x in non): res = "timeout"   # the wait ran to the full bound for someone
else: res = "proceed-p95"                                                                       # every non-responder was cut short by a learned bound
result({"result": res, "elapsedSeconds": int(now() - t0), "pollCalls": calls["n"], "sinceReviewId": since,
        "responded": list(responded.values()), "nonResponders": non, "notRegistered": not_registered,
        "rejectedSamples": rejected, "cacheState": cache_state}, 0 if res == "all-posted" else 3)
PY
exit $?
