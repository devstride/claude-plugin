#!/usr/bin/env python3
"""When will landed work be live? Honest estimates: a range from measured history, never a promise.

The rules are in `skills/release/references/estimates.md`. No clock time is quoted before work has
landed; after it lands, this script turns the repository's own recent history into a range with a
confidence, and later scores the quote against when the work really went live. It reads git only:
it writes nothing, posts nothing and starts nothing. The caller posts its `token` line on the item.

  quote --sha SHA [--now ISO] [--json]
      QUOTE <line>      a range: live between LOW and HIGH, 8 in 10 chance                   exit 0
      NONE <reason>     no clock time: not landed, or too little history to give a range     exit 10
      LIVE <line>       already on the production branch (live after the deploy)             exit 11
      ERROR <reason>                                                                          exit 1
  score --sha SHA --low ISO --high ISO --quoted ISO [--live ISO] [--json]
      SCORED <line>     inside, early or late, and by how many minutes                       exit 0
      PENDING <reason>  not on the production branch yet and no --live given                 exit 10
      ERROR <reason>                                                                          exit 1
  backtest [--days N] [--now ISO] [--json]
      BACKTEST <line>   every landing of the last N days (default 14) that went live, quoted 5
                        minutes after landing from the history as it stood then, and scored: how
                        many landed inside their range, early, late, and how many got no range  exit 0
  usage                                                                                       exit 2

WHERE WORK LANDS: the release train when one ships (`release.mergeTrainBeforeCut` true and
`releaseTrain.branch`, or the old `supportTrain.branch`), else `release.releaseSource` (default
`develop`). Work has landed when SHA is reachable from origin/<landing branch>; its landing time is
the committer time of the first first-parent commit of that branch containing it (a `--no-ff` or
pull-request merge, stamped when it landed). A landing branch that IS `release.productionBranch`
means a merge is the release: the quote is LIVE. An epic integration branch is never a landing
branch: an epic's work lands when its release pull request merges.

HISTORY: every landing on the landing branch in the last 14 days (first-parent commits, leaving out
sync merges: merges whose other parents are all first-parent commits of the release source or the
production branch), each with the time the first first-parent commit of origin/<production> that
contains it was made, if any. A landing not on production yet is still waiting: it counts as
"at least this long" (censored), so slow work is never dropped from the history. The wait from
landing to the production merge is estimated with the Kaplan-Meier method, CONDITIONAL on the time
this landing has already waited: the range runs from the 10th to the 90th percentile of the
remaining wait, so 8 in 10 quotes should land inside it. Both ends add
`release.estimates.deployMinutes` (default 0), the time from the production merge to live. Fewer
than 8 landings that waited at least as long as this one, or a history whose 90th percentile is
never reached (too many still waiting), gives NONE: too little history for an honest range.

The range is everything after landing measured together (the wait for the next release to start,
the train's tests and their failures, the release steps, the golden route, the owner's go-ahead),
because each is in the history. Times are shown in `release.holdTimeZone` (an IANA name; absent:
UTC) and stored in UTC.

The token is the record: quote → `[estimate v1 sha=<12> quoted=<UTC> low=<UTC> high=<UTC> p=80
n=<N>]`; score → `[estimate-score v1 sha=<12> quoted=… low=… high=… live=<UTC>
result=inside|early|late minutes=<N>]` (minutes outside the range; 0 inside). `score` takes LIVE as
--live (the deploy confirmed) or, without it, the production merge time plus deployMinutes.

Test seams: AUTO_START_NO_FETCH=1 (read the remote-tracking refs as they are), --now.
"""
import argparse
import datetime
import importlib.util
import json
import math
import os
import subprocess
import sys
import zoneinfo

HERE = os.path.dirname(os.path.abspath(__file__))
UTC = datetime.timezone.utc
WINDOW_DAYS = 14
MIN_AT_RISK = 8
LOW_Q, HIGH_Q = 0.10, 0.90
EXIT = {"QUOTE": 0, "SCORED": 0, "BACKTEST": 0, "NONE": 10, "PENDING": 10, "LIVE": 11, "ERROR": 1}


class Answer(Exception):
    def __init__(self, verdict, line, **record):
        Exception.__init__(self, line)
        self.verdict, self.line, self.record = verdict, line, record


def load_auto_start():
    """auto-start.py's load_config and section: one way to find the config, reused."""
    spec = importlib.util.spec_from_file_location("auto_start", os.path.join(HERE, "auto-start.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def parse_time(text, name):
    try:
        when = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        raise Answer("ERROR", "%s must be an ISO date-time with its offset: %r" % (name, text))
    if when.tzinfo is None:
        raise Answer("ERROR", "%s must carry its offset: %r" % (name, text))
    return when.astimezone(UTC)


def utc(when):
    return when.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def git(root, *args, check=True):
    done = subprocess.run(["git", "-C", root] + list(args), capture_output=True, text=True, stdin=subprocess.DEVNULL)
    if check and done.returncode != 0:
        raise Answer("ERROR", "git %s failed: %s" % (args[0], (done.stderr or "").strip()[:200]))
    return done


def settings(config, section):
    """-> (landing branch, release source, production branch, deploy minutes, zone)."""
    release = section(config, "release")
    if isinstance(config.get("releaseTrain"), dict) and isinstance(config.get("supportTrain"), dict):
        raise Answer("ERROR", "both releaseTrain and supportTrain are set; supportTrain is the old name of releaseTrain")
    train = (section(config, "releaseTrain") or section(config, "supportTrain")).get("branch")
    source = release.get("releaseSource") or "develop"
    production = release.get("productionBranch") or "master"
    ships = release.get("mergeTrainBeforeCut") is True and isinstance(train, str) and train
    landing = train if ships else source
    deploy = section(release, "estimates").get("deployMinutes", 0)
    if isinstance(deploy, bool) or not isinstance(deploy, int) or deploy < 0:
        raise Answer("ERROR", "release.estimates.deployMinutes must be a whole number of minutes, 0 or more")
    name = release.get("holdTimeZone") or "UTC"
    try:
        zone = zoneinfo.ZoneInfo(name)
    except (zoneinfo.ZoneInfoNotFoundError, ValueError, TypeError):
        raise Answer("ERROR", "release.holdTimeZone is not an IANA time zone: %r" % (name,))
    return landing, source, production, deploy, zone


def fetch(root, branches):
    if os.environ.get("AUTO_START_NO_FETCH") == "1":
        return
    specs = ["+refs/heads/%s:refs/remotes/origin/%s" % (b, b) for b in sorted(set(branches))]
    done = git(root, "fetch", "-q", "origin", *specs, check=False)
    if done.returncode != 0:
        raise Answer("ERROR", "git fetch of %s failed: %s" % (", ".join(sorted(set(branches))), (done.stderr or "").strip()[:200]))


def rows(root, *revs, since=None):
    """-> [(sha, committed epoch, [parents])] of the first-parent walk of revs, oldest first."""
    args = ["log", "--first-parent", "--reverse", "--format=%H %ct %P"]
    if since is not None:
        args.append("--since=@%d" % since)
    found = []
    for line in git(root, *(args + list(revs) + ["--"])).stdout.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            found.append((parts[0], int(parts[1]), parts[2:]))
    return found


def first_parent(root, branch, since=None):
    return rows(root, "origin/%s" % branch, since=since)


def ancestor(root, sha, branch):
    return git(root, "merge-base", "--is-ancestor", sha, "origin/%s" % branch, check=False).returncode == 0


def landed_at(root, sha, chain):
    """The first of `chain` (first-parent commits, oldest first) that contains sha, found by
    bisection: along a first-parent chain, once a commit contains sha every later one does."""
    lo, hi = 0, len(chain)
    while lo < hi:
        mid = (lo + hi) // 2
        if git(root, "merge-base", "--is-ancestor", sha, chain[mid][0], check=False).returncode == 0:
            hi = mid
        else:
            lo = mid + 1
    return chain[lo] if lo < len(chain) else None


def brought(root, merge):
    """The landings a first-parent commit of the release source brought. A train delivery (its
    second parent's first-parent walk back to its first parent holds nothing but merges: the
    train's landings and syncs) brings that walk; any other commit, a pull request merged straight
    into the source included, is itself the landing."""
    if len(merge[2]) < 2:
        return [merge]
    walk = rows(root, merge[2][1], "--not", merge[2][0])
    if walk and all(len(row[2]) >= 2 for row in walk):
        return walk
    return [merge]


def landing_of(root, sha, landing, source):
    """When sha landed: the first first-parent commit of the landing branch containing it. A train
    is fast-forwarded or merged into the source at each release, so once sha is on the source it is
    found through the source merge that brought it, never on the train's walk as it stands now."""
    if landing == source:
        return landed_at(root, sha, first_parent(root, source))
    if ancestor(root, sha, source):
        merge = landed_at(root, sha, first_parent(root, source))
        return landed_at(root, sha, brought(root, merge)) or merge
    return landed_at(root, sha, rows(root, "origin/%s" % landing, "--not", "origin/%s" % source))


def shipped_times(root, production, since):
    """-> {sha: epoch} for every commit a first-parent commit of origin/<production> made since
    `since` brought in, at that commit's committer time."""
    times = {}
    for sha, when, parents in first_parent(root, production, since):
        if parents:
            new = git(root, "rev-list", "%s..%s" % (parents[0], sha)).stdout.split()
        else:
            new = git(root, "rev-list", sha).stdout.split()
        for commit in new:
            times.setdefault(commit, when)
    return times


def table(root, landing, source, production, start):
    """-> [(sha, landed epoch, shipped epoch or None)] for every landing since `start`, sync merges
    left out. Landings on a train are read through the source merges that brought them (the train's
    own walk loses them when it is fast-forwarded), plus those still on the train beyond the
    source. `shipped` is when the first production first-parent commit containing it was made."""
    upstream = {sha for branch in {source, production} if branch != landing
                for sha, _, _ in first_parent(root, branch, start - 30 * 86400)}
    if landing == source:
        candidates = first_parent(root, source, start)
    else:
        candidates = [row for merge in first_parent(root, source, start) for row in brought(root, merge)]
        candidates += rows(root, "origin/%s" % landing, "--not", "origin/%s" % source)
    shipped = shipped_times(root, production, start)
    found, seen = [], set()
    for sha, when, parents in candidates:
        if sha in seen or when < start:
            continue
        seen.add(sha)
        others = parents[1:]
        if others and all(p in upstream for p in others):
            continue   # a sync merge carries nothing
        found.append((sha, when, shipped.get(sha)))
    return found


def samples_at(landings, now, skip=None):
    """-> [(minutes, shipped?)] as the history stood at `now`: the window's landings made by then,
    each shipped only if it reached production by then, else still waiting (at least this long)."""
    moment, start = now.timestamp(), now.timestamp() - WINDOW_DAYS * 86400
    found = []
    for sha, landed, shipped in landings:
        if sha == skip or not start <= landed <= moment:
            continue
        if shipped is not None and shipped <= moment:
            found.append((max(0.0, (shipped - landed) / 60.0), True))
        else:
            found.append((max(0.0, (moment - landed) / 60.0), False))
    return found


def remaining_range(samples, waited):
    """Kaplan-Meier over (minutes, shipped?) conditional on having waited `waited` minutes: ->
    (at risk, low minutes from now, high minutes from now), the 10th and 90th percentiles of the rest
    of the wait; None for an end the history never reaches."""
    at_risk = [s for s in samples if s[0] >= waited]
    events = sorted({t for t, shipped in at_risk if shipped})
    survival, low, high = 1.0, None, None
    for t in events:
        risk = sum(1 for s in at_risk if s[0] >= t)
        died = sum(1 for s in at_risk if s[0] == t and s[1])
        if risk:
            survival *= 1 - died / risk
        done = 1 - survival
        if low is None and done >= LOW_Q - 1e-9:
            low = t - waited
        if high is None and done >= HIGH_Q - 1e-9:
            high = t - waited
    return len(at_risk), low, high


def shown(when, zone, now):
    local = when.astimezone(zone)
    clock = local.strftime("%I:%M %p").lstrip("0")
    if local.date() != now.astimezone(zone).date():
        clock = local.strftime("%a %b ") + str(local.day) + " " + clock
    return "%s %s" % (clock, local.tzname())


def floor5(when):
    return when - datetime.timedelta(minutes=when.minute % 5, seconds=when.second, microseconds=when.microsecond)


def ceil5(when):
    down = floor5(when)
    return down if down == when else down + datetime.timedelta(minutes=5)


def setup():
    auto = load_auto_start()
    config, root = auto.load_config()
    landing, source, production, deploy, zone = settings(config, auto.section)
    fetch(root, [landing, source, production])
    return root, landing, source, production, deploy, zone


def resolve(root, name):
    sha = git(root, "rev-parse", "--verify", "--quiet", name + "^{commit}", check=False).stdout.strip()
    if not sha:
        raise Answer("ERROR", "no commit %r here (fetch it first)" % name)
    return sha


def quote_range(landings, sha, landed, now, deploy):
    """-> (record, low, high) for work that landed at `landed`, quoted at `now`; raises NONE."""
    waited = max(0.0, (now - landed).total_seconds() / 60.0)
    samples = samples_at(landings, now, sha)
    at_risk, low, high = remaining_range(samples, waited)
    record = {"landedAt": utc(landed), "waitedMinutes": int(waited), "landings": len(samples),
              "shipped": sum(1 for _, done in samples if done), "atRisk": at_risk}
    if at_risk < MIN_AT_RISK:
        raise Answer("NONE", "too little history for an honest range: %d landing(s) in the last %d days waited "
                     "at least as long as this one (%d needed)" % (at_risk, WINDOW_DAYS, MIN_AT_RISK), **record)
    if low is None or high is None:
        raise Answer("NONE", "too little history for an honest range: too many of the last %d days' landings are "
                     "still waiting to say when 9 in 10 go live" % WINDOW_DAYS, **record)
    lo = floor5(now + datetime.timedelta(minutes=low + deploy))
    hi = ceil5(now + datetime.timedelta(minutes=high + deploy))
    return record, lo, hi


def quote(args):
    now = parse_time(args.now, "--now") if args.now else datetime.datetime.now(UTC)
    root, landing, source, production, deploy, zone = setup()
    sha = resolve(root, args.sha)
    record = {"sha": sha, "landingBranch": landing, "production": production, "now": utc(now),
              "deployMinutes": deploy}
    on = landed_at(root, sha, first_parent(root, production)) if ancestor(root, sha, production) else None
    if on is not None and on[1] <= now.timestamp():
        merged = datetime.datetime.fromtimestamp(on[1], UTC)
        raise Answer("LIVE", "already on %s since %s; live after the deploy%s" % (
            production, shown(merged, zone, now), " (about %d minutes)" % deploy if deploy else ""),
            live=utc(merged + datetime.timedelta(minutes=deploy)), **record)
    at = landing_of(root, sha, landing, source) if ancestor(root, sha, landing) else None
    if at is None or at[1] > now.timestamp():
        raise Answer("NONE", "not landed on %s yet: no clock time before landing; say which steps remain" % landing, **record)
    record["landing"] = at[0]
    landings = table(root, landing, source, production, int(now.timestamp()) - WINDOW_DAYS * 86400)
    try:
        found, lo, hi = quote_range(landings, at[0], datetime.datetime.fromtimestamp(at[1], UTC), now, deploy)
    except Answer as answer:
        answer.record.update(record)
        raise
    record.update(found)
    token = "[estimate v1 sha=%s quoted=%s low=%s high=%s p=80 n=%d]" % (sha[:12], utc(now), utc(lo), utc(hi), found["atRisk"])
    line = "live between %s and %s (8 in 10 chance), from %d landings in the last %d days" % (
        shown(lo, zone, now), shown(hi, zone, now), found["atRisk"], WINDOW_DAYS)
    raise Answer("QUOTE", line, low=utc(lo), high=utc(hi), confidence=0.8, token=token, **record)


def backtest(args):
    """Replay: every landing of the last --days that reached production, quoted 5 minutes after it
    landed from the history as it stood then, and scored against when it really went live."""
    now = parse_time(args.now, "--now") if args.now else datetime.datetime.now(UTC)
    root, landing, source, production, deploy, zone = setup()
    start = int(now.timestamp()) - args.days * 86400
    landings = table(root, landing, source, production, start - WINDOW_DAYS * 86400)
    counts = {"inside": 0, "early": 0, "late": 0, "none": 0, "pending": 0}
    worst = 0
    for sha, landed, shipped in landings:
        if landed < start:
            continue
        if shipped is None:
            counts["pending"] += 1
            continue
        at = datetime.datetime.fromtimestamp(landed, UTC) + datetime.timedelta(minutes=5)
        if shipped <= at.timestamp():
            continue   # live before any quote
        try:
            _, lo, hi = quote_range(landings, sha, datetime.datetime.fromtimestamp(landed, UTC), at, deploy)
        except Answer:
            counts["none"] += 1
            continue
        live = datetime.datetime.fromtimestamp(shipped, UTC) + datetime.timedelta(minutes=deploy)
        if live < lo:
            counts["early"] += 1
        elif live > hi:
            counts["late"] += 1
            worst = max(worst, int((live - hi).total_seconds() // 60))
        else:
            counts["inside"] += 1
    scored = counts["inside"] + counts["early"] + counts["late"]
    share = int(round(100.0 * counts["inside"] / scored)) if scored else 0
    line = "%d quoted: %d inside (%d%%), %d early, %d late (worst %d minutes); %d without a range, %d not live yet" % (
        scored, counts["inside"], share, counts["early"], counts["late"], worst, counts["none"], counts["pending"])
    raise Answer("BACKTEST", line, insidePercent=share, worstLateMinutes=worst, days=args.days, **counts)


def score(args):
    low, high = parse_time(args.low, "--low"), parse_time(args.high, "--high")
    quoted = parse_time(args.quoted, "--quoted")
    if high < low:
        raise Answer("ERROR", "--high is before --low")
    root, landing, source, production, deploy, zone = setup()
    sha = resolve(root, args.sha)
    record = {"sha": sha, "quoted": utc(quoted), "low": utc(low), "high": utc(high)}
    if args.live:
        live = parse_time(args.live, "--live")
    elif ancestor(root, sha, production):
        at = landed_at(root, sha, first_parent(root, production))
        live = datetime.datetime.fromtimestamp(at[1], UTC) + datetime.timedelta(minutes=deploy)
    else:
        raise Answer("PENDING", "not on %s yet: score it once the deploy is confirmed" % production, **record)
    if live < low:
        result, minutes = "early", int(math.ceil((low - live).total_seconds() / 60))
    elif live > high:
        result, minutes = "late", int(math.ceil((live - high).total_seconds() / 60))
    else:
        result, minutes = "inside", 0
    token = "[estimate-score v1 sha=%s quoted=%s low=%s high=%s live=%s result=%s minutes=%d]" % (
        sha[:12], utc(quoted), utc(low), utc(high), utc(live), result, minutes)
    said = "inside the range" if result == "inside" else "%s by %d minutes" % (result, minutes)
    line = "live at %s; the quote of %s was %s to %s: %s" % (
        shown(live, zone, live), shown(quoted, zone, live), shown(low, zone, live), shown(high, zone, live), said)
    raise Answer("SCORED", line, live=utc(live), result=result, minutes=minutes, token=token, **record)


class Parser(argparse.ArgumentParser):
    def error(self, message):   # usage goes to stdout, below, never argparse's stderr
        raise SystemExit(2)


def main(argv):
    parser = Parser(prog="estimate.py", add_help=False)
    sub = parser.add_subparsers(dest="command", parser_class=Parser)
    q = sub.add_parser("quote", add_help=False)
    q.add_argument("--sha", required=True)
    q.add_argument("--now")
    q.add_argument("--json", action="store_true")
    s = sub.add_parser("score", add_help=False)
    for name in ("--sha", "--low", "--high", "--quoted"):
        s.add_argument(name, required=True)
    s.add_argument("--live")
    s.add_argument("--json", action="store_true")
    b = sub.add_parser("backtest", add_help=False)
    b.add_argument("--days", type=int, default=WINDOW_DAYS)
    b.add_argument("--now")
    b.add_argument("--json", action="store_true")
    try:
        args = parser.parse_args(argv)
    except SystemExit:
        print(__doc__.strip().split("\n\n")[1])
        return 2
    if args.command not in ("quote", "score", "backtest") or getattr(args, "days", 1) < 1:
        print(__doc__.strip().split("\n\n")[1])
        return 2
    try:
        {"quote": quote, "score": score, "backtest": backtest}[args.command](args)
    except Answer as answer:
        if args.json:
            print(json.dumps(dict(answer.record, verdict=answer.verdict, line=answer.line), sort_keys=True))
        else:
            print("%s %s" % (answer.verdict, answer.line))
            if answer.record.get("token"):
                print(answer.record["token"])
        return EXIT[answer.verdict]
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
