#!/usr/bin/env python3
"""Is any of this work held back from release? Holds are data on the items, never memory.

The single implementation of `references/release-holds.md`. Run on an item and its ancestors
before anything lands on the release path (`build-item`: a one-off's merge onto the train or the
base branch, an epic's release onto its target) and, as a backstop, on every item in a release's
delta before the cut. Any other tool that lands or releases (a repository's own CLI) runs this
file, never a copy.

A hold is one line of an item's description, starting exactly `Release hold:` (case aside):

  Release hold: not before 2026-11-09               lifts at 00:00 that day in the hold zone
  Release hold: not before 2026-11-11T08:00-06:00   an instant: needs its offset (or Z)
  Release hold: after I20101 is live                I20101 deployed to production and checked

The hold zone is `release.holdTimeZone` (an IANA name; absent: UTC), so every machine reads a
date the same way. Any other text after `Release hold:` holds too: the run exits 2 naming the item
and the line, because a hold nobody can read is never read as no hold.

  decide  stdin {"items": [{"number", "description"}...], "now"?, "timeZone"?, "config"?,
                 "productionRef"?, "live"?}
          stdout {"held", "holds": [{"item", "kind", "value", "satisfied", "reason"}], "reason"}

`description` is the item's description as DevStride returns it (HTML, or get_item's
{"html": ...}) or plain text. `now` is an ISO date-time with its offset (absent: this machine's
clock). `config` replaces reading `.claude/ds-config.json`; `timeZone` replaces its hold zone.

Live, for `after`: the newest commit whose message names the item as a whole word (`[I20101]`,
`merge: I20101 ...`, an `epic-I20101-...` branch merge) is reachable from `productionRef` (absent:
`origin/<release.productionBranch>`, fetched by the caller), and the production merge that carried
it, or a later one, has the commit status `release/post-deploy` at success: deployed and checked,
which a merge alone is not. A repository whose releases record no such status
(`release.clearance.scope` neither `cut-to-deploy` nor `merge-and-deploy`) counts the merge, and the reason says so.
`live` (a list of item numbers) replaces the git and GitHub lookups: the fixtures' mode.

Exit 0 with an answer (held or not), 2 with one `release-holds: <reason>` line on stderr (a bad
request, a hold line that does not parse, or a status that cannot be read), 1 for anything else.
A caller lands or releases nothing on a non-zero exit, nor while `held` is true.
"""
import datetime
import html
import json
import os
import re
import subprocess
import sys
import zoneinfo

HOLD = re.compile(r"^\s*release hold\s*:\s*(.*?)\s*$", re.I)
NOT_BEFORE = re.compile(r"^not before\s+(\d{4}-\d{2}-\d{2})(?:[T ](\d{2}:\d{2}(?::\d{2})?)\s*(Z|[+-](?:0\d|1[0-4]):?[0-5]\d)?)?\.?$", re.I)
AFTER = re.compile(r"^after\s+(I\d+)\s+is\s+live\.?$", re.I)
ITEM = re.compile(r"^I\d+$")
BREAKS = re.compile(r"<\s*/?\s*(br|p|li|ul|ol|h[1-6]|div|tr|td|th|table|blockquote|pre|section|article|hr)\b[^>]*>", re.I)
TAGS = re.compile(r"<[^>]*>")


class Refuse(Exception):
    pass


def need(cond, reason):
    if not cond:
        raise Refuse(reason)


def lines_of(description):
    plain = TAGS.sub("", BREAKS.sub("\n", description))
    return [html.unescape(line).replace(" ", " ") for line in plain.splitlines()]


def holds_of(item):
    need(isinstance(item, dict) and isinstance(item.get("number"), str) and ITEM.match(item["number"]),
         "each item needs a number like I20100")
    desc = item.get("description")
    if isinstance(desc, dict):  # get_item's {"html": ...}
        desc = desc.get("html")
    need(desc is None or isinstance(desc, str), "%s: description must be text or HTML" % item["number"])
    found = []
    for line in lines_of(desc or ""):
        m = HOLD.match(line)
        if not m:
            continue
        rule = m.group(1)
        nb, after = NOT_BEFORE.match(rule), AFTER.match(rule)
        if nb and (nb.group(2) is None or nb.group(3)):
            found.append((item["number"], "notBefore", nb))
        elif after:
            found.append((item["number"], "after", after.group(1).upper()))
        else:
            raise Refuse("%s: \"%s\" does not parse, so it holds (write \"Release hold: not before YYYY-MM-DD\", "
                         "\"... not before YYYY-MM-DDTHH:MM-06:00\" or \"... after I##### is live\")" % (item["number"], line.strip()))
    return found


def clock(req):
    if "now" not in req:
        return datetime.datetime.now().astimezone()
    need(isinstance(req["now"], str), "now must be an ISO date-time with its offset")
    try:
        now = datetime.datetime.fromisoformat(req["now"].replace("Z", "+00:00"))
    except ValueError:
        raise Refuse("now must be an ISO date-time with its offset: %r" % req["now"])
    need(now.tzinfo is not None, "now must carry its offset: %r" % req["now"])
    return now


def not_before(m, now, zone):
    day, time, offset = m.group(1), m.group(2), m.group(3)
    try:
        if time is None:
            instant = datetime.datetime.combine(datetime.date.fromisoformat(day), datetime.time(), zone)
        else:
            offset = "+00:00" if offset.upper() == "Z" else (offset if ":" in offset else offset[:3] + ":" + offset[3:])
            instant = datetime.datetime.fromisoformat("%sT%s%s" % (day, time, offset))
    except ValueError:
        raise Refuse("not a real date or time in a release hold: %s" % m.group(0))
    return now >= instant, instant.isoformat(), "now %s" % now.astimezone(zone).isoformat(timespec="minutes")


def git(*args):
    p = subprocess.run(["git"] + list(args), capture_output=True)
    need(p.returncode == 0, "git %s failed: %s" % (" ".join(args[:3]), p.stderr.decode("utf-8", "replace").strip()[:200]))
    return p.stdout.decode("utf-8", "replace")


def config_of(req):
    if "config" in req:
        need(isinstance(req["config"], dict), "config must be an object")
        return req["config"]
    root = git("rev-parse", "--show-toplevel").strip()
    path = os.path.join(root, ".claude", "ds-config.json")
    if not os.path.exists(path):
        return {}
    try:
        with open(path) as f:
            config = json.load(f)
    except (OSError, ValueError) as err:
        raise Refuse("cannot read %s: %s" % (path, err))
    need(isinstance(config, dict), "%s is not a JSON object" % path)
    return config


def release_of(config):
    return config.get("release") if isinstance(config.get("release"), dict) else {}


def zone_of(req, config):
    name = req.get("timeZone", release_of(config).get("holdTimeZone") or "UTC")
    try:
        return zoneinfo.ZoneInfo(name)
    except (zoneinfo.ZoneInfoNotFoundError, ValueError, TypeError):
        raise Refuse("the hold zone must be an IANA time zone name such as America/Chicago: %r" % (name,))


def gh_status(sha):
    try:
        p = subprocess.run(["gh", "api", "repos/{owner}/{repo}/commits/%s/status" % sha, "--jq",
                            '[.statuses[] | select(.context == "release/post-deploy") | .state] | first // ""'],
                           capture_output=True)
    except OSError as err:
        raise Refuse("cannot read release/post-deploy on %s: %s" % (sha[:12], err))
    need(p.returncode == 0, "cannot read release/post-deploy on %s: %s" % (sha[:12], p.stderr.decode("utf-8", "replace").strip()[:200]))
    return p.stdout.decode().strip()


def live_check(req, config):
    if "live" in req:
        live = req["live"]
        need(isinstance(live, list) and all(isinstance(n, str) and ITEM.match(n) for n in live),
             "live must list item numbers like I20101")
        return lambda number: (number in live, "in the given live list" if number in live else "not in the given live list")
    release = release_of(config)
    ref = req.get("productionRef") or "origin/" + (release.get("productionBranch") or "master")
    need(isinstance(ref, str), "productionRef must be a ref")
    git("rev-parse", "--verify", "%s^{commit}" % ref)
    clearance = release.get("clearance") if isinstance(release.get("clearance"), dict) else {}
    checked = clearance.get("scope") in ("cut-to-deploy", "merge-and-deploy")

    def on_ref(number):
        commit = git("log", "-1", "--format=%H", "-E", "--grep=(^|[^0-9A-Za-z])%s([^0-9A-Za-z]|$)" % number, ref).strip()
        if not commit:
            return False, "no commit naming it on %s" % ref
        if not checked:
            return True, "merged to %s; this repository records no post-deploy status" % ref
        # Deploys are cumulative: a success on the carrying production merge or any later one on
        # the first-parent line proves it live. Newest first, so the usual answer is one lookup.
        # Candidates: production's first-parent commits that contain the item's commit (through any
        # parent, so a commit inside a merged branch counts), newest first.
        contains = set(git("rev-list", "--ancestry-path", "%s..%s" % (commit, ref)).split()) | {commit}
        line = [sha for sha in git("rev-list", "--first-parent", ref).split() if sha in contains]
        for sha in line:
            if gh_status(sha) == "success":
                return True, "release/post-deploy success on %s" % sha[:12]
        return False, "merged to %s (%s) but no release/post-deploy success on it or after" % (ref, commit[:12])
    return on_ref


def decide(req):
    need(isinstance(req, dict), "the request must be a JSON object")
    items = req.get("items")
    need(isinstance(items, list) and items, "items must list the work to check (the item and its ancestors)")
    found = [h for item in items for h in holds_of(item)]
    if not found:
        return {"held": False, "holds": [], "reason": "no release hold"}
    config = config_of(req)
    zone, now = zone_of(req, config), clock(req)
    is_live = live_check(req, config) if any(kind == "after" for _, kind, _ in found) else None
    holds = []
    for number, kind, value in found:
        if kind == "notBefore":
            ok, shown, against = not_before(value, now, zone)
            reason = "%s: not before %s (%s)" % (number, shown, against)
        else:
            (ok, against), shown = is_live(value), value
            reason = "%s: after %s is live (%s)" % (number, value, against)
        holds.append({"item": number, "kind": kind, "value": shown, "satisfied": ok, "reason": reason})
    open_ = [h["reason"] for h in holds if not h["satisfied"]]
    return {"held": bool(open_), "holds": holds,
            "reason": ("held: " + "; ".join(open_)) if open_ else "every release hold is met"}


def main(argv):
    if len(argv) != 2 or argv[1] != "decide":
        sys.stderr.write("release-holds: usage: release-holds.py decide < request.json\n")
        return 2
    try:
        request = json.loads(sys.stdin.read())
    except ValueError as err:
        sys.stderr.write("release-holds: the request is not JSON: %s\n" % err)
        return 2
    try:
        result = decide(request)
    except Refuse as err:
        sys.stderr.write("release-holds: %s\n" % str(err).replace("\n", " "))
        return 2
    sys.stdout.write(json.dumps(result, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as err:  # never a traceback on the caller's screen
        sys.stderr.write("release-holds: internal error: %s\n" % err)
        sys.exit(1)
