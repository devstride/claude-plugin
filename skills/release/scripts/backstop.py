#!/usr/bin/env python3
"""Has landed work waited too long for a release? The release backstop: `release.backstop`.

The rules are in `skills/release/references/backstop.md`. Releases still start whenever work is
ready (`release.autoStart`, or by hand); this check, run on a schedule (every few minutes by a
dispatcher, or `/devstride:release backstop` by hand), starts one ONLY when work on the release
train has waited longer than `maxWaitMinutes` and nothing is releasing it. It claims nothing,
starts nothing and writes nothing: a START or SHADOW goes on to claim the backstop key, and that
claim, not this check, decides which machine acts. Its `--json` answer is the record the caller
stores with that claim.

  due [--now ISO] [--json] [--holds FILE]
      START <key> (<why>)                live: claim <key>, the train claim, then release     exit 0
      SHADOW <key> would start (<why>)   shadow: claim <key>, record, start nothing             exit 10
      SKIP <reason>                      nothing to do now, and why                             exit 11
      OFF <reason>                       no release.backstop block, or its mode is off          exit 12
      HOLDS <I#> [<I#>...]               read these items and their ancestors; run again        exit 13
      ERROR <reason>                     a bad config, an unreadable train or holds request     exit 1
    SKIP covers: not waiting long enough, nothing waiting, a release in progress, held, clearance
    unreadable, no release train, no claims block. HOLDS: the waiting work names these items; write
    release-holds.py's request for each and its ancestors and run `due` again with --holds <file>.
  config
      OK, or one `ERROR|WARN <path>: <message>` line per finding; exit 1 on an ERROR.
      skills/doctor/scripts/validate-config.py reports the same findings (it imports `problems`).
  usage                                                                                    exit 2

WAITING WORK is every LANDING on the train not yet on the release source: each first-parent commit
in origin/<source>..origin/<train>, except a merge whose other parents are all already on the source
(a sync merge, which carries nothing). Work lands on the train as a `--no-ff` merge or a pull
request merge, so a landing's committer time is the moment it landed; it is read from git, so every
machine computes the same wait. The OLDEST landing's committer time is when the wait began, and its
SHA keys the claim: `<owner>/<repo>@<sha>` (kind `release-train`; `:shadow` appended in shadow mode
so shadow records never consume a live key). Every check while that work waits computes the same
key, so concurrent checks dedupe; once the work ships, the oldest landing changes and so does the key.

START or SHADOW only when ALL hold: the mode is live or shadow, a `claims` block is configured, the
train holds work beyond the source (auto-start.py's `train_state`, one rule, reused), the oldest
landing waited MORE than `maxWaitMinutes` (default 120), clearance shows no release in progress
(with `release.clearance` set: its provider's `status --json` is `clear`, with no open release pull
request on final; unreadable is never clear), and no release hold holds the waiting items
(release-holds.py on `--holds`, the single implementation; its exit 2 is held). A release that holds
the train claim is found by the caller's own claim of it (claim_work decides; a list never does).

`--now` replaces the clock (an ISO time with its offset). Test seams are auto-start.py's:
AUTO_START_REPO (owner/name) and AUTO_START_NO_FETCH=1. Network: `git ls-remote`/`git fetch`, and the
clearance provider's `status` when `release.clearance` is set.
"""
import datetime
import importlib.util
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
AUTO_START = os.path.join(HERE, "auto-start.py")
HOLDS = os.path.join(os.path.dirname(os.path.dirname(HERE)), "build-item/scripts/release-holds.py")
MODES = ("off", "shadow", "live")
DEFAULT_WAIT, MIN_WAIT = 120, 15
ITEM = re.compile(r"(?<![0-9A-Za-z])I\d{2,}(?![0-9A-Za-z])")
UTC = datetime.timezone.utc
EXIT = {"START": 0, "SHADOW": 10, "SKIP": 11, "OFF": 12, "HOLDS": 13, "ERROR": 1}


class Answer(Exception):
    def __init__(self, verdict, line, **record):
        Exception.__init__(self, line)
        self.verdict, self.line, self.record = verdict, line, record


def load_auto_start():
    """The config lookup, the train check and the repository key are auto-start.py's; never a copy."""
    spec = importlib.util.spec_from_file_location("auto_start", AUTO_START)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def section(value, key):
    found = value.get(key) if isinstance(value, dict) else None
    return found if isinstance(found, dict) else {}


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
    elif isinstance(config["claims"].get("commands"), dict):
        found.append(("WARN", "release.backstop.mode", "a `claims.commands` store cannot release a claim "
                      "final, so a stopped release may be started again for the same waiting work"))
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
    wait = block.get("maxWaitMinutes", DEFAULT_WAIT)
    if isinstance(wait, bool) or not isinstance(wait, int) or wait < MIN_WAIT:
        raise Answer("ERROR", "release.backstop.maxWaitMinutes must be a whole number of minutes, at least %d" % MIN_WAIT)
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


def git(root, *args):
    done = subprocess.run(["git", "-C", root] + list(args), capture_output=True, text=True, stdin=subprocess.DEVNULL)
    if done.returncode != 0:
        raise Answer("ERROR", "git %s failed: %s" % (args[0], (done.stderr or "").strip()[:200]))
    return done.stdout


def landings(root, train, source):
    """-> [(sha, committed epoch)] newest first: the first-parent commits beyond the source, sync
    merges (every other parent already on the source) left out."""
    found = []
    for row in git(root, "log", "--first-parent", "--format=%H %ct %P", "origin/%s..origin/%s" % (source, train)).splitlines():
        parts = row.split()
        if len(parts) < 3:
            continue
        sha, when, parents = parts[0], int(parts[1]), parts[2:]
        others = parents[1:]
        if others and all(subprocess.run(["git", "-C", root, "merge-base", "--is-ancestor", p, "origin/%s" % source],
                                         stdin=subprocess.DEVNULL).returncode == 0 for p in others):
            continue
        found.append((sha, when))
    return found


def waiting_items(root, train, source):
    """Every item number a commit message on the train beyond the source names, merges included."""
    found = set(ITEM.findall(git(root, "log", "--format=%B", "origin/%s..origin/%s" % (source, train))))
    return sorted(found, key=lambda number: int(number[1:]))


def clearance(config, root):
    """-> (busy, reason). No release.clearance → not read. Unreadable is never clear."""
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
        done = subprocess.run(argv, cwd=root, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=120)
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
    final = status.get("onFinal")
    if isinstance(final, dict) and final.get("number"):
        return True, "a release is in progress: release pull request #%s is open" % final["number"]
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
        raise Answer("ERROR", "the holds request needs items: each waiting item and its ancestors")
    numbers = {entry.get("number") for entry in listed if isinstance(entry, dict)}
    missing = [n for n in items if n not in numbers]
    if missing:
        raise Answer("ERROR", "the holds request leaves out %s: read every waiting item and its ancestors" % " ".join(missing))
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


def due(now_text, holds_path):
    auto = load_auto_start()
    now = parse_now(now_text)
    try:
        config, root = auto.load_config()
    except SystemExit:   # load_config printed its own ERROR line
        raise Answer("ERROR", "the config cannot be read", printed=True)
    mode, wait = settings(config)
    record = {"mode": mode, "now": now.isoformat(), "maxWaitMinutes": wait}
    if not isinstance(config.get("claims"), dict):
        raise Answer("SKIP", "release.backstop needs a claims block; without one it does nothing", **record)
    state = auto.train_state(config, root)
    if state[0] != "AHEAD":
        raise Answer(state[0], state[1], **record)
    _, commits, train, source = state
    landed = landings(root, train, source)
    if not landed:
        raise Answer("SKIP", "the train holds nothing beyond %s" % source, **record)
    oldest, since = landed[-1]
    waited = (now - datetime.datetime.fromtimestamp(since, UTC)).total_seconds() / 60
    try:
        repo = auto.repo_key(root)
    except SystemExit:
        raise Answer("ERROR", "cannot read <owner>/<repo> from the origin remote", printed=True)
    key = "%s@%s%s" % (repo, oldest, ":shadow" if mode == "shadow" else "")
    record.update({"key": key, "train": train, "source": source, "commits": len(commits), "landings": len(landed),
                   "oldestLanding": oldest, "landedAt": datetime.datetime.fromtimestamp(since, UTC).isoformat(),
                   "waitedMinutes": int(waited)})
    if waited <= wait:
        raise Answer("SKIP", "not waiting long enough: the oldest landing %s has waited %d of %d minutes"
                     % (oldest[:12], int(waited), wait), **record)
    busy, why = clearance(config, root)
    record["clearance"] = why
    if busy:
        raise Answer("SKIP", why, **record)
    items = waiting_items(root, train, source)
    record["items"] = items
    if items and not holds_path:
        raise Answer("HOLDS", " ".join(items), **record)
    held, reason = check_holds(holds_path, items, now, root) if holds_path else (False, "no item named on the train")
    record["holds"] = reason
    if held:
        raise Answer("SKIP", reason if reason.startswith("held") else "held: " + reason, **record)
    why = "the oldest of %d landing(s), %s, has waited %d minutes, over %d; %d commit(s) on %s not on %s" % (
        len(landed), oldest[:12], int(waited), wait, len(commits), train, source)
    if mode == "live":
        raise Answer("START", "%s (%s)" % (key, why), **record)
    raise Answer("SHADOW", "%s would start (%s)" % (key, why), **record)


def main(argv):
    args = argv[1:]
    verb = args.pop(0) if args else None
    options = {"--now": None, "--holds": None}
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
    if verb not in ("due", "config") or (verb == "config" and (as_json or any(options.values()))):
        sys.stderr.write("usage: backstop.py due [--now ISO] [--json] [--holds FILE] | config\n")
        return 2
    if verb == "config":
        config, _ = load_auto_start().load_config()
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
    except Answer as answer:
        if answer.record.pop("printed", False):
            return 1
        if as_json:
            print(json.dumps(dict(answer.record, verdict=answer.verdict, reason=answer.line), ensure_ascii=False))
        else:
            print("%s %s" % (answer.verdict, answer.line))
        return EXIT[answer.verdict]
    print("ERROR no verdict")
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except SystemExit:
        raise
    except Exception as error:  # never a traceback on the caller's screen
        print("ERROR backstop: internal error: %s" % error)
        sys.exit(1)
