#!/usr/bin/env python3
"""hooks/run-watch.py — a workflow run is driven only where its step agents can be heard, and a
turn that ends while one of the session's runs has a step nothing is running is held once.

An agent that has ended its turn drives nothing: what it started in the background reports to a
conversation that is not driving the run, and the run sits at an issued step with nothing to say so.

  pre   (PreToolUse, tools Skill, Agent and Task)
        - Skill: a run-driving skill (devstride:release, plan, run-workflow, branch-hotfix or
          rebalance, one leading "/" allowed) called by a helper agent (the payload carries
          agent_id) is refused: it runs only in the session's main conversation.
        - Agent (or Task, its older name): a step agent (devstride:workflow-steps or
          devstride:workflow-judgement) started with run_in_background true is refused, whoever
          starts it: step agents run in the foreground, so their answer and any prompt they hit
          come back to the driver.
        A refusal is {"hookSpecificOutput": {"hookEventName": "PreToolUse",
        "permissionDecision": "deny", "permissionDecisionReason": <why>}}; anything else, silence.
  stop  (Stop) silent for a helper agent, a turn already held (stop_hook_active), a session a
        person stopped on the Agent Fleet, a payload that carries no background_tasks list (the
        host cannot say what runs), or while an agent, workflow, script or cloud session of the
        session still runs (any other type, a shell included, does not count; the hold names it).
        Otherwise it reads the session's unfinished runs (the step runner's `status`, all of them;
        then each candidate's own `status` for its attempt) and holds the turn once, as
        {"decision": "block", "reason": <what to do>}, for:
          - a running run whose issued step is not waiting: nothing runs it;
          - a running run whose step reported `wait`, when no background task but a teammate runs
            (a teammate's entry reads running all session, busy or not);
          - a run stopped for the person's answer (kind needs-person): so its question is shown.
        A run bound to another checkout (a helper agent's) is named with it, and never driven here.
        Each is held once per run, step, attempt (and stop reason), recorded in
        ${XDG_CACHE_HOME:-~/.cache}/devstride-plugin/run-watch/<session>.json, owner-only and
        written whole BEFORE the hold is printed: a hold that cannot be recorded is not made.

FAILS OPEN: it always exits 0, and any error, a runner that is missing, fails, takes more than three
seconds or answers something unreadable means silence. python3 and the standard library only.
"""
import json
import os
import re
import secrets
import stat
import subprocess
import sys
import time

sys.dont_write_bytecode = True  # never leave compiled files in the installed plugin
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUNNER = os.path.join(ROOT, "skills/run-workflow/scripts/workflow.py")
PAYLOAD_LIMIT = 4 * 1048576
SESSION_ID = re.compile(r"^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$")
DRIVERS = frozenset("devstride:" + name for name in ("release", "plan", "run-workflow", "branch-hotfix", "rebalance"))
STEP_AGENTS = frozenset(("devstride:workflow-steps", "devstride:workflow-judgement"))
AGENT_TOOLS = ("Agent", "Task")
# background_tasks types that can carry a run on (Claude Code names a subagent `subagent`, a
# workflow `workflow`, a script `code` and a cloud session `cloud session`; the internal names are
# kept for versions that show them). A shell, a monitor, a teammate or a type not listed here never
# silences the hold, and every one but a teammate is named in it.
ALIVE = frozenset(("subagent", "workflow", "code", "cloud session",
                   "local_agent", "local_workflow", "local_script", "remote_agent"))
LISTED = ("running", "pending")
RUNNER_SECONDS = 3.0
KEPT = 200

DRIVER_REFUSED = (
    "%s drives a workflow run, and runs only in the session's main conversation, never inside an "
    "agent: what an agent starts, and any question it asks, report to that agent and not to the "
    "conversation driving the run, so the run stalls with nobody to carry it on. Hand back to the main conversation and ask it to run "
    "the skill there; do not drive the run by any other means. If you took the release-train claim "
    "for this start, release it now (the release_claim tool, or the release command the "
    "repository's claims block names), or hand the START back to the conversation that started you.")
STEP_AGENT_REFUSED = (
    "%s runs in the foreground, so its answer and any prompt it hits come back to the driver of the "
    "run. Start it again with run_in_background false.")


def read_payload():
    sys.stdin.reconfigure(encoding="utf-8", errors="replace")
    payload = json.loads(sys.stdin.read(PAYLOAD_LIMIT) or "{}")
    return payload if isinstance(payload, dict) else {}


def pre(payload):
    """The refusal of a run-driving skill inside an agent or a step agent in the background, or None."""
    tool, given = payload.get("tool_name"), payload.get("tool_input")
    given = given if isinstance(given, dict) else {}
    if tool == "Skill" and payload.get("agent_id"):
        name = given.get("skill")
        name = name[1:] if isinstance(name, str) and name.startswith("/") else name
        if name in DRIVERS:
            return DRIVER_REFUSED % name
    if tool in AGENT_TOOLS and given.get("subagent_type") in STEP_AGENTS and given.get("run_in_background") is True:
        return STEP_AGENT_REFUSED % given["subagent_type"]
    return None


def runner(request, cwd, deadline):
    """One read-only runner command's answer, or None on anything but exit 0 with a JSON object."""
    left = deadline - time.monotonic()
    if left <= 0 or not os.path.isfile(RUNNER):
        return None
    try:
        done = subprocess.run([sys.executable, "-B", RUNNER, "status"], input=json.dumps(request),
                              capture_output=True, text=True, encoding="utf-8", errors="replace",
                              timeout=left, cwd=cwd)
        answer = json.loads(done.stdout) if done.returncode == 0 else None
    except (OSError, ValueError, subprocess.SubprocessError):
        return None
    return answer if isinstance(answer, dict) else None


def candidates(session, cwd, quiet):
    """[(key, kind, row, attempt)] for the runs to hold, or None when the runner cannot say."""
    deadline = time.monotonic() + RUNNER_SECONDS
    listing = runner({"all": True, "session": session}, cwd, deadline)
    if listing is None or not isinstance(listing.get("runs"), list):
        return None
    found = []
    for row in listing["runs"]:
        if not isinstance(row, dict) or not isinstance(row.get("runId"), str) or not isinstance(row.get("position"), dict):
            continue
        stopped = row.get("stopped") if isinstance(row.get("stopped"), dict) else {}
        if row.get("state") == "running":
            kind = "waiting" if row.get("waiting") else "issued"
            if kind == "waiting" and not quiet:
                continue  # something still runs: the waiting step may be its command
        elif row.get("state") == "stopped" and stopped.get("kind") == "needs-person":
            kind = "question"
        else:
            continue
        detail = runner({"runId": row["runId"], "session": session}, cwd, deadline)
        if detail is None:
            return None
        step = row["position"].get("stepId")
        attempt = next((r.get("attempt") for r in detail.get("rows") or [] if isinstance(r, dict) and r.get("stepId") == step), None)
        key = "%s:%s:%s" % (row["runId"], step, attempt)
        if kind == "waiting":
            key += ":waiting"
        elif kind == "question":
            key += ":" + str(stopped.get("reason"))
        found.append((key, kind, row, attempt))
    return found


def marker_dir():
    base = os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
    parent = os.path.join(base, "devstride-plugin")
    folder = os.path.join(parent, "run-watch")
    os.makedirs(parent, mode=0o700, exist_ok=True)
    os.makedirs(folder, mode=0o700, exist_ok=True)
    info = os.lstat(folder)
    if not stat.S_ISDIR(info.st_mode) or (hasattr(os, "getuid") and (info.st_uid != os.getuid() or info.st_mode & 0o022)):
        raise OSError("untrusted folder")
    return folder


def held_keys(path):
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except FileNotFoundError:
        return []
    with os.fdopen(fd, encoding="utf-8", errors="replace") as handle:
        text = handle.read(1048576)
    try:
        kept = json.loads(text).get("held")
    except (ValueError, AttributeError):
        return []  # damaged: written whole again below
    return [key for key in kept if isinstance(key, str)] if isinstance(kept, list) else []


def record(folder, path, keys):
    temporary = os.path.join(folder, ".%s.tmp" % secrets.token_hex(8))
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(json.dumps({"held": keys[-KEPT:]}) + "\n")
    os.replace(temporary, path)


def one_line(text, limit):
    text = " ".join(str(text).split())
    return text if len(text) <= limit else text[:limit - 1] + "…"


def checkout_top(start):
    """The checkout a folder is in: the nearest folder holding .git (a folder, or a worktree's file), or None."""
    here = os.path.realpath(start)
    while not os.path.exists(os.path.join(here, ".git")):
        parent = os.path.dirname(here)
        if parent == here:
            return None
        here = parent
    return here


def elsewhere(row, cwd):
    """The checkout a run is bound to when it is not this one, else None (also when this one is not known).
    Checkouts are compared, never folders: a run started at the top and a session that has since gone
    into a subfolder are in the same one. Outside any checkout the folders themselves are compared.
    A bound folder that is gone is always another: walking up from it would reach an enclosing checkout
    (a worktree removed from inside the main one) and call the run that checkout's own."""
    bound = row.get("cwd")
    if not cwd or not isinstance(bound, str) or not bound:
        return None
    if not os.path.isdir(bound):
        return bound
    tops = checkout_top(bound), checkout_top(cwd)
    if None not in tops:
        return bound if tops[0] != tops[1] else None
    if tops == (None, None) and os.path.realpath(bound) != os.path.realpath(cwd):
        return bound
    return None  # only one of them is in a checkout: which one is meant cannot be told, so never "leave it"


def reason(held, running, cwd):
    lines = ["No agent, workflow or script of this session is running now, and these workflow runs have not moved on:"]
    away = False
    for _, kind, row, attempt in held:
        at = row["position"]
        name = "%s, run %s" % (one_line(str(row.get("workflow") or row.get("workflowId")).replace("Workflow: ", "", 1), 80), row["runId"])
        if isinstance(row.get("item"), str):
            name += " for %s" % one_line(row["item"], 40)
        bound = elsewhere(row, cwd)
        if bound:
            name += " (checkout %s, %s)" % (one_line(bound, 200), "not this one" if os.path.isdir(bound) else "which no longer exists")
            away = True
        where = "step %s (%s of %s, attempt %s)" % (at.get("stepId"), at.get("index"), at.get("of"), attempt)
        if kind == "issued":
            lines.append("- %s: %s was handed out and nothing is running it." % (name, where))
        elif kind == "waiting":
            lines.append("- %s: %s reported it is waiting (%s), and nothing of this session runs now."
                         % (name, where, one_line(row.get("waiting"), 120)))
        else:
            lines.append("- %s: stopped at %s for the person's answer (%s)." % (name, where, one_line(row["stopped"].get("reason"), 160)))
    kinds = set(kind for _, kind, _, _ in held)
    if kinds & {"issued", "waiting"}:
        lines.append("For a step handed out or left waiting, first: if the person asked this conversation to pause, "
                     "stop or leave that run, or its step waits on the person's answer to a question already shown to "
                     "them, end the turn again, saying so in one line (which question). A wait on anything else (a "
                     "deploy, a test run, a review) is no reason to end the turn once nothing runs it: read that "
                     "work's own result (the exit status and output of the background task that ran it, or the "
                     "deploy or review by its own id; the run's status keeps only the wait's reason) and carry the "
                     "run on.")
        if running:
            lines.append("These background tasks still run: %s. If one is that step's own work, report wait for the "
                         "step with it as the reason and end the turn instead." % "; ".join(running))
        if away:
            lines.append("A run bound to another checkout is never driven from here: tell the person in one line which "
                         "run and checkout it is, and leave it.")
        lines.append("Otherwise drive it now, here, through the skill that started the run (it resumes by run id: "
                     "status with all, then next, then run the issued step), and tell the person in one line that it "
                     "had stopped. Never start a step a second time.")
    if "question" in kinds:
        lines.append("For a run stopped for the person: if its question has not been shown to them in this conversation, "
                     "show it now; otherwise end the turn.")
    lines.append("This hold is never a yes: it approves nothing.")
    return "\n".join(lines)


def stop(payload):
    """The hold's reason, or None."""
    session = payload.get("session_id")
    if payload.get("agent_id") or payload.get("stop_hook_active") is True or not isinstance(session, str) or not SESSION_ID.match(session):
        return None
    sys.path.insert(0, os.path.join(ROOT, "skills/build-item/scripts"))
    import session_stop
    if session_stop.read(session) is not None:
        return None  # a person stopped this session on the Agent Fleet: nothing is to go on
    tasks = payload.get("background_tasks")
    if not isinstance(tasks, list):
        return None  # a host that does not list its tasks cannot say that nothing runs
    tasks = [t for t in tasks if isinstance(t, dict) and t.get("status") in LISTED]
    if any(t.get("type") in ALIVE for t in tasks):
        return None
    cwd = payload.get("cwd") if isinstance(payload.get("cwd"), str) and os.path.isdir(payload["cwd"]) else None
    found = candidates(session, cwd, not any(t.get("type") != "teammate" for t in tasks))
    if not found:
        return None
    folder = marker_dir()
    path = os.path.join(folder, session + ".json")
    kept = held_keys(path)
    held = [entry for entry in found if entry[0] not in kept]
    if not held:
        return None
    record(folder, path, [key for key in kept if key not in [entry[0] for entry in held]] + [entry[0] for entry in held])
    running = [("shell command `%s`" if t.get("type") == "shell" else one_line(t.get("type"), 40) + " `%s`")
               % one_line(t.get("command") or t.get("description") or "", 200)
               for t in tasks if t.get("type") != "teammate"][:5]
    return reason(held, running, cwd)


def main(argv):
    try:
        mode = argv[0] if argv else None
        payload = read_payload()
        if mode == "pre":
            why = pre(payload)
            if why:
                sys.stdout.write(json.dumps({"hookSpecificOutput": {
                    "hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": why}}) + "\n")
        elif mode == "stop":
            why = stop(payload)
            if why:
                sys.stdout.write(json.dumps({"decision": "block", "reason": why}) + "\n")
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
