#!/usr/bin/env python3
"""Shapes what the build loop reports about the workflow it follows: which step it is on and what
each step produced. Standard library only, no network: it prints the one call the agent then makes
(or a reason to make none) and remembers a little per-run state. The step runner builds every
report with `build_report_arguments`; the rule for sending them is in
`skills/build-item/references/workflow-reports.md`.

A module first and a command line second. Importing it runs nothing, reads no state, no clock and
no environment variable; later tools load it by file path and call these functions directly:

  canonical_json(obj) -> bytes            definition_hash(definition) -> str
  normalize_repository(url) -> str|None   clean_verdict(s) -> str
  clean_evidence(lines) -> list[str]      clean_links(links) -> dict
  build_report_arguments(run_id, session_id, reports, *, item_number=None, repository=None,
                         definition=None, run=None, now=None) -> dict

Commands (JSON out on stdout; exit 0, or 2 with one `workflow-report:` line on stderr for bad input):

  workflow_report.py repository [--dir <path>]            {"repository": "host/owner/name" | null}
  workflow_report.py definition [--file <path>] [--canonical]   {"id", "version", "hash", "bytes"}
  workflow_report.py payload     reads {"config", "item", "reports", "run"?, "now"?} on stdin; prints
                                 {"skip": "<reason>"} or {"via": "provider"|"commands", "call": {...}}
  workflow_report.py outcome     reads {"item", "answer"} on stdin; prints {"action": "continue"} for any JSON object

State: one JSON file per session and item under DEVSTRIDE_WORKFLOW_STATE_DIR, else
<temp dir>/devstride-workflows-<user id>, a folder that must be the caller's own. When it cannot be
kept the helper carries on without it and says so with "stateKept": false. Whatever goes wrong,
`payload` prints a skip and `outcome` prints its one line: neither ever stops the loop.
"""
import datetime
import hashlib
import json
import math
import os
import re
import stat
import subprocess
import sys
import tempfile

MAX_SAFE_INTEGER = 2 ** 53 - 1
MAX_REPORTS = 4
MAX_ATTEMPT = 50
VERDICT_MAX = 200
EVIDENCE_LINE_MAX = 1000
EVIDENCE_MAX_LINES = 40
EVIDENCE_MAX_BYTES = 8192
EVIDENCE_DROPPED = "… more evidence not sent"
BRANCH_MAX = 300
LINK_MAX = 500
RAN_TEXT_MAX = 200
REPOSITORY_MAX = 300
STATUSES = ("running", "done", "failed", "waiting", "skipped")
FINISHED = ("done", "failed", "skipped")
# landed, handed-up and shipped only where the tracker said it accepts them: the runner decides (`tracker_outcome`).
RUN_OUTCOMES = ("completed", "failed", "interrupted", "ended-early", "landed", "handed-up", "shipped")
WAITING_ON = ("person",)
ERROR_KINDS = ("ABSENT", "FORBIDDEN", "UNREACHABLE", "ERROR")
OFF_WORDS = ("0", "false", "off", "no")
LINK_KEYS = ("pullRequest", "commit", "comment")
RUN_SOURCES = ("builtin", "library", "repo", "off")

CONTROL = re.compile(r"[\x00-\x1f\x7f]")
SEGMENT = re.compile(r"^[a-z0-9._-]+$")
ITEM = re.compile(r"^I[0-9]+$")
ISO = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$")
LINK = re.compile(r"^https?://([A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?)(?::([0-9]{1,5}))?(?:[/?#]\S*)?$", re.I)
SESSION_MAX = 200
SCHEME = re.compile(r"^([a-z][a-z0-9+.-]*)://(.*)$", re.I)
SCP = re.compile(r"^(?:[^@/\s]+@)?([^:/\s@]{2,}):(.+)$")
HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
DEFAULT_DEFINITION = os.path.join(PLUGIN_ROOT, "workflows", "build.json")


# --- pure functions -------------------------------------------------------------------------

def _refuse_numbers(value, path="$"):
    if isinstance(value, bool) or value is None or isinstance(value, str):
        return
    if isinstance(value, float):
        raise ValueError("%s: a %s is not allowed; use whole numbers" % (
            path, "non-finite number" if not math.isfinite(value) else "float"))
    if isinstance(value, int):
        if abs(value) > MAX_SAFE_INTEGER:
            raise ValueError("%s: an integer above 2^53-1 is not allowed" % path)
        return
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str):
                raise ValueError("%s: every key must be a string" % path)
            _refuse_numbers(item, "%s.%s" % (path, key))
        return
    if isinstance(value, (list, tuple)):
        for index, item in enumerate(value):
            _refuse_numbers(item, "%s[%d]" % (path, index))
        return
    raise ValueError("%s: not a JSON value" % path)


def canonical_json(obj):
    """The canonical form: keys sorted by code point, no spaces, non-ASCII left as it is, UTF-8."""
    _refuse_numbers(obj)
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def definition_hash(definition):
    """Lower-case hex sha256 of the canonical form: the one name of a workflow definition."""
    return hashlib.sha256(canonical_json(definition)).hexdigest()


def normalize_repository(url):
    """`host/owner/name` in lower case from a git remote address, or None for anything refused.
    No scheme, no user or password, no port, no trailing `.git` or slash."""
    if not isinstance(url, str):
        return None
    text = url.strip()
    if not text or CONTROL.search(text) or " " in text:
        return None
    scheme = SCHEME.match(text)
    if scheme:
        if scheme.group(1).lower() not in ("https", "http", "ssh", "git", "git+ssh"):
            return None
        authority, _, path = scheme.group(2).partition("/")
        host = authority.rsplit("@", 1)[-1]
        host = re.sub(r":[0-9]*$", "", host)
    else:
        scp = SCP.match(text)
        if not scp or text.startswith((".", "~")) or re.match(r"^[A-Za-z]:\\", text):
            return None
        host, path = scp.group(1), scp.group(2)
    path = re.sub(r"\.git$", "", path.strip("/").lower())
    segments = [host.lower()] + [part for part in path.split("/")]
    if not 3 <= len(segments) <= 6 or not all(SEGMENT.match(part) and part.strip(".") for part in segments):
        return None
    name = "/".join(segments)
    return name if len(name) <= REPOSITORY_MAX else None


def _one_line(value):
    """One line of plain text: control characters and half-characters gone, white space collapsed."""
    value = value.encode("utf-8", "replace").decode("utf-8")
    return re.sub(r"\s+", " ", CONTROL.sub(" ", value)).strip()


def _units(value):
    """Length as the receiving side counts it: UTF-16 code units, where an emoji is two."""
    return len(value.encode("utf-16-le")) // 2


def _clip(value, limit):
    while _units(value) > limit:
        value = value[:-1]
    return value


def _cut(value, limit):
    return value if _units(value) <= limit else _clip(value, limit - 1).rstrip() + "…"


def clean_verdict(s):
    """The first line, control characters turned into spaces, white space collapsed, at most 200."""
    if not isinstance(s, str):
        return ""
    for line in re.split(r"[\r\n]+", s):
        cleaned = _one_line(line)
        if cleaned:
            return _cut(cleaned, VERDICT_MAX)
    return ""


def clean_evidence(lines):
    """At most 40 lines of at most 1000 characters and 8,192 UTF-8 bytes in all; when anything is
    dropped the last kept line says so."""
    if isinstance(lines, str):
        lines = [lines]
    if not isinstance(lines, (list, tuple)):
        return []
    cleaned = [_cut(_one_line(line), EVIDENCE_LINE_MAX) for line in lines if isinstance(line, str)]
    cleaned = [line for line in cleaned if line]
    kept, used = [], 0
    for line in cleaned:
        size = len(line.encode("utf-8"))
        if len(kept) == EVIDENCE_MAX_LINES or used + size > EVIDENCE_MAX_BYTES:
            break
        kept.append(line)
        used += size
    if len(kept) < len(cleaned):
        marker = len(EVIDENCE_DROPPED.encode("utf-8"))
        while kept and (len(kept) >= EVIDENCE_MAX_LINES or used + marker > EVIDENCE_MAX_BYTES):
            used -= len(kept.pop().encode("utf-8"))
        kept.append(EVIDENCE_DROPPED)
    return kept


def _clean_link(value):
    if not isinstance(value, str) or CONTROL.search(value) or value != _one_line(value) or _units(value) > LINK_MAX:
        return None
    match = LINK.match(value)
    if not match or "\\" in value or (match.group(2) and int(match.group(2)) > 65535):
        return None
    host = match.group(1)
    if re.match(r"^[0-9.]+$", host) and not (re.match(r"^[0-9]{1,3}(\.[0-9]{1,3}){3}$", host) and all(int(p) <= 255 for p in host.split("."))):
        return None
    return value


def clean_links(links):
    """Web addresses the step produced (http or https, no user or password, at most 500) and its
    branch name (at most 300). Anything else is dropped."""
    out = {}
    if not isinstance(links, dict):
        return out
    for key in LINK_KEYS:
        link = _clean_link(links.get(key))
        if link:
            out[key] = link
    branch = links.get("branch")
    if isinstance(branch, str) and _one_line(branch):
        out["branch"] = _clip(_one_line(branch), BRANCH_MAX)
    return out


def _clean_ran(ran):
    if not isinstance(ran, dict) or ran.get("source") not in RUN_SOURCES:
        return None
    out = {"source": ran["source"]}
    for key in ("ref", "version", "hash"):
        value = ran.get(key)
        if isinstance(value, str) and _one_line(value):
            out[key] = _clip(_one_line(value), RAN_TEXT_MAX)
    return out


def _iso(moment):
    return moment.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (moment.microsecond // 1000)


def _is_time(value):
    if not isinstance(value, str) or not ISO.match(value):
        return False
    try:
        datetime.datetime.strptime(value[:19], "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return False
    return True


def _time(value, fallback):
    return value if _is_time(value) else fallback


def _now(now):
    if _is_time(now):
        return now
    if isinstance(now, datetime.datetime):
        return _iso(now if now.tzinfo else now.replace(tzinfo=datetime.timezone.utc))
    return _iso(datetime.datetime.now(datetime.timezone.utc))


def build_report_arguments(run_id, session_id, reports, *, item_number=None, repository=None,
                           definition=None, run=None, now=None):
    """The exact arguments of `record_workflow_step`. `definition` is included only when passed:
    whether the platform already holds it is the caller's knowledge, never this function's."""
    reports = list(reports or [])
    if len(reports) > MAX_REPORTS:
        raise ValueError("at most %d reports in one call" % MAX_REPORTS)
    moment = None
    shaped = []
    for report in reports:
        if not isinstance(report, dict):
            raise ValueError("a report is an object")
        step = report.get("step", report.get("stepId"))
        status = report.get("status")
        if not isinstance(step, str) or not step:
            raise ValueError("a report names its step")
        if status not in STATUSES:
            raise ValueError("unknown status: %r" % (status,))
        attempt = report.get("attempt", 1)
        if isinstance(attempt, bool) or not isinstance(attempt, int) or not 1 <= attempt <= MAX_ATTEMPT:
            raise ValueError("an attempt is a whole number from 1 to %d" % MAX_ATTEMPT)
        moment = moment or _now(now)
        out = {"stepId": step, "attempt": attempt, "status": status}
        verdict = clean_verdict(report.get("verdict"))
        if not verdict and status != "running":
            verdict = status.capitalize()
        if verdict:
            out["verdict"] = verdict
        evidence = clean_evidence(report.get("evidence"))
        if evidence:
            out["evidence"] = evidence
        links = clean_links(report.get("links"))
        if links:
            out["links"] = links
        out["startedAt"] = _time(report.get("startedAt"), moment)
        if _time(report.get("endedAt"), None) or status in FINISHED:
            out["endedAt"] = _time(report.get("endedAt"), moment)
        ran = _clean_ran(report.get("ran"))
        if ran:
            out["ran"] = ran
        if status == "waiting" and report.get("waitingOn") in WAITING_ON:
            out["waitingOn"] = report["waitingOn"]  # a person was asked; any other wait names itself in its verdict
        shaped.append(out)
    arguments = {"runId": run_id, "sessionId": _clip(_one_line(str(session_id)), SESSION_MAX)}
    if isinstance(item_number, str) and ITEM.match(item_number):
        arguments["itemNumber"] = item_number
    if repository:
        arguments["repository"] = repository
    if definition is not None:
        arguments["definition"] = definition
    if shaped:
        arguments["reports"] = shaped
    if run is not None:
        if not isinstance(run, dict) or run.get("outcome") not in RUN_OUTCOMES:
            raise ValueError("a run closes as completed, failed, interrupted, landed, handed-up, shipped or ended-early")
        arguments["run"] = {"outcome": run["outcome"], "endedAt": _time(run.get("endedAt"), moment or _now(now))}
    return arguments


# --- the command line: state, the clock, the environment and git live only below ------------

class Usage(Exception):
    pass


def _state_dir(env):
    """The caller's own folder: named for the user, so a shared temporary directory is never
    shared state."""
    given = env.get("DEVSTRIDE_WORKFLOW_STATE_DIR")
    if given:
        return given
    user = os.getuid() if hasattr(os, "getuid") else "user"
    return os.path.join(tempfile.gettempdir(), "devstride-workflows-%s" % user)


def _state_path(env, session, item):
    name = hashlib.sha256(("%s|%s" % (session, item or "-")).encode("utf-8")).hexdigest()[:16]
    return os.path.join(_state_dir(env), name + ".json")


def _clean_state(state):
    """Only what this helper writes survives a read: a state file is data, never trusted."""
    if not isinstance(state, dict):
        return {}
    out = {}
    if isinstance(state.get("nonce"), str) and re.match(r"^[0-9a-f]{0,32}$", state["nonce"]):
        out["nonce"] = state["nonce"]
    for key in ("closed", "closing", "definitionReceived", "available"):
        if isinstance(state.get(key), bool):
            out[key] = state[key]
    steps = {}
    for step, last in (state.get("steps") if isinstance(state.get("steps"), dict) else {}).items():
        if (isinstance(step, str) and isinstance(last, dict) and last.get("status") in STATUSES
                and isinstance(last.get("attempt"), int) and not isinstance(last.get("attempt"), bool)
                and 1 <= last["attempt"] <= MAX_ATTEMPT and isinstance(last.get("startedAt"), str)
                and _is_time(last["startedAt"])):
            steps[step] = {"attempt": last["attempt"], "status": last["status"], "startedAt": last["startedAt"]}
    out["steps"] = steps
    return out


def _own_folder(folder):
    """True for a real directory that belongs to the caller: never a link, never someone else's."""
    info = os.lstat(folder)
    return stat.S_ISDIR(info.st_mode) and (not hasattr(os, "getuid") or info.st_uid == os.getuid())


def _load_state(env, session, item):
    try:
        if not _own_folder(_state_dir(env)):
            return {}
        with open(_state_path(env, session, item), encoding="utf-8") as handle:
            return _clean_state(json.load(handle))
    except Exception:
        return {}


def _save_state(env, session, item, state):
    """Best effort: a helper that cannot remember carries on, it never fails. The folder must be
    this user's own and private, and the file is written beside its final name, then moved."""
    try:
        folder = _state_dir(env)
        os.makedirs(folder, mode=0o700, exist_ok=True)
        if not _own_folder(folder):
            return False
        if os.lstat(folder).st_mode & 0o077:
            os.chmod(folder, 0o700)
        handle, temporary = tempfile.mkstemp(dir=folder, suffix=".tmp")
        try:
            with os.fdopen(handle, "w") as out:
                json.dump(state, out)
            os.replace(temporary, _state_path(env, session, item))
        except Exception:
            try:
                os.unlink(temporary)
            except OSError:
                pass
            return False
        return True
    except Exception:
        return False


def _run_id(session, item, nonce):
    return hashlib.sha256(("%s|%s|%s" % (session, item or "-", nonce)).encode("utf-8")).hexdigest()[:32]


def _session(env):
    sys.path.insert(0, HERE)
    import claim_record
    return claim_record.session_id(env), claim_record.plugin_version()


def _read_definition(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except OSError as error:
        raise Usage("cannot read %s: %s" % (path, error.strerror or error))
    except (ValueError, RecursionError):
        raise Usage("%s is not JSON" % path)


def _stdin_object():
    if sys.stdin is None or sys.stdin.isatty():
        raise Usage("this command reads one JSON object on stdin")
    try:
        value = json.loads(sys.stdin.read())
    except (ValueError, RecursionError):
        raise Usage("the input on stdin is not JSON")
    if not isinstance(value, dict):
        raise Usage("the input on stdin must be one JSON object")
    return value


def read_repository(folder="."):
    """The remote named origin, else the only remote, normalized; None when there is none."""
    def git(*args):
        try:
            out = subprocess.run(["git", "-C", folder] + list(args), capture_output=True, text=True, encoding="utf-8",
                                 errors="replace", timeout=5)
        except Exception:
            return None
        return out.stdout.strip() if out.returncode == 0 else None
    remotes = (git("remote") or "").split()
    name = "origin" if "origin" in remotes else (remotes[0] if len(remotes) == 1 else None)
    return normalize_repository(git("remote", "get-url", name)) if name else None


def _off(config, env):
    return config is None or config is False or (env.get("DEVSTRIDE_WORKFLOWS") or "").strip().lower() in OFF_WORDS


def _via(config):
    commands = config.get("commands") if isinstance(config, dict) else None
    return "commands" if isinstance(commands, dict) and isinstance(commands.get("report"), str) and commands["report"].strip() else "provider"


def _item(body):
    return body.get("item") if isinstance(body.get("item"), str) and ITEM.match(body["item"]) else None


def command_payload(env):
    body = _stdin_object()
    if "config" not in body:
        raise Usage("payload needs `config` ({} when the key is absent, null when it is off)")
    config = body["config"]
    reports = body.get("reports") or []
    if not isinstance(reports, list) or any(not isinstance(r, dict) or not isinstance(r.get("step"), str) or not r.get("step") for r in reports):
        raise Usage("every report is an object that names its step")
    if any(r.get("status") not in STATUSES for r in reports):
        raise Usage("a report's status is one of %s" % ", ".join(STATUSES))
    closing = body.get("run")
    if closing is not None and (not isinstance(closing, dict) or closing.get("outcome") not in RUN_OUTCOMES):
        raise Usage("a run closes as completed, failed, interrupted, landed, handed-up, shipped or ended-early")
    if _off(config, env):
        return {"skip": "off"}
    session, version = _session(env)
    if not session:
        return {"skip": "no-session"}
    if len(reports) > MAX_REPORTS:
        return {"skip": "too-many-reports"}
    item = _item(body)
    state = _load_state(env, session, item)
    if state.get("closed") or (state.get("closing") and not closing):
        # The last run ended (or its closing call was never answered): this is a new run.
        state = {}
    kept = True
    if "nonce" not in state:
        # A new run. Its id is random when it can be remembered, so a later run of the same item
        # never reuses it; when nothing can be kept it is derived, so one run keeps one id.
        state = {"nonce": os.urandom(8).hex(), "steps": {}}
        kept = _save_state(env, session, item, state)
        if not kept:
            state["nonce"] = ""
    if state.get("available") is False:
        if closing:
            _save_state(env, session, item, dict(state, closed=True))
        return {"skip": "unavailable"}
    # A step the definition does not have is left out; the other reports and the close still go.

    definition = _read_definition(DEFAULT_DEFINITION)
    steps = {step["id"]: step for phase in definition.get("phases", []) for step in phase.get("steps", [])}
    moment = _now(body.get("now"))
    remembered = dict(state.get("steps", {}))
    shaped, unknown = [], False
    for report in reports:
        step, status = report["step"], report["status"]
        if step not in steps:
            unknown = True
            continue
        last = remembered.get(step, {})
        attempt = report.get("attempt")
        if isinstance(attempt, bool) or not isinstance(attempt, int):
            attempt = last.get("attempt", 1)
            if last.get("status") in FINISHED and status != last.get("status"):
                attempt += 1
        if not 1 <= attempt <= MAX_ATTEMPT:
            return {"skip": "too-many-attempts"}
        same = last.get("attempt") == attempt
        started = _time(report.get("startedAt"), (last.get("startedAt") if same else None) or moment)
        remembered[step] = {"attempt": attempt, "status": status, "startedAt": started}
        run = steps[step].get("run", {})
        ran = {"source": run.get("source"), "ref": run.get("ref"), "version": version}
        shaped.append(dict(report, step=step, attempt=attempt, startedAt=started, ran=report.get("ran") or ran))
    send_definition = not state.get("definitionReceived")
    if not shaped and not closing and (unknown or not send_definition):
        return {"skip": "unknown-step" if unknown else "nothing-to-send"}
    try:
        arguments = build_report_arguments(
            _run_id(session, item, state["nonce"]), session, shaped, item_number=item,
            repository=read_repository("."), definition=definition if send_definition else None,
            run=closing, now=moment)
    except ValueError as error:
        raise Usage(str(error))
    state["steps"] = remembered
    if closing:
        state["closing"] = True  # closed once the answer says the call was taken
    if kept:
        kept = _save_state(env, session, item, state)
    out = {"via": _via(config), "call": {"tool": "record_workflow_step", "arguments": arguments}}
    if not kept:
        out["stateKept"] = False
    return out


def _failed(answer):
    """An answer that says the report was not taken: nothing at all, an error kind, or a
    command's first line other than OK."""
    if isinstance(answer, dict):
        return "error" in answer or answer.get("isError") is True
    if isinstance(answer, str):
        return (answer.strip().splitlines() or [""])[0].strip() != "OK"
    return not isinstance(answer, list)


def command_outcome(env):
    body = _stdin_object()
    session, _ = _session(env)
    if session:
        item = _item(body)
        state = _load_state(env, session, item)
        answer = body.get("answer")
        if "nonce" not in state or state.get("closed"):
            pass  # no open run to record an answer for
        elif isinstance(answer, dict) and answer.get("outcome") == "DEFINITION_REQUIRED" and not _failed(answer):
            state["definitionReceived"] = False  # the same run sends again, definition included
            _save_state(env, session, item, state)
        else:
            if _failed(answer):
                state["available"] = False
            else:
                state["definitionReceived"] = True
                state["available"] = True
            if state.get("closing"):
                state["closed"] = True
            _save_state(env, session, item, state)
    return {"action": "continue"}


def command_definition(argv):
    path, canonical = DEFAULT_DEFINITION, False
    while argv:
        flag = argv.pop(0)
        if flag == "--file" and argv:
            path = argv.pop(0)
        elif flag == "--canonical":
            canonical = True
        else:
            raise Usage("usage: workflow_report.py definition [--file <path>] [--canonical]")
    document = _read_definition(path)
    try:
        text = canonical_json(document)
    except (ValueError, UnicodeError, RecursionError) as error:
        raise Usage(str(error))
    described = document if isinstance(document, dict) else {}
    out = {"id": described.get("id"), "version": described.get("version"),
           "hash": definition_hash(document), "bytes": len(text)}
    if canonical:
        out["canonical"] = text.decode("utf-8")
    return out


def main(argv, env=None):
    env = os.environ if env is None else env
    command, rest = (argv[0] if argv else None), list(argv[1:])
    try:
        if command == "repository" and (not rest or (len(rest) == 2 and rest[0] == "--dir")):
            out = {"repository": read_repository(rest[1] if rest else ".")}
        elif command == "definition":
            out = command_definition(rest)
        elif command == "payload" and not rest:
            out = command_payload(env)
        elif command == "outcome" and not rest:
            out = command_outcome(env)
        else:
            raise Usage("usage: workflow_report.py repository [--dir <path>] | definition [--file <path>] [--canonical] | payload | outcome")
    except Usage as error:
        print("workflow-report: %s" % error, file=sys.stderr)
        return 2
    except Exception:
        # Fail open: whatever went wrong here must never stop, slow or speak over the loop.
        out = {"action": "continue"} if command == "outcome" else {"skip": "error"}
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
