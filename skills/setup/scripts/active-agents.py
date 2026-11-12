#!/usr/bin/env python3
"""The Active Agents block — validate it, merge a tag into a tag group, render and run its
commands, resolve and settle a plan's board root, pick the shared view, classify board drift.
Deterministic and dependency-free.

The single implementation behind `skills/setup/references/agents-mode.md` (setup agents),
`skills/doctor/references/agents.md` (doctor agents) and
`skills/build-item/references/active-agents.md` (the build loop's board placement and commands).

  validate [--config <path>]
      -> line 1: ACTIVE AGENTS: VALID | NOT CONFIGURED | INVALID (<n>)
         VALID: line 2 is the effective block, defaults filled, as JSON.
         INVALID: one `ERROR activeAgents.<key>: <problem>` line per problem.
         Exit 0 valid or not configured (no config file yet counts as not configured), 1
         invalid, 2 a config file that cannot be read.
  merge-labels   stdin {"labels": [<id>…], "tag": "<id>"}
      -> {"change": bool, "added": […], "before": […], "after": […]}  (existing order kept)
  render <start|end> <root> [--config <path>]
      -> the command with `<root>` replaced; a root that is not ^[IF][0-9]+$ is refused.
  run <start|end> <root> [--config <path>] [--timeout <seconds>]
      -> one line: ACTIVE AGENTS <verb>: DONE | FAILED <reason> | NOT CONFIGURED. Runs from the
         repository root with ACTIVE_AGENTS_ROOT, ACTIVE_AGENTS_TAG and
         ACTIVE_AGENTS_STALE_MINUTES exported; always exit 0 (presence never blocks a turn),
         except 2 for a refused root or a bad verb.
  resolve-root   stdin {"chain": [{"number", "workType", "marker"? | "description"?,
                 "deferred"?}…], "rootLevel": <name> | null, "leafTypes": […],
                 "argument": {"number", "workType"} | null, "planRoot": <number> | null}
      -> one line: ROOT I<n> (<source>) | ROOT NONE (<reason>). `chain` is the picked-up item
         first, then each ancestor upward. First match wins: the argument; the nearest item
         carrying the marker; the nearest item whose work type is rootLevel (case-insensitive);
         the run's plan root. A workstream, a leaf type and anything flagged `deferred` (the
         deferred container and everything under it) are never a root.
  comment <placed|removed> [--board <id> --label <text>]
      -> the { html } of the placement comment (the board the root came from) or the removal
         comment (the board it went back to); no --board means no board.
  came-from   stdin {"comments": [{"html", "dateAdded"}…]}
      -> one line: FROM <board id> | FROM NONE (<reason>), read from the newest placement comment.
  settle   stdin {"remaining": <n>, "onBoard": bool, "boardId": <id>,
           "cameFrom": {"id", "exists", "archived"} | null}
      -> one line: SETTLE KEEP (<reason>) | SETTLE MOVE <board id> | SETTLE OFF (<reason>).
  pick-view   stdin {"views": [{"id", "label", "visibility", "location"?, "boardView"?,
              "dataVersion"}…]}
      -> VIEW ADOPT <id>, then one VIEW DUPLICATE <id> line per other candidate; or VIEW CREATE.
  classify   stdin {"configured"?: bool (default true), "boards"?: [{"id", "label", "archived"}],
             "board": {"exists", "archived"} | null, "boardItems": [{"number", "workType", "done",
             "remaining"?}], "leafTypes": […], "tag": {"id"} | null, "rootLevel"?: <name> | null,
             "planRootTypes": [{"name", "labelCollectionId"}], "labelCollections": {"<id>": [<label
             id>…]}, "taggedItems": [{"number", "workType", "done"}], "views"?: [{…, "columns":
             [{"identifier", "visible"}] | null}]}
      -> {"findings": [{"check", "severity", "message", "items"?: […]}…]}; an empty list is a
         clean board. `configured: false` (no block) scans `boards` only, and is INFO at most.

Bad input exits 2 with one `{"error": …}` line. `--config` defaults to
`.claude/ds-config.json` under the repository root.
"""
import html
import json
import os
import re
import signal
import subprocess
import sys
import tempfile

DEFAULTS = {"boardId": None, "tagName": "agent active", "tagColor": "green", "staleMinutes": 20,
            "rootLevel": None}
COLOURS = ("gray-medium-dark", "red", "pink", "orange", "yellow", "lime", "green", "teal", "blue",
           "blue-medium", "purple")  # create_label's colours; the registry carries the same enum
KEYS = set(DEFAULTS) | {"commands"}
ROOT_RE = re.compile(r"^[IF][0-9]+$")
ITEM_RE = re.compile(r"^I[0-9]+$")
BOARD_LABEL = "active agents"
VIEW_LABEL = "Active Agents"
# The starting columns, in order (the DevStride MCP's view column identifiers).
STARTING_COLUMNS = ("identifier", "status", "progress", "priority", "pullRequests", "tags")
# The one-line per-plan override an owner writes in an item's description.
MARKER_RE = re.compile(r"<strong>\s*Active Agents root:\s*</strong>\s*this item", re.I)
PLACED_RE = re.compile(r"<strong>Active Agents:</strong> placed on the Active Agents board")
CAME_FROM_RE = re.compile(r"Came from: (?:no board\.|.*\(board ([A-Za-z0-9-]+)\)\.)", re.S)


def fail(message):
    print(json.dumps({"error": message}))
    sys.exit(2)


def repo_root():
    try:
        out = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True,
                             text=True, timeout=10)
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return os.getcwd()


def option(args, name, default=None):
    if name in args:
        i = args.index(name)
        if i + 1 >= len(args):
            fail("%s needs a value" % name)
        value = args[i + 1]
        del args[i:i + 2]
        return value
    return default


def load_block(path):
    """(block, problems): block None when absent or null, or when there is no config file yet
    (a fresh repository: setup agents creates both)."""
    if not os.path.exists(path):
        return None, []
    try:
        with open(path, encoding="utf-8") as f:
            config = json.load(f)
    except (OSError, ValueError) as error:
        print("ACTIVE AGENTS: config unreadable: %s" % error)
        sys.exit(2)
    if not isinstance(config, dict):
        print("ACTIVE AGENTS: config unreadable: not a JSON object")
        sys.exit(2)
    block = config.get("activeAgents")
    if block is None:
        return None, []
    if not isinstance(block, dict):
        return block, ["ERROR activeAgents: must be an object or null"]
    problems = []
    for key in sorted(set(block) - KEYS):
        if not key.startswith("_"):
            problems.append("ERROR activeAgents.%s: not a known key" % key)
    board = block.get("boardId")
    if board is not None and (not isinstance(board, str) or not board.strip()):
        problems.append("ERROR activeAgents.boardId: must be a non-empty string or null")
    for key in ("tagName", "tagColor"):
        if key in block and (not isinstance(block[key], str) or not block[key].strip()):
            problems.append("ERROR activeAgents.%s: must be a non-empty string" % key)
    if isinstance(block.get("tagColor"), str) and block["tagColor"].strip() \
            and block["tagColor"] not in COLOURS:
        problems.append("ERROR activeAgents.tagColor: must be one of " + ", ".join(COLOURS))
    level = block.get("rootLevel")
    if "rootLevel" in block and level is not None and (not isinstance(level, str)
                                                       or not level.strip()):
        problems.append("ERROR activeAgents.rootLevel: must be a non-empty work type name or null")
    stale = block.get("staleMinutes", DEFAULTS["staleMinutes"])
    if isinstance(stale, bool) or not isinstance(stale, int) or stale < 1:
        problems.append("ERROR activeAgents.staleMinutes: must be a positive whole number")
    commands = block.get("commands")
    if not isinstance(commands, dict):
        problems.append("ERROR activeAgents.commands: must be an object with start and end")
    else:
        for key in sorted(set(commands) - {"start", "end"}):
            if not key.startswith("_"):
                problems.append("ERROR activeAgents.commands.%s: not a known key" % key)
        for verb in ("start", "end"):
            value = commands.get(verb)
            if not isinstance(value, str) or not value.strip():
                problems.append("ERROR activeAgents.commands.%s: must be a non-empty command" % verb)
        start = commands.get("start")
        if isinstance(start, str) and start.strip() and "<root>" not in start:
            problems.append("ERROR activeAgents.commands.start: must contain the <root> placeholder")
    return block, problems


def effective(block):
    out = dict(DEFAULTS)
    out.update({k: v for k, v in block.items() if k in KEYS})
    return out


def cmd_validate(args):
    path = option(args, "--config") or os.path.join(repo_root(), ".claude", "ds-config.json")
    block, problems = load_block(path)
    if block is None:
        print("ACTIVE AGENTS: NOT CONFIGURED")
        return 0
    if problems:
        print("ACTIVE AGENTS: INVALID (%d)" % len(problems))
        print("\n".join(problems))
        return 1
    print("ACTIVE AGENTS: VALID")
    print(json.dumps(effective(block), sort_keys=True))
    return 0


def read_stdin():
    try:
        request = json.load(sys.stdin)
    except ValueError as error:
        fail("stdin is not JSON: %s" % error)
    if not isinstance(request, dict):
        fail("stdin must be one JSON object")
    return request


def ids(value, what):
    if not isinstance(value, list) or not all(isinstance(v, str) and v for v in value):
        fail("%s must be an array of ids" % what)
    return value


def cmd_merge_labels(_args):
    request = read_stdin()
    before = ids(request.get("labels"), "labels")
    tag = request.get("tag")
    if not isinstance(tag, str) or not tag:
        fail("tag must be a label id")
    added = [] if tag in before else [tag]
    print(json.dumps({"change": bool(added), "added": added, "before": before,
                      "after": before + added}))
    return 0


def render(args):
    if len(args) != 2 or args[0] not in ("start", "end"):
        fail("usage: render|run <start|end> <root>")
    verb, root = args
    if not ROOT_RE.match(root):
        fail("root must be an item number like I123 or F45, got %r" % root)
    return verb, root


def cmd_render(args):
    path = option(args, "--config") or os.path.join(repo_root(), ".claude", "ds-config.json")
    verb, root = render(args)
    block, problems = load_block(path)
    if block is None or problems:
        fail("activeAgents is not configured or not valid; run validate")
    print(block["commands"][verb].replace("<root>", root))
    return 0


def cmd_run(args):
    path = option(args, "--config")
    timeout = option(args, "--timeout", "10")
    verb, root = render(args)
    top = repo_root()
    block, problems = load_block(path or os.path.join(top, ".claude", "ds-config.json"))
    label = "ACTIVE AGENTS %s" % verb
    if block is None:
        print("%s: NOT CONFIGURED" % label)
        return 0
    if problems:
        print("%s: FAILED the block is not valid (%s)" % (label, problems[0]))
        return 0
    block = effective(block)
    command = block["commands"][verb].replace("<root>", root)
    env = dict(os.environ, ACTIVE_AGENTS_ROOT=root, ACTIVE_AGENTS_TAG=block["tagName"],
               ACTIVE_AGENTS_STALE_MINUTES=str(block["staleMinutes"]))
    try:
        seconds = float(timeout)
    except ValueError:
        fail("--timeout must be a number of seconds")
    # Output goes to a temporary file, never a pipe: a descendant that leaves the process group
    # and keeps the output open cannot then hold this call past the limit.
    with tempfile.TemporaryFile() as output:
        try:
            child = subprocess.Popen(command, shell=True, cwd=top, env=env, stdin=subprocess.DEVNULL,
                                     stdout=output, stderr=output, start_new_session=True)
        except OSError as error:
            print("%s: FAILED %s" % (label, error))
            return 0
        try:
            child.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            try:  # the whole group: a shell's own children must not outlive the limit
                os.killpg(child.pid, signal.SIGKILL)
            except OSError:
                pass
            print("%s: FAILED timed out after %gs" % (label, seconds))
            return 0
        output.seek(0)
        said = output.read().decode("utf-8", errors="replace")
    if child.returncode != 0:
        said = said.strip().splitlines()
        print("%s: FAILED exit %d%s" % (label, child.returncode, (": " + said[-1]) if said else ""))
        return 0
    print("%s: DONE" % label)
    return 0


def fold(name):
    return name.strip().casefold() if isinstance(name, str) else None


def chain_entry(entry, what):
    if not isinstance(entry, dict) or not isinstance(entry.get("number"), str) \
            or not ROOT_RE.match(entry["number"]):
        fail("every %s needs an item number" % what)
    return entry


def has_marker(entry):
    if "marker" in entry:
        return entry["marker"] is True
    description = entry.get("description")
    return isinstance(description, str) and bool(MARKER_RE.search(description))


def cmd_resolve_root(_args):
    request = read_stdin()
    chain = request.get("chain")
    if not isinstance(chain, list):
        fail("chain must be an array, the picked-up item first")
    chain = [chain_entry(e, "chain entry") for e in chain]
    leaves = {fold(t) for t in request.get("leafTypes") or [] if isinstance(t, str)}
    deferred = {e["number"] for e in chain if e.get("deferred") is True}

    def eligible(entry):
        return ITEM_RE.match(entry["number"]) and entry["number"] not in deferred \
            and fold(entry.get("workType")) not in leaves

    argument = request.get("argument")
    if argument is not None:
        argument = chain_entry(argument, "argument")
        if eligible(argument):
            print("ROOT %s (argument)" % argument["number"])
            return 0
    for entry in chain:
        if eligible(entry) and has_marker(entry):
            print("ROOT %s (marker)" % entry["number"])
            return 0
    level = request.get("rootLevel")
    if level is not None and (not isinstance(level, str) or not level.strip()):
        fail("rootLevel must be a work type name or null")
    if level:
        for entry in chain:
            if eligible(entry) and fold(entry.get("workType")) == fold(level):
                print("ROOT %s (level %s)" % (entry["number"], entry.get("workType")))
                return 0
    plan_root = request.get("planRoot")
    if plan_root is not None and (not isinstance(plan_root, str) or not ROOT_RE.match(plan_root)):
        fail("planRoot must be an item number or null")
    if plan_root and ITEM_RE.match(plan_root) and plan_root not in deferred:
        print("ROOT %s (plan root)" % plan_root)
        return 0
    reasons = ["no argument" if argument is None else "the argument cannot be a root",
               "no marker", "no %s above" % level if level else "no root level",
               "no plan root" if not plan_root else "the plan root cannot be a root"]
    print("ROOT NONE (%s)" % ", ".join(reasons))
    return 0


def cmd_comment(args):
    board = option(args, "--board")
    label = option(args, "--label")
    if len(args) != 1 or args[0] not in ("placed", "removed"):
        fail("usage: comment <placed|removed> [--board <id> --label <text>]")
    if board is not None and not re.match(r"^[A-Za-z0-9-]+$", board):
        fail("--board must be a board id")
    where = "no board." if board is None else "%s (board %s)." % (
        html.escape(label or "a board", quote=False), board)
    if args[0] == "placed":
        text = ("<strong>Active Agents:</strong> placed on the Active Agents board while its plan"
                " is built. Came from: " + where)
    else:
        text = ("<strong>Active Agents:</strong> its plan is finished, so it came off the Active"
                " Agents board. Moved to: " + where)
    print(json.dumps({"html": "<p>%s</p>" % text}))
    return 0


def cmd_came_from(_args):
    request = read_stdin()
    comments = request.get("comments")
    if not isinstance(comments, list):
        fail("comments must be an array")
    placed = [c for c in comments if isinstance(c, dict) and isinstance(c.get("html"), str)
              and PLACED_RE.search(c["html"])]
    if not placed:
        print("FROM NONE (no placement comment)")
        return 0
    newest = max(placed, key=lambda c: str(c.get("dateAdded") or ""))
    match = CAME_FROM_RE.search(newest["html"])
    if not match:
        print("FROM NONE (the placement comment names no board)")
    elif match.group(1):
        print("FROM %s" % match.group(1))
    else:
        print("FROM NONE (it was on no board)")
    return 0


def cmd_settle(_args):
    request = read_stdin()
    remaining = request.get("remaining")
    if isinstance(remaining, bool) or not isinstance(remaining, int) or remaining < 0:
        fail("remaining must be a whole number")
    if remaining:
        print("SETTLE KEEP (%d remaining)" % remaining)
        return 0
    if request.get("onBoard") is not True:
        print("SETTLE KEEP (not on the Active Agents board)")
        return 0
    came = request.get("cameFrom")
    if not isinstance(came, dict) or not came.get("id"):
        print("SETTLE OFF (it came from no board)")
    elif came["id"] == request.get("boardId"):
        print("SETTLE OFF (it came from the Active Agents board itself)")
    elif not came.get("exists"):
        print("SETTLE OFF (the board it came from no longer exists)")
    elif came.get("archived"):
        print("SETTLE OFF (the board it came from is archived)")
    else:
        print("SETTLE MOVE %s" % came["id"])
    return 0


def view_candidates(views):
    if not isinstance(views, list):
        fail("views must be an array")
    out = []
    for v in views:
        if not isinstance(v, dict) or not isinstance(v.get("id"), str):
            fail("every view needs an id")
        label = fold(v.get("label")) or ""
        if v.get("visibility") != "internal" or v.get("location", "board") != "board" \
                or v.get("boardView", "table") != "table":
            continue
        if label == BOARD_LABEL or label.startswith("active agent"):
            out.append(v)
    version = lambda v: v.get("dataVersion") if isinstance(v.get("dataVersion"), int) else 0
    return sorted(out, key=lambda v: (-version(v), v["id"]))


def cmd_pick_view(_args):
    candidates = view_candidates(read_stdin().get("views"))
    if not candidates:
        print("VIEW CREATE")
        return 0
    print("VIEW ADOPT %s" % candidates[0]["id"])
    for v in candidates[1:]:
        print("VIEW DUPLICATE %s" % v["id"])
    return 0


def finding(check, message, severity="FAIL", **extra):
    out = {"check": check, "severity": severity, "message": message}
    out.update(extra)
    return out


def scan_boards(boards):
    if not isinstance(boards, list):
        fail("boards must be an array")
    found = [b["id"] for b in boards if isinstance(b, dict) and isinstance(b.get("id"), str)
             and fold(b.get("label")) == BOARD_LABEL and not b.get("archived")]
    if found:
        return [finding("not-adopted", "an Active Agents board exists but is not adopted; run "
                        "/devstride:setup agents", "INFO", items=found)]
    return [finding("no-board", "no Active Agents board; /devstride:setup agents creates one",
                    "INFO")]


def view_findings(views):
    candidates = view_candidates(views)
    if not candidates:
        return [finding("view", "no shared Active Agents table view", "INFO")]
    out = []
    if len(candidates) > 1:
        out.append(finding("view", "more than one shared Active Agents view; %s is the one in "
                           "use, the rest are for the owner to remove" % candidates[0]["id"],
                           "INFO", items=[v["id"] for v in candidates[1:]]))
    columns = candidates[0].get("columns")
    if isinstance(columns, list):
        shown = {c.get("identifier") for c in columns if isinstance(c, dict)
                 and c.get("visible") is not False}
        hidden = [c for c in STARTING_COLUMNS if c not in shown]
        if hidden:
            out.append(finding("view", "the view does not show: " + ", ".join(hidden), "INFO",
                               items=hidden))
    return out


def cmd_classify(_args):
    request = read_stdin()
    if request.get("configured", True) is False:
        print(json.dumps({"findings": scan_boards(request.get("boards"))}))
        return 0
    findings = []
    board = request.get("board")
    if not isinstance(board, dict) or not board.get("exists"):
        findings.append(finding("board", "the Active Agents board does not exist"))
    elif board.get("archived"):
        findings.append(finding("board", "the Active Agents board is archived"))
    tag = request.get("tag")
    tag_id = tag.get("id") if isinstance(tag, dict) else None
    if not tag_id:
        findings.append(finding("tag", "the agent-active tag does not exist"))
    collections = request.get("labelCollections") or {}
    if not isinstance(collections, dict):
        fail("labelCollections must be an object")
    root_types = request.get("planRootTypes") or []
    for t in root_types:
        if not isinstance(t, dict) or not isinstance(t.get("name"), str):
            fail("every planRootTypes entry needs a name")
    if tag_id:
        missing, ungrouped = [], []
        for t in root_types:
            group = t.get("labelCollectionId")
            if not group:
                ungrouped.append(t["name"])
            elif tag_id not in (collections.get(group) or []):
                missing.append(t["name"])
        if missing:
            findings.append(finding("tag-allowed", "the tag is not allowed on: " + ", ".join(missing),
                                    items=missing))
        if ungrouped:
            findings.append(finding("tag-group", "no tag group, skipped: " + ", ".join(ungrouped),
                                    "INFO", items=ungrouped))
    level = request.get("rootLevel")
    if isinstance(level, str) and level.strip() and root_types \
            and fold(level) not in {fold(t["name"]) for t in root_types}:
        findings.append(finding("root-level", "activeAgents.rootLevel %r names no work type above "
                                "the leaves" % level, items=[level]))
    leaves = set(request.get("leafTypes") or [])
    on_board = [i for i in request.get("boardItems") or [] if isinstance(i, dict)]
    leaf_items = [i["number"] for i in on_board if i.get("workType") in leaves and i.get("number")]
    if leaf_items:
        findings.append(finding("leaf-on-board", "%d leaf item(s) on the board" % len(leaf_items),
                                items=leaf_items[:5], count=len(leaf_items)))
    finished = [i["number"] for i in on_board if i.get("number")
                and i.get("workType") not in leaves and i.get("remaining") == 0
                and not isinstance(i.get("remaining"), bool)]
    if finished:
        findings.append(finding("done-on-board", "plan root(s) on the board with nothing left to "
                                "build: " + ", ".join(finished), items=finished))
    done_roots = [i["number"] for i in request.get("taggedItems") or []
                  if isinstance(i, dict) and i.get("done") and i.get("number")]
    if done_roots:
        findings.append(finding("tag-on-done", "the tag sits on Done item(s)", items=done_roots))
    if "views" in request:
        findings.extend(view_findings(request.get("views")))
    print(json.dumps({"findings": findings}))
    return 0


def main():
    commands = {"validate": cmd_validate, "merge-labels": cmd_merge_labels, "render": cmd_render,
                "run": cmd_run, "resolve-root": cmd_resolve_root, "comment": cmd_comment,
                "came-from": cmd_came_from, "settle": cmd_settle, "pick-view": cmd_pick_view,
                "classify": cmd_classify}
    if len(sys.argv) < 2 or sys.argv[1] not in commands:
        fail("usage: active-agents.py validate|merge-labels|render|run|resolve-root|comment|"
             "came-from|settle|pick-view|classify …")
    sys.exit(commands[sys.argv[1]](sys.argv[2:]))


if __name__ == "__main__":
    main()
