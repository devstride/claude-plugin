#!/usr/bin/env python3
"""Has landed work waited too long for a release? The release backstop: `release.backstop`.

The rules are in `skills/release/references/backstop.md`. Releases still start whenever work is
ready (`release.autoStart`, or by hand); this check, run on a schedule (every few minutes by a
dispatcher, or `/devstride:release backstop` by hand), starts one ONLY when work on the release
train has waited longer than `maxWaitMinutes` and nothing is releasing it. It claims nothing,
starts nothing and writes nothing: a START or SHADOW goes on to claim the backstop key, and that
claim, not this check, decides which machine acts. Its `--json` answer is the record the caller
stores with that claim, and carries the exact claim to make (`claim`, `trainClaim`).

  due [--now ISO] [--json] [--holds FILE] [--recheck KEY]
      START <key> (<why>)                live: claim <key>, the train claim, recheck, release exit 0
      SHADOW <key> would start (<why>)   shadow: claim <key>, record, start nothing             exit 10
      SKIP <reason>                      nothing to do now, and why                             exit 11
      OFF <reason>                       no release.backstop block, or its mode is off          exit 12
      HOLDS <I#> [<I#>...]               read these items and their ancestors; run again        exit 13
      ERROR <reason>                     a bad config, an unreadable train or holds request     exit 1
    SKIP covers: not waiting long enough, nothing waiting, a release in progress, held, clearance
    or release pull requests unreadable, no release train, no claims block, and under --recheck
    any answer other than the same START or SHADOW for KEY ("changed since the claim"). HOLDS: the
    release delta names these items; write release-holds.py's request for each and its ancestors
    and run `due` again with --holds <file>.
  decide   (stdin {"stage": "before"|"after", "response": <get_claim | claim_work answer>, "now"?,
            "before"?: <the before stage's action, on the after stage>})
      {"action": "claim"|"takeover"|"skip"|"proceed"|"degrade", "message", "takeoverDigest"?}  exit 0
      before: a live claim held by anyone, this session too, is skip (never renewed or extended);
      a lapsed one is takeover; none, or one released not final, is claim. after: won is proceed
      (a renewal too when "before" was takeover: this holder taking back its own lapsed claim),
      unless it renewed a claim the read did not show lapsed; lost is skip.
  config
      OK, or one `ERROR|WARN <path>: <message>` line per finding; exit 1 on an ERROR.
      skills/doctor/scripts/validate-config.py reports the same findings (it imports `problems`).
  usage                                                                                    exit 2

WAITING WORK is every LANDING on the train not yet on the release source: each first-parent commit
in origin/<source>..origin/<train>, except a merge whose other parents are all already on the source
(a sync merge, which carries nothing). Work lands on the train as a `--no-ff` merge or a pull
request merge, so a landing's committer time is the moment it landed; it is read from git, so every
machine computes the same wait. The OLDEST landing is the one with the SMALLEST committer time (the
earlier in first-parent order on a tie), whatever its position, so a merge stamped by a skewed
clock still counts from its stamp. Its committer time is when the wait began, and its SHA keys the
claim: `<owner>/<repo>@<sha>` (kind `release-train`; `:shadow` appended in shadow mode so shadow
records never consume a live key). Every check while that work waits computes the same key, so
concurrent checks dedupe; once that landing ships, the key moves to the next oldest.

START or SHADOW only when ALL hold: the mode is live or shadow, a `claims` block is configured, the
train holds work beyond the source (auto-start.py's `train_state`, one rule, reused), the oldest
landing waited MORE than `maxWaitMinutes` (default 120), no release is in progress, and no release
hold holds the release delta. Under `release.clearance.scope` `cut-to-deploy` or `merge-and-deploy`
nothing below is read: a release there holds the tower only from its cut (or only for its merge and
deploy) and hands the train claim on at the cut (or once its pull request is open), so an open
release pull request or a held tower is a release that has already left this waiting work behind, and the train claim the caller takes next alone decides. Otherwise a
release is in progress when `gh pr list --repo HOST/OWNER/REPO`
(all three read from the raw origin URL: an enterprise origin is listed on its own host, and an
origin with no host to read is a SKIP) shows an open pull request
into the production branch headed by the release source or a `release.releaseBranchPattern` branch
(the branch-patterns rule, clearance_core.py's `pattern_regex`), always, with or without clearance;
and, with `release.clearance` set, when its provider's `status --json` is anything but `clear` with
`derived` true and no release pull request on final. Unreadable is never clear: a failed or
truncated list, or a status that is unknown or not derived, is a release in progress. A release that
holds the train claim is found by the caller's own claim of it (claim_work decides; a list never
does). The holds are release-holds.py's (the single implementation; its exit 2 is held) over every
item the release itself would check: the commits on origin/<train> or origin/<source> that are not
on origin/<production>, after fetching all three.

`--recheck KEY` is the check the caller repeats once it holds the train claim: the same START (or
SHADOW) for KEY, else SKIP "changed since the claim: …". `--now` replaces the clock (an ISO time with
its offset). Test seams are auto-start.py's: AUTO_START_REPO (owner/name) and AUTO_START_NO_FETCH=1.
Network: `git ls-remote`/`git fetch`, `gh pr list`, and the clearance provider's `status`.
"""
import contextlib
import datetime
import importlib.util
import io
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
AUTO_START = os.path.join(HERE, "auto-start.py")
CLEARANCE_CORE = os.path.join(HERE, "clearance_core.py")
HOLDS = os.path.join(os.path.dirname(os.path.dirname(HERE)), "build-item/scripts/release-holds.py")
MODES = ("off", "shadow", "live")
DEFAULT_WAIT, MIN_WAIT, MAX_WAIT = 120, 15, 1440   # a claim lives at most a day
PR_LIMIT = 200   # a list this long is truncated, never trusted
ITEM = re.compile(r"(?<![0-9A-Za-z])I\d{2,}(?![0-9A-Za-z])")
UTC = datetime.timezone.utc
GATED_SCOPES = ("cut-to-deploy", "merge-and-deploy")   # release.clearance.scope values that hand the train claim on before the merge
EXIT = {"START": 0, "SHADOW": 10, "SKIP": 11, "OFF": 12, "HOLDS": 13, "ERROR": 1}


class Answer(Exception):
    def __init__(self, verdict, line, **record):
        Exception.__init__(self, line)
        self.verdict, self.line, self.record = verdict, line, record


def load(name, path):
    """auto-start.py (config, train check, repository key) and clearance_core.py (the branch-patterns
    rule) are reused, never copied."""
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def section(value, key):
    found = value.get(key) if isinstance(value, dict) else None
    return found if isinstance(found, dict) else {}


def whole(value):
    """A whole number of minutes: an int, or a float with no fraction (JSON's 120.0 is 120)."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, float) and value.is_integer():
        return int(value)
    return None


def problems(config):
    """What the schema cannot say about release.backstop, as (severity, path, message) tuples. The
    schema already errs on a wrong type, a mode outside the enum and a wait under 15 minutes."""
    release = section(config, "release")
    block = release.get("backstop")
    if not isinstance(block, dict) or block.get("mode", "off") not in ("shadow", "live"):
        return []
    found = []
    if not isinstance(config.get("claims"), dict):
        found.append(("ERROR", "release.backstop.mode", "needs a `claims` block: without a one-winner "
                      "backstop claim two machines could start a release for the same waiting work"))
    elif isinstance(config["claims"].get("commands"), dict) and not config["claims"]["commands"].get("get"):
        found.append(("ERROR", "release.backstop.mode", "needs `claims.commands.get`: a live backstop claim is "
                      "read before claiming, so a check never renews or extends one"))
    train = section(config, "releaseTrain").get("branch") or section(config, "supportTrain").get("branch")
    if release.get("mergeTrainBeforeCut") is not True or not train:
        found.append(("WARN", "release.backstop.mode", "has no effect without a release train "
                      "(release.mergeTrainBeforeCut and releaseTrain.branch): no work ever waits on one"))
    return found


def settings(config):
    """-> (mode, maxWaitMinutes); raises OFF or ERROR."""
    block = section(config, "release").get("backstop")
    if block is None:
        raise Answer("OFF", "release.backstop is not configured", mode="off")
    if not isinstance(block, dict):
        raise Answer("ERROR", "release.backstop must be an object")
    mode = block.get("mode", "off")
    if mode not in MODES:
        raise Answer("ERROR", "release.backstop.mode must be off, shadow or live, not %r" % (mode,))
    wait = whole(block.get("maxWaitMinutes", DEFAULT_WAIT))
    if wait is None or not MIN_WAIT <= wait <= MAX_WAIT:
        raise Answer("ERROR", "release.backstop.maxWaitMinutes must be a whole number of minutes from %d to %d"
                     % (MIN_WAIT, MAX_WAIT))
    if mode == "off":
        raise Answer("OFF", "release.backstop.mode is off", mode="off")
    return mode, wait


def parse_now(text):
    if text is None:
        return datetime.datetime.now(UTC)
    try:
        now = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        raise Answer("ERROR", "--now must be an ISO date-time with its offset: %r" % text)
    if now.tzinfo is None:
        raise Answer("ERROR", "--now must carry its offset: %r" % text)
    return now.astimezone(UTC)


def run(argv, root, **extra):
    return subprocess.run(argv, cwd=root, capture_output=True, text=True, stdin=subprocess.DEVNULL, **extra)


def git(root, *args):
    done = run(["git", "-C", root] + list(args), root)
    if done.returncode != 0:
        raise Answer("ERROR", "git %s failed: %s" % (args[0], (done.stderr or "").strip()[:200]))
    return done.stdout


def fetch_production(root, production):
    if os.environ.get("AUTO_START_NO_FETCH") == "1":
        return
    done = run(["git", "-C", root, "fetch", "-q", "origin",
                "+refs/heads/%s:refs/remotes/origin/%s" % (production, production)], root)
    if done.returncode != 0:
        raise Answer("ERROR", "git fetch of %s failed: %s" % (production, (done.stderr or "").strip()[:200]))


def landings(root, train, source):
    """-> [(sha, committed epoch)] in first-parent order, newest first: the first-parent commits
    beyond the source, sync merges (every other parent already on the source) left out."""
    found = []
    for row in git(root, "log", "--first-parent", "--format=%H %ct %P", "origin/%s..origin/%s" % (source, train)).splitlines():
        parts = row.split()
        if len(parts) < 3:
            continue
        sha, when, parents = parts[0], int(parts[1]), parts[2:]
        others = parents[1:]
        if others and all(run(["git", "-C", root, "merge-base", "--is-ancestor", p, "origin/%s" % source], root).returncode == 0
                          for p in others):
            continue
        found.append((sha, when))
    return found


def oldest_of(landed):
    """The landing with the smallest committer time; on a tie, the earlier in first-parent order."""
    best = None
    for position, (sha, when) in enumerate(landed):   # newest first, so a later index is earlier
        if best is None or when < best[1] or (when == best[1] and position > best[2]):
            best = (sha, when, position)
    return best[0], best[1]


def delta_items(root, train, source, production):
    """Every item number a commit on the train or the source, not on production, names."""
    text = git(root, "log", "--format=%B", "origin/%s" % train, "origin/%s" % source, "--not", "origin/%s" % production)
    return sorted(set(ITEM.findall(text)), key=lambda number: int(number[1:]))


ORIGIN_URL = re.compile(r"^([a-z][a-z0-9+.-]*)://(?:[^@/]+@)?(\[[^\]]+\]|[^:/@\s]+)(?::(\d+))?/", re.I)
ORIGIN_SCP = re.compile(r"^(?:[^@/:]+@)?(\[[^\]]+\]|[^:/@\s]+):(?!/)")


def origin_host(url):
    """-> the host gh should list on, or None. A network URL (scheme://) keeps a non-default
    http(s) port, since gh reaches the API over https; an ssh/git transport port is dropped.
    An scp-style origin (host:path, no slash before the colon) has no port. Anything else,
    including a relative or absolute filesystem path, has no host."""
    found = ORIGIN_URL.match(url)
    if found:
        scheme, host, port = found.group(1).lower(), found.group(2).lower(), found.group(3)
        if scheme in ("http", "https") and port and port != {"http": "80", "https": "443"}[scheme]:
            host = "%s:%s" % (host, port)
        elif scheme not in ("http", "https", "ssh", "git", "git+ssh", "ssh+git"):
            return None
        bare = found.group(2)
    else:
        found = ORIGIN_SCP.match(url)
        if not found:
            return None
        host = bare = found.group(1).lower()
    if "." not in bare and bare.lower() != "localhost":
        return None
    return host


def origin_repo(root, repo):
    """-> HOST/OWNER/REPO for `gh --repo`, the host read from the same raw origin URL as the owner and
    name (ssh, scp-style or http(s); insteadOf never applies), so an enterprise origin is listed on its
    own host, never on github.com. An origin with no host to read raises an Answer."""
    url = run(["git", "-C", root, "config", "--get", "remote.origin.url"], root).stdout.strip()
    host = origin_host(url)
    if not host:
        raise Answer("ERROR", "cannot read the host of the origin remote (%r)" % url)
    return "%s/%s" % (host, repo)


def open_release_prs(root, release, production, source, repo):
    """-> (busy, reason) from `gh pr list`: an open pull request into production headed by the source
    or a release branch is a release in progress. A failed or truncated list is never clear."""
    pattern = release.get("releaseBranchPattern")
    matcher = load("clearance_core", CLEARANCE_CORE).pattern_regex(pattern) if isinstance(pattern, str) and pattern else None
    try:
        done = run(["gh", "pr", "list", "--repo", repo, "--base", production, "--state", "open",
                    "--json", "number,headRefName", "--limit", str(PR_LIMIT)], root, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as error:
        return True, "open release pull requests could not be read (%s)" % error
    try:
        listed = json.loads(done.stdout) if done.returncode == 0 else None
    except ValueError:
        listed = None
    if not isinstance(listed, list):
        return True, "open release pull requests could not be read (%s)" % ((done.stderr or "").strip()[:200] or "exit %d" % done.returncode)
    if len(listed) >= PR_LIMIT:
        return True, "open pull requests into %s could not all be read (%d or more)" % (production, PR_LIMIT)
    for pr in sorted((p for p in listed if isinstance(p, dict)), key=lambda p: p.get("number") or 0):
        head = pr.get("headRefName") or ""
        if head == source or (matcher and matcher.match(head)):
            return True, "a release is in progress: release pull request #%s (%s) is open" % (pr.get("number"), head)
    return False, "no release pull request is open"


def clearance(config, root):
    """-> (busy, reason). No release.clearance → not read. Unreadable or not derived is never clear."""
    block = section(config, "release").get("clearance")
    if not block:
        return False, "no release.clearance configured"
    if not isinstance(block, dict):
        return True, "release.clearance is not an object, so clearance cannot be read"
    commands = section(block, "commands")
    if commands:
        command = commands.get("status")
        if not isinstance(command, str) or not command.strip():
            return True, "release.clearance.commands.status is not set, so clearance cannot be read"
        argv = ["/bin/sh", "-c", command + " --json"]
    elif block.get("provider") in ("github", "devstride"):
        argv = ["bash", os.path.join(HERE, "clearance-%s.sh" % block["provider"]), "status", "--json"]
    else:
        return True, "release.clearance names no provider this check can read"
    try:
        done = run(argv, root, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as error:
        return True, "clearance could not be read (%s)" % error
    try:
        status = json.loads(done.stdout.strip().splitlines()[-1]) if done.stdout.strip() else None
    except ValueError:
        status = None
    if done.returncode != 0 or not isinstance(status, dict) or status.get("state") not in ("clear", "held"):
        why = (status or {}).get("error") if isinstance(status, dict) else (done.stderr or "").strip()[:200]
        return True, "clearance could not be read (%s)" % (why or "exit %d" % done.returncode)
    if status["state"] == "held":
        record = status.get("record") if isinstance(status.get("record"), dict) else {}
        what = record.get("branch") or record.get("purpose") or "a release"
        by = record.get("machine") or record.get("user") or "another session"
        return True, "a release is in progress: clearance is held for %s by %s%s" % (
            what, by, " (stale: the owner decides)" if status.get("stale") else "")
    if status.get("derived") is not True:
        return True, "clearance could not be read (its release pull requests were not derived)"
    final = status.get("onFinal")
    if isinstance(final, dict) and final.get("number"):
        return True, "a release is in progress: release pull request #%s is on final" % final["number"]
    return False, "clearance is clear"


def check_holds(path, items, now, root):
    """-> (held, reason) from release-holds.py over the caller's request, which must cover `items`."""
    try:
        with open(path) as handle:
            request = json.load(handle)
    except (OSError, ValueError) as error:
        raise Answer("ERROR", "the holds request %s cannot be read as JSON (%s)" % (path, error))
    listed = request.get("items") if isinstance(request, dict) else None
    if not isinstance(listed, list) or not listed:
        raise Answer("ERROR", "the holds request needs items: each release item and its ancestors")
    numbers = {entry.get("number") for entry in listed if isinstance(entry, dict)}
    missing = [n for n in items if n not in numbers]
    if missing:
        raise Answer("ERROR", "the holds request leaves out %s: read every release item and its ancestors" % " ".join(missing))
    request.setdefault("now", now.isoformat())
    ran = subprocess.run([sys.executable, HOLDS, "decide"], input=json.dumps(request), capture_output=True,
                         text=True, cwd=root)
    if ran.returncode == 2:   # a hold nobody can read holds
        return True, "held: " + (ran.stderr.strip().splitlines() or ["release-holds refused"])[0]
    if ran.returncode != 0:
        raise Answer("ERROR", "release-holds.py failed: %s" % (ran.stderr or "").strip()[:200])
    try:
        answer = json.loads(ran.stdout)
    except ValueError:
        raise Answer("ERROR", "release-holds.py answered something other than JSON")
    return bool(answer.get("held")), answer.get("reason") or ""


def quiet(function, *args):
    """Run an auto-start.py helper whose failures print an ERROR line and exit: the line becomes this
    check's own Answer, so every failure keeps the documented verdict, exit code and --json shape."""
    printed = io.StringIO()
    try:
        with contextlib.redirect_stdout(printed):
            return function(*args)
    except SystemExit:
        line = printed.getvalue().strip().splitlines()
        raise Answer("ERROR", re.sub(r"^ERROR ", "", line[0]) if line else "auto-start.py stopped")


def due(now_text, holds_path):
    auto = load("auto_start", AUTO_START)
    now = parse_now(now_text)
    config, root = quiet(auto.load_config)
    mode, wait = settings(config)
    record = {"mode": mode, "now": now.isoformat(), "maxWaitMinutes": wait}
    if not isinstance(config.get("claims"), dict):
        raise Answer("SKIP", "release.backstop needs a claims block; without one it does nothing", **record)
    state = quiet(auto.train_state, config, root)
    if state[0] != "AHEAD":
        raise Answer(state[0], state[1], **record)
    _, commits, train, source = state
    release = section(config, "release")
    production = release.get("productionBranch") or "master"
    landed = landings(root, train, source)
    if not landed:
        raise Answer("SKIP", "the train holds nothing beyond %s" % source, **record)
    oldest, since = oldest_of(landed)
    waited = (now - datetime.datetime.fromtimestamp(since, UTC)).total_seconds() / 60
    try:
        repo = quiet(auto.repo_key, root)
        gh_repo = origin_repo(root, repo)
    except Answer as answer:   # no repository to list pull requests in, nor to key the claim by
        raise Answer("SKIP", "open release pull requests cannot be read: %s" % answer.line, **record)
    key = "%s@%s%s" % (repo, oldest, ":shadow" if mode == "shadow" else "")
    record.update({"key": key, "train": train, "source": source, "production": production,
                   "commits": len(commits), "landings": len(landed), "oldestLanding": oldest,
                   "landedAt": datetime.datetime.fromtimestamp(since, UTC).isoformat(), "waitedMinutes": int(waited),
                   "claim": {"kind": "release-train", "key": key, "expiryMinutes": wait,
                             "purpose": "release backstop"},
                   "trainClaim": {"kind": "release-train", "key": repo}})
    if waited <= wait:
        raise Answer("SKIP", "not waiting long enough: the oldest landing %s has waited %d of %d minutes"
                     % (oldest[:12], int(waited), wait), **record)
    block = release.get("clearance")
    scope = block.get("scope") if isinstance(block, dict) else None
    if scope in GATED_SCOPES:
        # Under these scopes a release holds the tower only from its cut (merge-and-deploy: only for
        # its merge and deploy), its train phase runs outside it, and it hands the train claim on at
        # the cut (merge-and-deploy: once its pull request is open) so the next train phase can run
        # while it deploys: an open release pull request or a held tower is not the release THIS
        # waiting work needs. The train claim (claimed next, by the caller) alone decides.
        why = "not read: under release.clearance.scope %s the train claim alone decides" % scope
        record["releasePullRequests"] = record["clearance"] = why
    else:
        busy, why = open_release_prs(root, release, production, source, gh_repo)
        record["releasePullRequests"] = why
        if busy:
            raise Answer("SKIP", why, **record)
        busy, why = clearance(config, root)
        record["clearance"] = why
        if busy:
            raise Answer("SKIP", why, **record)
    fetch_production(root, production)
    items = delta_items(root, train, source, production)
    record["items"] = items
    if items and not holds_path:
        raise Answer("HOLDS", " ".join(items), **record)
    held, reason = check_holds(holds_path, items, now, root) if holds_path else (False, "no item named in the release delta")
    record["holds"] = reason
    if held:
        raise Answer("SKIP", reason if reason.startswith("held") else "held: " + reason, **record)
    why = "the oldest of %d landing(s), %s, has waited %d minutes, over %d; %d commit(s) on %s not on %s" % (
        len(landed), oldest[:12], int(waited), wait, len(commits), train, source)
    if mode == "live":
        raise Answer("START", "%s (%s)" % (key, why), **record)
    raise Answer("SHADOW", "%s would start (%s)" % (key, why), **record)


FAILURES = ("ABSENT", "UNREACHABLE", "FORBIDDEN", "ERROR")


def decide_claim(request):
    """The backstop claim's two decisions (backstop.md). `before`: get_claim's answer for the key.
    A live claim held by ANYONE, this session included, is skip — never claimed again, so never
    renewed or extended; a lapsed one is taken over by its digest; none, or one released not final,
    is claimed. `after`: claim_work's answer. Won → proceed, unless it renewed a claim this holder
    already held without the read showing it lapsed (skip: `before` was not takeover); a renewal
    after a takeover is this holder taking back its own lapsed claim (proceed); lost → skip. A
    failure is degrade either way."""
    stage, response = request.get("stage"), request.get("response")
    now = parse_now(request.get("now"))
    if isinstance(response, dict) and (response.get("error") or str(response.get("verdict", "")).upper() in FAILURES):
        return {"action": "degrade", "message": "The claims store could not be used; the backstop does nothing."}
    if stage == "after":
        if not isinstance(response, dict):
            return {"action": "degrade", "message": "The claim answer could not be read; the backstop does nothing."}
        won = response.get("won") if "won" in response else str(response.get("verdict", "")).upper() in ("WON", "OK")
        if won and response.get("renewed") and request.get("before") != "takeover":
            # a renewal of a claim the read did not show lapsed: it was live, and this holder's own
            return {"action": "skip", "message": "This session already held the backstop claim; it starts nothing twice."}
        if won:
            return {"action": "proceed", "message": "Claimed the backstop."}
        return {"action": "skip", "message": "Another check holds the backstop claim."}
    if stage != "before":
        return {"action": "degrade", "message": "stage must be before or after"}
    row = response.get("claim") if isinstance(response, dict) and "claim" in response else \
        (response if isinstance(response, dict) and response.get("holderDigest") else None)
    if not isinstance(row, dict):
        return {"action": "claim", "message": "No backstop claim yet."}
    state = row.get("state")
    if state not in ("live", "expired", "released"):
        expires = row.get("expiresAt")
        try:
            lapsed = bool(expires) and parse_now(expires) <= now
        except Answer:
            lapsed = False
        state = "released" if row.get("releasedAt") else ("expired" if lapsed else "live")
    who = row.get("machine") or row.get("sessionName") or "a session"
    if state == "released":
        if row.get("final"):
            return {"action": "skip", "message": "The backstop claim was finished for good."}
        return {"action": "claim", "message": "The last backstop claim was released (%s)." % (row.get("outcome") or "released")}
    if state == "live":
        return {"action": "skip", "message": "The backstop claim is held by %s until %s; nothing starts before it lapses."
                % (who, row.get("expiresAt") or "it lapses")}
    return {"action": "takeover", "takeoverDigest": row.get("holderDigest"),
            "message": "The backstop claim held by %s lapsed; taking it over." % who}


def main(argv):
    args = argv[1:]
    verb = args.pop(0) if args else None
    options = {"--now": None, "--holds": None, "--recheck": None}
    as_json = False
    while args:
        flag = args.pop(0)
        if flag == "--json":
            as_json = True
        elif flag in options and args:
            options[flag] = args.pop(0)
        else:
            verb = None
            break
    if verb not in ("due", "config", "decide") or (verb != "due" and (as_json or any(options.values()))):
        sys.stderr.write("usage: backstop.py due [--now ISO] [--json] [--holds FILE] [--recheck KEY] | config | decide\n")
        return 2
    if verb == "decide":
        try:
            request = json.loads(sys.stdin.read())
            if not isinstance(request, dict):
                raise ValueError("not an object")
            print(json.dumps(decide_claim(request)))
        except (ValueError, Answer) as error:
            sys.stderr.write("backstop: decide needs a JSON object on stdin: %s\n" % error)
            return 2
        return 0
    if verb == "config":
        config, _ = load("auto_start", AUTO_START).load_config()
        found = problems(config)
        try:
            settings(config)
        except Answer as answer:
            if answer.verdict == "ERROR":
                found.insert(0, ("ERROR", "release.backstop", answer.line))
        print("\n".join("%s %s: %s" % f for f in found) if found else "OK")
        return 1 if any(f[0] == "ERROR" for f in found) else 0
    try:
        due(options["--now"], options["--holds"])
        answer = Answer("ERROR", "no verdict")
    except Answer as raised:
        answer = raised
    recheck = options["--recheck"]
    if recheck and not (answer.verdict in ("START", "SHADOW") and answer.record.get("key") == recheck):
        answer = Answer("SKIP", "changed since the claim: %s %s" % (answer.verdict, answer.line),
                        **dict(answer.record, recheck=recheck))
    if as_json:
        print(json.dumps(dict(answer.record, verdict=answer.verdict, reason=answer.line), ensure_ascii=False))
    else:
        print("%s %s" % (answer.verdict, answer.line))
    return EXIT[answer.verdict]


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except SystemExit:
        raise
    except Exception as error:  # never a traceback on the caller's screen
        print("ERROR backstop: internal error: %s" % error)
        sys.exit(1)
