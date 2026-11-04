#!/usr/bin/env python3
"""The Active Agents block — validate it, merge a tag into a tag group, render and run its
commands, classify board drift. Deterministic and dependency-free.

The single implementation behind `skills/setup/references/agents-mode.md` (setup agents),
`skills/doctor/references/agents.md` (doctor agents) and
`skills/build-item/references/active-agents.md` (the build loop's board placement and commands).

  validate [--config <path>]
      -> line 1: ACTIVE AGENTS: VALID | NOT CONFIGURED | INVALID (<n>)
         VALID: line 2 is the effective block, defaults filled, as JSON.
         INVALID: one `ERROR activeAgents.<key>: <problem>` line per problem.
         Exit 0 valid or not configured, 1 invalid, 2 unreadable config.
  merge-labels   stdin {"labels": [<id>…], "tag": "<id>"}
      -> {"change": bool, "added": […], "before": […], "after": […]}  (existing order kept)
  render <start|end> <root> [--config <path>]
      -> the command with `<root>` replaced; a root that is not ^[IF][0-9]+$ is refused.
  run <start|end> <root> [--config <path>] [--timeout <seconds>]
      -> one line: ACTIVE AGENTS <verb>: DONE | FAILED <reason> | NOT CONFIGURED. Runs from the
         repository root with ACTIVE_AGENTS_ROOT, ACTIVE_AGENTS_TAG and
         ACTIVE_AGENTS_STALE_MINUTES exported; always exit 0 (presence never blocks a turn),
         except 2 for a refused root or a bad verb.
  classify   stdin {"board": {"exists", "archived"} | null, "boardItems": [{"number",
             "workType", "done"}], "leafTypes": […], "tag": {"id"} | null,
             "planRootTypes": [{"name", "labelCollectionId"}], "labelCollections": {"<id>": [<label
             id>…]}, "taggedItems": [{"number", "workType", "done"}]}
      -> {"findings": [{"check", "message", "items"?: […]}…]}; an empty list is a clean board.

Bad input exits 2 with one `{"error": …}` line. `--config` defaults to
`.claude/ds-config.json` under the repository root.
"""
import json
import os
import re
import signal
import subprocess
import sys
import tempfile

DEFAULTS = {"boardId": None, "tagName": "agent active", "tagColor": "green", "staleMinutes": 20}
COLOURS = ("gray-medium-dark", "red", "pink", "orange", "yellow", "lime", "green", "teal", "blue",
           "blue-medium", "purple")  # create_label's colours; the registry carries the same enum
KEYS = set(DEFAULTS) | {"commands"}
ROOT_RE = re.compile(r"^[IF][0-9]+$")


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
    """(block, problems): block None when absent or null."""
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
    stale = block.get("staleMinutes", DEFAULTS["staleMinutes"])
    if isinstance(stale, bool) or not isinstance(stale, int) or stale < 1:
        problems.append("ERROR activeAgents.staleMinutes: must be a positive whole number")
    commands = block.get("commands")
    if not isinstance(commands, dict):
        problems.append("ERROR activeAgents.commands: must be an object with start and end")
    else:
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


def cmd_classify(_args):
    request = read_stdin()
    findings = []
    board = request.get("board")
    if not isinstance(board, dict) or not board.get("exists"):
        findings.append({"check": "board", "message": "the Active Agents board does not exist"})
    elif board.get("archived"):
        findings.append({"check": "board", "message": "the Active Agents board is archived"})
    tag = request.get("tag")
    tag_id = tag.get("id") if isinstance(tag, dict) else None
    if not tag_id:
        findings.append({"check": "tag", "message": "the agent-active tag does not exist"})
    collections = request.get("labelCollections") or {}
    if not isinstance(collections, dict):
        fail("labelCollections must be an object")
    if tag_id:
        missing, ungrouped = [], []
        for t in request.get("planRootTypes") or []:
            if not isinstance(t, dict) or not isinstance(t.get("name"), str):
                fail("every planRootTypes entry needs a name")
            group = t.get("labelCollectionId")
            if not group:
                ungrouped.append(t["name"])
            elif tag_id not in (collections.get(group) or []):
                missing.append(t["name"])
        if missing:
            findings.append({"check": "tag-allowed", "items": missing,
                             "message": "the tag is not allowed on: " + ", ".join(missing)})
        if ungrouped:
            findings.append({"check": "tag-group", "items": ungrouped,
                             "message": "no tag group, skipped: " + ", ".join(ungrouped)})
    leaves = set(request.get("leafTypes") or [])
    on_board = [i for i in request.get("boardItems") or [] if isinstance(i, dict)]
    leaf_items = [i["number"] for i in on_board if i.get("workType") in leaves and i.get("number")]
    if leaf_items:
        findings.append({"check": "leaf-on-board", "items": leaf_items[:5], "count": len(leaf_items),
                         "message": "%d leaf item(s) on the board" % len(leaf_items)})
    done_roots = [i["number"] for i in request.get("taggedItems") or []
                  if isinstance(i, dict) and i.get("done") and i.get("number")]
    if done_roots:
        findings.append({"check": "tag-on-done", "items": done_roots,
                         "message": "the tag sits on Done item(s)"})
    print(json.dumps({"findings": findings}))
    return 0


def main():
    commands = {"validate": cmd_validate, "merge-labels": cmd_merge_labels, "render": cmd_render,
                "run": cmd_run, "classify": cmd_classify}
    if len(sys.argv) < 2 or sys.argv[1] not in commands:
        fail("usage: active-agents.py validate|merge-labels|render|run|classify …")
    sys.exit(commands[sys.argv[1]](sys.argv[2:]))


if __name__ == "__main__":
    main()
