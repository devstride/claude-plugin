#!/usr/bin/env python3
"""Board placement rules — validate them, resolve one item to its board, classify what is wrong
with them, name a folder's current cycle. Deterministic and dependency-free.

The single implementation behind `skills/setup/references/boards-mode.md` (setup boards),
`skills/doctor/references/boards.md` (doctor) and
`skills/build-item/references/board-placement.md` (the build loop's placement at pickup).

The rules are an ordered list, first match wins: `boardPlacement.rules` in
`.claude/ds-config.json`, with the contributor's personal rules read before them. Personal rules
only override a repository block: without one nothing is configured and they are ignored.

  {"name"?: <text>,
   "match"?: {"workType"?: [<name>…], "team"?: [<team id>…], "tag"?: [<tag name>…],
              "customField"?: {"<field id>": [<value>…]}, "under"?: [<item number>…]},
   "place": {"board": <board id>} | {"cycleFolder": <board folder id>} | {"none": true}}

Every condition a rule names must hold; a list holds when any entry does; work types and tags
compare case-insensitively; no `match` (or an empty one) matches every item. `board` is one
long-lived board. `cycleFolder` is the dated board directly in that folder whose dates cover the
day. `none` leaves the item off boards.

  personal-path
      -> the contributor's personal rules file for this repository (it need not exist).
         `DEVSTRIDE_BOARD_PLACEMENT_FILE` names it outright; else
         <CLAUDE_CONFIG_DIR or ~/.claude>/devstride/board-placement/<owner>__<repo>.json.
  validate [--config <path>] [--personal <path>]
      -> line 1: BOARD PLACEMENT: VALID | NOT CONFIGURED | INVALID (<n>)
         NOT CONFIGURED: a `NOTE …` line follows when a personal file exists and is ignored.
         VALID: line 2 is {"rules": […each with "source": "personal" | "repository"],
         "personalPath": <path>, "personalRules": <n>} as JSON.
         INVALID: one `ERROR <where>: <problem>` line per problem.
         Exit 0 valid or not configured, 1 invalid, 2 a file that cannot be read.
  resolve [--config <path>] [--personal <path>]
      stdin {"item": {"number"?, "workType", "teamId"?, "tags"?: [<name>…], "customFields"?: {…},
             "ancestors"?: [<number>…], "boardId"?: <id> | null, "done"?: bool},
             "boards": [{"id", "boardFolderId"?, "label"?, "archived"?, "startDate"?,
             "endDate"?}…], "date": "YYYY-MM-DD"}
      -> one line, always exit 0 (placement never blocks a turn; 2 only for unusable input or
         a config or personal file that cannot be read):
         PLACE MOVE <board id> (<why>)   put the item on that board
         PLACE KEEP (<why>)              leave it where it is
         PLACE NONE (<why>)              no rule places it (`… says no board` when a rule
                                         decided that); never a reason to take it off a board
         PLACE UNRESOLVED (<why>)        a rule matched but its board cannot be used
         An item moves only from no board, from the Active Agents board, or from a dated board
         of the same cycle folder that has ENDED; any other board was chosen by a person and is
         kept. `tags` and `ancestors` must be arrays of strings, `customFields` an object,
         `boardId` a string and `done` a boolean; each may be absent or null, which reads as
         none. Any other shape exits 2. A custom field's values compare as the item carries
         them: a choice field carries its option's id, not its label.
  current --folder <board folder id>
      stdin {"boards": […as resolve], "date": "YYYY-MM-DD"}
      -> CURRENT <board id> <label> | CURRENT NONE — the dated board of that folder covering
         the day, for a question asked before any rule exists.
  classify [--config <path>] [--personal <path>]
      stdin {"boards": […as resolve], "date": "YYYY-MM-DD", "placedTypes"?: [<name>…],
             "workTypes"?: [<name>…], "teams"?: [<id>…], "tags"?: [<name>…],
             "customFields"?: [<id>…]}
      -> {"findings": [{"check", "severity", "message", "items"?: […]}…]}; an empty list is clean.

Bad input exits 2 with one `{"error": …}` line. `--config` defaults to `.claude/ds-config.json`
under the repository root; `--personal` to `personal-path`.
"""
import datetime
import json
import os
import re
import subprocess
import sys

MATCH_KEYS = ("workType", "team", "tag", "customField", "under")
PLACE_KEYS = ("board", "cycleFolder", "none")
NUMBER_RE = re.compile(r"^[IF][0-9]+$", re.I)
SETUP = "/devstride:setup boards"
IGNORED = ("personal rules in %s are ignored: the repository has no boardPlacement block, and "
           "personal rules only override one")


def fail(message):
    print(json.dumps({"error": message}))
    sys.exit(2)


def git(*args):
    try:
        out = subprocess.run(["git"] + list(args), capture_output=True, text=True, timeout=10)
        if out.returncode == 0:
            return out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return ""


def repo_root():
    return git("rev-parse", "--show-toplevel") or os.getcwd()


def option(args, name, default=None):
    if name in args:
        i = args.index(name)
        if i + 1 >= len(args):
            fail("%s needs a value" % name)
        value = args[i + 1]
        del args[i:i + 2]
        return value
    return default


def fold(value):
    return value.strip().casefold() if isinstance(value, str) else ""


def repo_slug():
    """<owner>__<repo> from the origin remote; else the main checkout's directory name, so every
    worktree of one repository shares one personal file."""
    remote = git("remote", "get-url", "origin")
    parts = [p for p in re.split(r"[/:]", re.sub(r"\.git$", "", remote)) if p]
    if len(parts) >= 2:
        slug = "%s__%s" % (parts[-2], parts[-1])
    else:
        common = git("rev-parse", "--path-format=absolute", "--git-common-dir")
        base = os.path.dirname(common) if common else repo_root()
        slug = os.path.basename(base.rstrip(os.sep)) or "repository"
    return re.sub(r"[^a-z0-9._-]+", "-", slug.lower()).strip("-") or "repository"


def personal_path():
    named = os.environ.get("DEVSTRIDE_BOARD_PLACEMENT_FILE")
    if named:
        return os.path.abspath(os.path.expanduser(named))
    home = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    return os.path.join(home, "devstride", "board-placement", repo_slug() + ".json")


def read_json(path, what):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as error:
        print("BOARD PLACEMENT: %s unreadable: %s" % (what, error))
        sys.exit(2)
    if not isinstance(data, dict):
        print("BOARD PLACEMENT: %s unreadable: not a JSON object" % what)
        sys.exit(2)
    return data


def strings(value):
    return isinstance(value, list) and bool(value) and all(
        isinstance(v, str) and v.strip() for v in value)


def check_rule(rule, where):
    problems = []
    if not isinstance(rule, dict):
        return ["ERROR %s: must be an object" % where]
    for key in sorted(set(rule) - {"name", "match", "place"}):
        if not key.startswith("_"):
            problems.append("ERROR %s.%s: not a known key" % (where, key))
    if "name" in rule and (not isinstance(rule["name"], str) or not rule["name"].strip()):
        problems.append("ERROR %s.name: must be a non-empty string" % where)
    match = rule.get("match", {})
    if not isinstance(match, dict):
        problems.append("ERROR %s.match: must be an object" % where)
    else:
        for key in sorted(set(match) - set(MATCH_KEYS)):
            if not key.startswith("_"):
                problems.append("ERROR %s.match.%s: not a known condition" % (where, key))
        for key in ("workType", "team", "tag", "under"):
            if key in match and not strings(match[key]):
                problems.append("ERROR %s.match.%s: must be a non-empty array of strings"
                                % (where, key))
        if strings(match.get("under")):
            for number in match["under"]:
                if not NUMBER_RE.match(number.strip()):
                    problems.append("ERROR %s.match.under: %r is not an item number"
                                    % (where, number))
        if "customField" in match:
            fields = match["customField"]
            if not isinstance(fields, dict) or not fields:
                problems.append("ERROR %s.match.customField: must be an object of field id to "
                                "values" % where)
            else:
                for field, values in sorted(fields.items()):
                    if not isinstance(values, list) or not values or not all(
                            isinstance(v, (str, int, float, bool)) for v in values):
                        problems.append("ERROR %s.match.customField.%s: must be a non-empty "
                                        "array of values" % (where, field))
    place = rule.get("place")
    if not isinstance(place, dict):
        problems.append("ERROR %s.place: must be an object with board, cycleFolder or none"
                        % where)
        return problems
    for key in sorted(set(place) - set(PLACE_KEYS)):
        if not key.startswith("_"):
            problems.append("ERROR %s.place.%s: not a known key" % (where, key))
    named = [k for k in PLACE_KEYS if k in place]
    if len(named) != 1:
        problems.append("ERROR %s.place: must name exactly one of board, cycleFolder, none"
                        % where)
    elif named[0] == "none":
        if place["none"] is not True:
            problems.append("ERROR %s.place.none: must be true" % where)
    elif not isinstance(place[named[0]], str) or not place[named[0]].strip():
        problems.append("ERROR %s.place.%s: must be a non-empty id" % (where, named[0]))
    return problems


def check_rules(rules, where):
    if not isinstance(rules, list):
        return ["ERROR %s: must be an array of rules" % where]
    problems = []
    for i, rule in enumerate(rules):
        problems.extend(check_rule(rule, "%s[%d]" % (where, i)))
    return problems


def load(args):
    """(rules, problems, meta). rules is None when nothing is configured anywhere."""
    config_path = option(args, "--config") or os.path.join(repo_root(), ".claude",
                                                           "ds-config.json")
    personal = option(args, "--personal") or personal_path()
    problems, repository, mine = [], [], []
    configured = False
    agents_board = None
    if os.path.exists(config_path):
        config = read_json(config_path, "config")
        agents = config.get("activeAgents")
        if isinstance(agents, dict) and isinstance(agents.get("boardId"), str):
            agents_board = agents["boardId"]
        block = config.get("boardPlacement")
        if block is not None:
            configured = True
            if not isinstance(block, dict):
                problems.append("ERROR boardPlacement: must be an object or null")
            else:
                for key in sorted(set(block) - {"rules"}):
                    if not key.startswith("_"):
                        problems.append("ERROR boardPlacement.%s: not a known key" % key)
                found = check_rules(block.get("rules"), "boardPlacement.rules")
                problems.extend(found)
                if not found:
                    repository = block["rules"]
    ignored = os.path.exists(personal) and not configured
    if os.path.exists(personal) and configured:
        data = read_json(personal, "personal rules")
        for key in sorted(set(data) - {"rules"}):
            if not key.startswith("_"):
                problems.append("ERROR personal %s: not a known key" % key)
        found = check_rules(data.get("rules"), "personal rules")
        problems.extend(found)
        if not found:
            mine = data["rules"]
    rules = [dict(r, source="personal") for r in mine] + \
            [dict(r, source="repository") for r in repository]
    if agents_board:
        for r in rules:
            if r["place"].get("board") == agents_board:
                problems.append("ERROR %s rule %s: places items on activeAgents.boardId, which "
                                "holds plan roots only" % (r["source"], label(r)))
    meta = {"personalPath": personal, "personalRules": len(mine), "agentsBoard": agents_board,
            "personalIgnored": ignored}
    return (rules if configured else None), problems, meta


def label(rule):
    return repr(rule["name"]) if rule.get("name") else json.dumps(rule.get("match") or {},
                                                                  sort_keys=True)


def cmd_personal_path(_args):
    print(personal_path())
    return 0


def cmd_validate(args):
    rules, problems, meta = load(args)
    if rules is None:
        print("BOARD PLACEMENT: NOT CONFIGURED")
        if meta["personalIgnored"]:
            print("NOTE %s" % IGNORED % meta["personalPath"])
        return 0
    if problems:
        print("BOARD PLACEMENT: INVALID (%d)" % len(problems))
        print("\n".join(problems))
        return 1
    print("BOARD PLACEMENT: VALID")
    print(json.dumps({"rules": rules, "personalPath": meta["personalPath"],
                      "personalRules": meta["personalRules"]}, sort_keys=True))
    return 0


def read_stdin():
    try:
        request = json.load(sys.stdin)
    except ValueError as error:
        fail("stdin is not JSON: %s" % error)
    if not isinstance(request, dict):
        fail("stdin must be one JSON object")
    return request


def day(value, what):
    if isinstance(value, str):
        try:
            return datetime.date.fromisoformat(value.strip()[:10])
        except ValueError:
            pass
    fail("%s must be a YYYY-MM-DD date" % what)


def board_list(request):
    boards = request.get("boards")
    if not isinstance(boards, list):
        fail("boards must be an array")
    out = []
    for b in boards:
        if not isinstance(b, dict) or not isinstance(b.get("id"), str) or not b["id"]:
            fail("every board needs an id")
        entry = {"id": b["id"], "folder": b.get("boardFolderId"), "label": b.get("label") or b["id"],
                 "archived": bool(b.get("archived")), "start": None, "end": None}
        if isinstance(b.get("startDate"), str) and isinstance(b.get("endDate"), str):
            try:
                entry["start"] = datetime.date.fromisoformat(b["startDate"].strip()[:10])
                entry["end"] = datetime.date.fromisoformat(b["endDate"].strip()[:10])
            except ValueError:
                entry["start"] = entry["end"] = None
        out.append(entry)
    return out


def cycles(boards, folder):
    """The dated, unarchived boards directly in a folder, earliest first."""
    found = [b for b in boards if b["folder"] == folder and b["start"] and b["end"]
             and not b["archived"]]
    return sorted(found, key=lambda b: (b["start"], b["end"], b["id"]))


def covering(boards, folder, when):
    """The dated board of a folder that covers a day; the shortest when two overlap. On a day
    one cycle ends and another starts, the one starting takes over."""
    found = [b for b in cycles(boards, folder) if b["start"] <= when <= b["end"]]
    if any(b["start"] == when for b in found):
        found = [b for b in found if not (b["end"] == when and b["start"] < when)]
    found.sort(key=lambda b: ((b["end"] - b["start"]).days, b["id"]))
    return found[0] if found else None


def matches(rule, item):
    match = rule.get("match") or {}
    if "workType" in match and fold(item.get("workType")) not in {fold(v) for v in match["workType"]}:
        return False
    if "team" in match and item.get("teamId") not in match["team"]:
        return False
    if "tag" in match:
        tags = {fold(t) for t in item.get("tags") or [] if isinstance(t, str)}
        if not tags & {fold(v) for v in match["tag"]}:
            return False
    if "under" in match:
        above = {a.strip().upper() for a in item.get("ancestors") or [] if isinstance(a, str)}
        if not above & {v.strip().upper() for v in match["under"]}:
            return False
    if "customField" in match:
        fields = item.get("customFields") if isinstance(item.get("customFields"), dict) else {}
        for field, wanted in match["customField"].items():
            value = fields.get(field)
            have = value if isinstance(value, list) else [value]
            if not {fold(str(v)) for v in have if v is not None} & {fold(str(w)) for w in wanted}:
                return False
    return True


def cmd_resolve(args):
    rules, problems, meta = load(args)
    request = read_stdin()
    item = request.get("item")
    if not isinstance(item, dict) or not isinstance(item.get("workType"), str):
        fail("item must be an object with a workType")
    for key in ("tags", "ancestors"):
        value = item.get(key)
        if value is not None and not (isinstance(value, list)
                                      and all(isinstance(v, str) for v in value)):
            fail("item.%s must be an array of strings" % key)
    if item.get("customFields") is not None and not isinstance(item["customFields"], dict):
        fail("item.customFields must be an object")
    if item.get("boardId") is not None and not isinstance(item["boardId"], str):
        fail("item.boardId must be a board id or null")
    if item.get("done") is not None and not isinstance(item["done"], bool):
        fail("item.done must be true or false")
    boards = board_list(request)
    when = day(request.get("date"), "date")
    if rules is None:
        print("PLACE NONE (no board placement rules)")
        return 0
    if problems:
        print("PLACE UNRESOLVED (the rules are invalid; run validate)")
        return 0
    if item.get("done"):
        print("PLACE KEEP (the item is Done)")
        return 0
    rule = next((r for r in rules if matches(r, item)), None)
    if rule is None:
        print("PLACE NONE (no rule matches a %s)" % item["workType"])
        return 0
    why = "%s rule %s" % (rule["source"], label(rule))
    place = rule["place"]
    if place.get("none"):
        print("PLACE NONE (%s says no board)" % why)
        return 0
    by_id = {b["id"]: b for b in boards}
    if "board" in place:
        target = by_id.get(place["board"])
        if target is None or target["archived"]:
            print("PLACE UNRESOLVED (%s names a board that is missing or archived)" % why)
            return 0
    else:
        target = covering(boards, place["cycleFolder"], when)
        if target is None:
            print("PLACE UNRESOLVED (%s: no dated board in that folder covers %s)"
                  % (why, when.isoformat()))
            return 0
    if meta["agentsBoard"] and target["id"] == meta["agentsBoard"]:
        print("PLACE UNRESOLVED (%s leads to the Active Agents board, which holds plan roots "
              "only)" % why)
        return 0
    current = item.get("boardId")
    if current == target["id"]:
        print("PLACE KEEP (already on %s)" % target["label"])
    elif not current or current == meta["agentsBoard"]:
        print("PLACE MOVE %s (%s; %s)" % (target["id"], target["label"], why))
    else:
        was = by_id.get(current)
        if ("cycleFolder" in place and was and was["end"] and was["end"] < when
                and was["folder"] == target["folder"]):
            print("PLACE MOVE %s (%s, carried over from %s; %s)"
                  % (target["id"], target["label"], was["label"], why))
        else:
            print("PLACE KEEP (on %s, which a person chose)" % (was["label"] if was else current))
    return 0


def finding(check, message, severity="FAIL", **extra):
    out = {"check": check, "severity": severity, "message": message}
    out.update(extra)
    return out


def known(request, key):
    value = request.get(key)
    if value is None:
        return None
    if not isinstance(value, list):
        fail("%s must be an array" % key)
    return {fold(v) for v in value if isinstance(v, str)}


def answers(rule, work_type):
    """A rule answers "where does this type go" when the type alone decides it: no conditions,
    or only a work type condition naming it. A rule about one team or tag answers for less."""
    match = {k: v for k, v in (rule.get("match") or {}).items() if not k.startswith("_")}
    if not match:
        return True
    return set(match) == {"workType"} and fold(work_type) in {fold(v) for v in match["workType"]}


def cmd_classify(args):
    rules, problems, meta = load(args)
    request = read_stdin()
    boards = board_list(request)
    when = day(request.get("date"), "date")
    if rules is None:
        findings = [finding("not-configured", "no board placement rules; %s asks where each kind "
                            "of item goes" % SETUP, "INFO")]
        if meta["personalIgnored"]:
            findings.append(finding("personal-ignored", IGNORED % meta["personalPath"], "INFO"))
        print(json.dumps({"findings": findings}))
        return 0
    if problems:
        print(json.dumps({"findings": [finding("invalid", p[len("ERROR "):]) for p in problems]}))
        return 0
    findings = []
    by_id = {b["id"]: b for b in boards}
    types, teams = known(request, "workTypes"), known(request, "teams")
    tags, fields = known(request, "tags"), known(request, "customFields")
    seen_folders = set()
    catch_all = None
    for index, rule in enumerate(rules):
        name = "%s rule %s" % (rule["source"], label(rule))
        match = {k: v for k, v in (rule.get("match") or {}).items() if not k.startswith("_")}
        if catch_all is not None:
            findings.append(finding("unreachable", "%s never applies: %s before it matches every "
                                    "item" % (name, catch_all), "INFO"))
        elif not match:
            catch_all = name
        for key, have, what in (("workType", types, "work type"), ("team", teams, "team"),
                                ("tag", tags, "tag")):
            missing = [v for v in match.get(key, []) if have is not None and fold(v) not in have]
            if missing:
                findings.append(finding("unknown-" + key.lower(), "%s names a %s the organization "
                                        "does not have: %s" % (name, what, ", ".join(missing)),
                                        items=missing))
        missing = [f for f in match.get("customField", {}) if fields is not None
                   and fold(f) not in fields]
        if missing:
            findings.append(finding("unknown-field", "%s names a custom field the organization "
                                    "does not have: %s" % (name, ", ".join(missing)),
                                    items=missing))
        place = rule["place"]
        if "board" in place:
            target = by_id.get(place["board"])
            if target is None or target["archived"]:
                findings.append(finding("rule-board", "%s names a board that is %s" % (
                    name, "archived" if target else "missing"), items=[place["board"]]))
        elif "cycleFolder" in place and place["cycleFolder"] not in seen_folders:
            folder = place["cycleFolder"]
            seen_folders.add(folder)
            dated = cycles(boards, folder)
            now = covering(boards, folder, when)
            if not dated:
                findings.append(finding("rule-folder", "%s names a folder with no dated board in "
                                        "it" % name, items=[folder]))
            elif now is None:
                findings.append(finding("no-current-cycle", "%s: no dated board in that folder "
                                        "covers %s, so work starting today is not placed"
                                        % (name, when.isoformat()), items=[folder]))
            elif meta["agentsBoard"] and now["id"] == meta["agentsBoard"]:
                findings.append(finding("rule-board", "%s: today's board in that folder is the "
                                        "Active Agents board, which holds plan roots only, so "
                                        "nothing is placed" % name, items=[now["id"]]))
            elif covering(boards, folder, now["end"] + datetime.timedelta(days=1)) is None:
                findings.append(finding("no-next-cycle", "%s: nothing follows %s, which ends %s; "
                                        "work starting after that is not placed until the next "
                                        "cycle's board exists" % (name, now["label"],
                                                                 now["end"].isoformat()),
                                        "INFO", items=[folder]))
    placed = request.get("placedTypes")
    if placed is not None:
        if not isinstance(placed, list):
            fail("placedTypes must be an array")
        uncovered = [t for t in placed if isinstance(t, str) and not any(
            answers(r, t) for r in rules)]
        if uncovered:
            findings.append(finding("uncovered-type", "no rule says where these go: %s. Answer "
                                    "with %s (a rule may say no board)" % (", ".join(uncovered),
                                                                           SETUP),
                                    items=uncovered))
    if meta["personalRules"]:
        findings.append(finding("personal", "%d personal rule(s) from %s apply before the "
                                "repository's on this machine" % (meta["personalRules"],
                                                                  meta["personalPath"]), "INFO"))
    print(json.dumps({"findings": findings}))
    return 0


def cmd_current(args):
    folder = option(args, "--folder")
    if not folder:
        fail("current needs --folder <board folder id>")
    request = read_stdin()
    now = covering(board_list(request), folder, day(request.get("date"), "date"))
    print("CURRENT %s %s" % (now["id"], now["label"]) if now else "CURRENT NONE")
    return 0


def main():
    commands = {"personal-path": cmd_personal_path, "validate": cmd_validate,
                "resolve": cmd_resolve, "classify": cmd_classify, "current": cmd_current}
    if len(sys.argv) < 2 or sys.argv[1] not in commands:
        fail("usage: board-placement.py personal-path|validate|resolve|classify|current …")
    sys.exit(commands[sys.argv[1]](sys.argv[2:]))


if __name__ == "__main__":
    main()
