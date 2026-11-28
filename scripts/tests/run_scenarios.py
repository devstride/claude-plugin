#!/usr/bin/env python3
"""Drives the step runner, in this process, through the shared scenarios in
skills/run-workflow/scripts/run-scenarios.json, and prints what each run told the tracker.

  python3 scripts/tests/run_scenarios.py            one JSON object on stdout, the same every time

  {"pluginVersion", "catalogHash", "scenarios": [{"name", "runId", "sessionId", "itemNumber",
    "repository", "machine", "definition", "definitionHash", "events", "status"}]}

`events` is the run's whole history in order, each event as schemas/run-events.schema.json shapes
it; `status` is the runner's own last word on the run ({"state", "rows": [{stepId, status, verdict,
attempt}]}). Anything that shows the events to a person must show what `status` says: that is what
the scenarios are for.

Nothing here reaches the network or this user's real folders. Every run lives in a temporary
directory (its own cache folder and git repository), the runner is handed an environment that holds
nothing but that cache folder, and its one network call is replaced by `Tracker`, which answers as
the wire contract says the tracker does, refusals included.

Also a module: the checks under scripts/tests/ load it for `Tracker`, `scripted_world`,
`schema_faults`, `step_reports`, `journaled` and `told`.
"""
import copy
import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RUNNER = "skills/run-workflow/scripts/workflow.py"
SCENARIOS = "skills/run-workflow/scripts/run-scenarios.json"
FIXTURES = "skills/run-workflow/scripts/workflow-fixtures.json"
SCHEMA = "schemas/run-events.schema.json"
RECORD_TOOL, CATALOG_TOOL = "record_workflow_run_events", "put_step_contract_catalog"
ARGUMENT_KEYS = ("runId", "sessionId", "itemNumber", "repository", "machine", "definition", "events")
PAYLOAD_MAX_BYTES, RESULT_MAX_BYTES, DEFINITION_MAX_BYTES, BATCH_MAX, HISTORY_MAX = 32 * 1024, 16 * 1024, 64 * 1024, 50, 5000
# A git that reads no setting of this machine's: the same repository, byte for byte, everywhere.
GIT_ENV = {"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "Scenario", "GIT_AUTHOR_EMAIL": "scenario@example.com",
           "GIT_COMMITTER_NAME": "Scenario", "GIT_COMMITTER_EMAIL": "scenario@example.com",
           "GIT_AUTHOR_DATE": "2026-01-02T03:04:05Z", "GIT_COMMITTER_DATE": "2026-01-02T03:04:05Z", "LC_ALL": "C", "TZ": "UTC"}
DIFF = ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-relative", "--src-prefix=a/", "--dst-prefix=b/",
        "--ignore-submodules=none", "--unified=3", "--no-renames", "--diff-algorithm=myers", "--inter-hunk-context=0"]


def load_runner(root=ROOT, name="workflow_for_scenarios"):
    spec = importlib.util.spec_from_file_location(name, os.path.join(root, RUNNER))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.load_helpers()
    return module


def read_json(path, root=ROOT):
    with open(os.path.join(root, path), encoding="utf-8") as handle:
        return json.load(handle)


# --- a small JSON Schema check: the keywords schemas/run-events.schema.json uses -------------------

def _is(value, name):
    if name == "null":
        return value is None
    if name == "boolean":
        return isinstance(value, bool)
    if name == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if name == "string":
        return isinstance(value, str)
    if name == "array":
        return isinstance(value, list)
    return name == "object" and isinstance(value, dict)


def schema_faults(value, schema, root=None, path="$"):
    """Why `value` does not fit `schema` (a list of lines; empty when it fits). Knows: $ref, type,
    enum, const, required, properties, additionalProperties, items, maxItems, minLength, maxLength,
    pattern, minimum, maximum, oneOf and not. A keyword it does not know is a fault of the schema."""
    root = schema if root is None else root
    known = ("$ref", "type", "enum", "const", "required", "properties", "additionalProperties", "items", "maxItems", "minLength",
             "maxLength", "pattern", "minimum", "maximum", "oneOf", "not", "description", "title", "$schema", "$defs", "$id", "$comment")
    faults = ["%s: the check does not know the keyword %s" % (path, key) for key in schema if key not in known]
    if "$ref" in schema:
        target = root
        for part in schema["$ref"].lstrip("#/").split("/"):
            target = target[part]
        faults += schema_faults(value, target, root, path)
    if "type" in schema:
        wanted = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(_is(value, name) for name in wanted):
            return faults + ["%s: not %s" % (path, " or ".join(wanted))]
    if "enum" in schema and not any(value == option and type(value) is type(option) for option in schema["enum"]):
        faults.append("%s: %r is not one of the listed values" % (path, value))
    if "const" in schema and not (value == schema["const"] and type(value) is type(schema["const"])):
        faults.append("%s: not %r" % (path, schema["const"]))
    if isinstance(value, str):
        units = len(value)  # characters, as JSON Schema and the tracker count them; the runner cuts by the longer UTF-16 count
        if "minLength" in schema and units < schema["minLength"]:
            faults.append("%s: shorter than %d" % (path, schema["minLength"]))
        if "maxLength" in schema and units > schema["maxLength"]:
            faults.append("%s: longer than %d" % (path, schema["maxLength"]))
        if "pattern" in schema and not re.search(schema["pattern"], value):
            faults.append("%s: does not match %s" % (path, schema["pattern"]))
    if isinstance(value, int) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            faults.append("%s: below %d" % (path, schema["minimum"]))
        if "maximum" in schema and value > schema["maximum"]:
            faults.append("%s: above %d" % (path, schema["maximum"]))
    if isinstance(value, list):
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            faults.append("%s: more than %d entries" % (path, schema["maxItems"]))
        if "items" in schema:
            for at, item in enumerate(value):
                faults += schema_faults(item, schema["items"], root, "%s[%d]" % (path, at))
    if isinstance(value, dict):
        faults += ["%s: %s is missing" % (path, key) for key in schema.get("required", []) if key not in value]
        named = schema.get("properties", {})
        for key, item in value.items():
            if key in named:
                faults += schema_faults(item, named[key], root, "%s.%s" % (path, key))
            elif schema.get("additionalProperties") is False:
                faults.append("%s: %s is not a key it may have" % (path, key))
            elif isinstance(schema.get("additionalProperties"), dict):
                faults += schema_faults(item, schema["additionalProperties"], root, "%s.%s" % (path, key))
    if "oneOf" in schema:
        fitting = [at for at, branch in enumerate(schema["oneOf"]) if not schema_faults(value, branch, root, path)]
        if len(fitting) != 1:
            faults.append("%s: fits %d of the %d shapes, not exactly one" % (path, len(fitting), len(schema["oneOf"])))
    if "not" in schema and not schema_faults(value, schema["not"], root, path):
        faults.append("%s: is what it must not be" % path)
    return faults


def whole_numbers(value):
    """True when every number in a value is a whole number the tracker's canonical JSON takes."""
    if isinstance(value, bool) or value is None or isinstance(value, str):
        return True
    if isinstance(value, int):
        return abs(value) <= 2 ** 53 - 1
    if isinstance(value, list):
        return all(whole_numbers(item) for item in value)
    if isinstance(value, dict):
        return all(isinstance(key, str) and whole_numbers(item) for key, item in value.items())
    return False


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


# --- the tracker's side of the wire contract, in memory ----------------------------------------------

class Refused(Exception):
    """A tool error: a validation refusal, an unknown tool, a server that is down."""


class Tracker:
    """Answers the runner's two tools as the tracker does, and refuses what the tracker refuses: an
    event its schema does not allow, a run that does not open with run-started numbered 1, a batch
    out of order or too large. `tools`: the tools this server has (an older one has neither);
    `catalogs`: the catalog hashes it already holds; `limit`: how many events a run may keep;
    `down`: every call fails."""

    def __init__(self, schema=None, tools=(RECORD_TOOL, CATALOG_TOOL), catalogs=(), limit=HISTORY_MAX):
        self.schema = schema or read_json(SCHEMA)
        self.tools, self.catalogs, self.limit = tuple(tools), set(catalogs), limit
        self.runs, self.calls, self.down, self.refusals = {}, [], False, []

    def refuse(self, reason):
        self.refusals.append(reason)
        raise Refused(reason)

    def call(self, tool, arguments):
        self.calls.append((tool, copy.deepcopy(arguments)))
        if self.down:
            raise Refused("unreachable")
        if tool not in self.tools:
            self.refuse("Unknown tool: %s" % tool)
        if tool == CATALOG_TOOL:
            if (not isinstance(arguments, dict) or sorted(arguments) != ["catalog", "pluginVersion"] or not isinstance(arguments["catalog"], dict)
                    or not re.match(r"^[0-9]+\.[0-9]+\.[0-9]+$", str(arguments["pluginVersion"])) or not whole_numbers(arguments["catalog"])):
                self.refuse("the catalog call is {catalog, pluginVersion}")
            digest = hashlib.sha256(canonical(arguments["catalog"])).hexdigest()
            self.catalogs.add(digest)
            return {"hash": digest}
        if not isinstance(arguments, dict) or any(key not in ARGUMENT_KEYS for key in arguments):
            self.refuse("unknown argument")
        run_id, events = arguments.get("runId"), arguments.get("events")
        if not isinstance(run_id, str) or not re.match(r"^[A-Za-z0-9_-]{8,64}$", run_id):
            self.refuse("runId")
        if not isinstance(arguments.get("sessionId"), str) or not 1 <= len(arguments["sessionId"]) <= 200:
            self.refuse("sessionId")
        if "itemNumber" in arguments and not re.match(r"^I[0-9]+$", str(arguments["itemNumber"])):
            self.refuse("itemNumber")
        if "machine" in arguments and not (isinstance(arguments["machine"], str) and 1 <= len(arguments["machine"]) <= 200):
            self.refuse("machine")
        if not isinstance(events, list) or not 1 <= len(events) <= BATCH_MAX:
            self.refuse("a batch is 1 to %d events" % BATCH_MAX)
        for event in events:
            faults = schema_faults(event, self.schema)
            if faults:
                self.refuse("an event its schema does not allow: %s" % "; ".join(faults[:3]))
            if not whole_numbers(event) or len(canonical(event["payload"])) > PAYLOAD_MAX_BYTES:
                self.refuse("an event's payload holds a number that is not whole, or is over its size limit")
            if event["payload"].get("result") is not None and len(canonical(event["payload"]["result"])) > RESULT_MAX_BYTES:
                self.refuse("a result over its size limit")
        numbers = [event["clientSequence"] for event in events]
        if numbers != sorted(set(numbers)):
            self.refuse("a batch's events are in ascending order")
        run = self.runs.get(run_id)
        if run is None:
            if numbers[0] != 1 or events[0]["type"] != "run-started":
                self.refuse("a run's first event is run-started, numbered 1")
            if not isinstance(arguments.get("definition"), dict):
                return {"outcome": "DEFINITION_REQUIRED"}
            if len(canonical(arguments["definition"])) > DEFINITION_MAX_BYTES:
                self.refuse("a definition over its size limit")
            if events[0]["payload"]["catalogHash"] not in self.catalogs:
                return {"outcome": "CATALOG_REQUIRED"}
            run = self.runs[run_id] = dict((key, arguments.get(key)) for key in ARGUMENT_KEYS if key != "events")
            run.update(events=[], batches=[])
        last = run["events"][-1]["clientSequence"] if run["events"] else 0
        taken = []
        for event in events:
            if event["clientSequence"] <= last:
                continue  # a replay: skipped, never compared
            if event["clientSequence"] != last + 1:
                run["events"] += taken
                return {"outcome": "OUT_OF_ORDER", "expectedClientSequence": last + 1}
            if len(run["events"]) + len(taken) >= self.limit:
                run["events"] += taken
                return {"outcome": "HISTORY_FULL"}
            taken.append(copy.deepcopy(event))
            last = event["clientSequence"]
        run["events"] += taken
        run["batches"].append(numbers)
        return {"runId": run_id, "acceptedThrough": last, "sequence": len(run["events"])}

    def events(self, run_id):
        return self.runs[run_id]["events"] if run_id in self.runs else []


def scripted_world(runner, tracker, cache, machine="scenario-machine", environ=None):
    """A World of the runner under test whose one network call is `tracker.call`: an environment
    that names only the cache folder, so no key of this machine can be found, and a fixed machine name."""

    class ScriptedWorld(runner.World):
        def send(self, tool, arguments, cwd=None, seconds=5):
            return tracker.call(tool, json.loads(json.dumps(arguments)))

        def machine(self):
            return machine

        def organization(self, cwd):
            return getattr(tracker, "org", None)  # the organization this stand-in key signs in to

    return ScriptedWorld(env=dict(environ or {}, XDG_CACHE_HOME=cache))


# --- what a person is shown: one row per step and attempt, from the events alone ----------------------

def step_reports(events):
    """The steps as a history's events leave them, in the order each step attempt first appears:
    [{stepId, attempt, status, verdict, evidence, links, ran}]. A step handed out is `running`; one
    waiting inside itself, parked for a person or left open is `waiting`; a step repaired by hand
    after its attempt ended is shown as the next attempt, the way an ended attempt is never changed."""
    rows, order, closed = {}, [], set()
    for event in events:
        if "stepId" not in event:
            continue
        payload, kind = event["payload"], event["type"]
        key = (event["stepId"], event["attempt"])
        if kind == "step-answered" and payload.get("repaired") and key in closed:
            key = (key[0], key[1] + 1)
        if key not in rows:
            rows[key] = {"stepId": key[0], "attempt": key[1], "status": "running", "verdict": None, "evidence": [], "links": {}, "ran": None}
            order.append(key)
        row = rows[key]
        if kind == "step-issued":
            row.update(status="running", ran=payload.get("ran"))
        elif kind == "step-waiting":
            row.update(status="waiting", verdict=payload.get("reason"))
        else:
            status = payload.get("status", "skipped" if payload.get("decision") in ("off", "skipped-by-condition") else "failed")
            row.update(status="waiting" if status in ("parked", "open") else status, verdict=payload["verdictLine"],
                       evidence=payload.get("evidence") or [], links=payload.get("links") or {})
            if payload.get("ran") is not None:
                row["ran"] = payload["ran"]
            if row["status"] in ("done", "failed", "skipped"):
                closed.add(key)
    return [rows[key] for key in order]


def run_ending(events):
    """How the run table names the run's end after these events, or None while it is open: the last
    run-finished or closing run-stopped, undone by a later resume."""
    ending = None
    for event in events:
        if event["type"] == "run-finished":
            ending = event["payload"]["trackerOutcome"]
        elif event["type"] == "run-stopped":
            ending = event["payload"].get("trackerOutcome")
        elif event["type"] in ("run-resumed", "step-issued"):
            ending = None
    return ending


# --- what a run kept on this machine: the outbox files of a cache folder ------------------------------

def outboxes(cache):
    """Every outbox under a cache folder, by file name: what its run journaled and has not sent."""
    folder, found = os.path.join(cache, "devstride-plugin", "workflows"), {}
    for name in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
        if name.endswith(".outbox.json") and not name.startswith("."):
            with open(os.path.join(folder, name), encoding="utf-8") as handle:
                found[name] = json.load(handle)
    return found


def journaled(cache, seen):
    """What each run under a cache folder journaled since the last call with the same `seen` (a
    dict this fills), for a check that drives the runner with no tracker to send to, so nothing
    ever leaves an outbox. One entry a run, a run that was only ended (replaced by a start) first:
    {"runId", "sessionId", "itemNumber"?, "repository"?, "definition"? (with the run's first
    event), "events", "reports" (one row for each event that changes a step, in order: {stepId,
    attempt, status, verdict?, evidence?, links?, ran?, startedAt, endedAt?, waitingOn?}), "run" ({"outcome",
    "endedAt"}, when the events end the run as the run table names it)}."""
    found = []
    for box in outboxes(cache).values():
        fresh = [event for event in box["events"] if (box["runId"], event["clientSequence"]) not in seen]
        if not fresh:
            continue
        entry = {"runId": box["runId"], "sessionId": box["sessionId"], "events": fresh, "reports": []}
        if box.get("item"):
            entry["itemNumber"] = box["item"]
        if box.get("repository"):
            entry["repository"] = box["repository"]
        for event in fresh:
            seen[(box["runId"], event["clientSequence"])] = True
            payload, kind = event["payload"], event["type"]
            if kind == "run-started":
                entry["definition"] = box.get("definition")
            elif kind == "run-finished" or (kind == "run-stopped" and payload.get("trackerOutcome")):
                entry["run"] = {"outcome": payload["trackerOutcome"], "endedAt": event["occurredAt"]}
            elif kind in ("run-resumed", "step-issued"):
                entry.pop("run", None)
            if "stepId" not in event:
                continue
            row = {"stepId": event["stepId"], "attempt": event["attempt"], "startedAt": event["occurredAt"]}
            if kind == "step-issued":
                row.update(status="running")
            elif kind == "step-waiting":
                row.update(status="waiting", verdict=payload.get("reason"))
            else:
                status = payload.get("status", "skipped" if payload.get("decision") in ("off", "skipped-by-condition") else "failed")
                row.update(status="waiting" if status in ("parked", "open") else status, verdict=payload["verdictLine"])
                if row["status"] != "waiting":
                    row["endedAt"] = event["occurredAt"]
                else:
                    # An answer that leaves its step waiting asked a person (a question, a
                    # confirmation, a gate or a checkpoint), as DevStride reads it; a step that
                    # waits inside itself says so with a step-waiting event and names no one.
                    row["waitingOn"] = "person"
                if payload.get("repaired"):
                    # An ended attempt is never changed: a repair by hand is shown as the next one.
                    count = seen[("repaired", box["runId"], event["stepId"], event["attempt"])] = seen.get(
                        ("repaired", box["runId"], event["stepId"], event["attempt"]), 0) + 1
                    row["attempt"] += count
                for key in ("evidence", "links"):
                    if payload.get(key):
                        row[key] = payload[key]
            # What ran a step is said when it is handed out; every later row of that attempt names it too.
            ran = (box["runId"], "ran", event["stepId"], event["attempt"])
            if payload.get("ran") is not None:
                seen[ran] = payload["ran"]
            if ran in seen:
                row["ran"] = seen[ran]
            entry["reports"].append(row)
        found.append(entry)
    return sorted(found, key=lambda entry: 0 if [event["type"] for event in entry["events"]] in (["run-finished"], ["run-started", "run-finished"]) else 1)


def told(answer, cache, seen):
    """A runner's answer with what that one command journaled attached as `reports` (absent when it
    journaled nothing), for a check that has no tracker to send to. The runner itself hands out no
    step reports: an answer of its own that holds the key is an error."""
    if isinstance(answer, dict):
        if "reports" in answer:
            raise AssertionError("the runner handed out step reports: %s" % json.dumps(answer)[:300])
        found = journaled(cache, seen)
        if found:
            answer["reports"] = found
    return answer


# --- the scenarios ---------------------------------------------------------------------------------------

def git(repo, *args, **options):
    env = dict(GIT_ENV, PATH=os.environ.get("PATH", ""), HOME=os.path.dirname(repo))
    done = subprocess.run(["git", "-C", repo, "-c", "commit.gpgsign=false", "-c", "core.hooksPath=" + os.devnull] + list(args),
                          capture_output=True, input=options.get("stdin"), env=env)
    if done.returncode != 0:
        raise RuntimeError("git %s: %s" % (" ".join(args), done.stderr.decode("utf-8", "replace")))
    return done.stdout


def scenario_repository(folder, remote):
    """A repository on a branch called feature, one commit ahead of main, the same bytes every time."""
    repo = os.path.join(folder, "repo")
    os.makedirs(repo)
    git(repo, "init", "-q", "--initial-branch=main")
    for name, text, message in (("readme.txt", "one\n", "first"), ("export.txt", "export\n", "add the export")):
        with open(os.path.join(repo, name), "w", encoding="utf-8") as out:
            out.write(text)
        git(repo, "add", "-A")
        git(repo, "commit", "-q", "-m", message)
        if name == "readme.txt":
            git(repo, "symbolic-ref", "refs/remotes/origin/main", "refs/heads/main")
            git(repo, "checkout", "-q", "-b", "feature")
    git(repo, "remote", "add", "origin", remote)
    return repo


def repository_facts(repo):
    diff = git(repo, *(DIFF + ["main...HEAD", "--"]))
    patch = git(repo, "patch-id", "--verbatim", stdin=diff).decode().split()
    return {"head": git(repo, "rev-parse", "HEAD").decode().strip(), "tree": git(repo, "rev-parse", "HEAD^{tree}").decode().strip(),
            "patchId": patch[0] if patch else ""}


def run_scenario(runner, scenario, shared, outputs, tracker, folder, number):
    """One scenario: its commands in order, each one second after the last. Returns what it printed about the run."""
    repo = scenario_repository(folder, shared["remote"])
    facts = repository_facts(repo)
    world = scripted_world(runner, tracker, os.path.join(folder, "cache"), shared["machine"])
    definition = read_json(os.path.join("workflows", scenario["workflow"]))
    session, clock, answer, run_id = shared["session"], [0], None, None

    def call(command, request):
        request = dict(request, session=session, now="2026-01-02T03:%02d:%02d.000Z" % (number, clock[0]))
        clock[0] += 1
        return runner.run_command(command, request, world)

    for entry in scenario["commands"]:
        command = entry["command"]
        if command == "start":
            answer = call("start", {"definition": definition, "context": dict(scenario["context"], cwd=repo)})
            run_id = answer["runId"]
            continue
        request = {"runId": run_id}
        if command == "done":
            step = (answer or {}).get("step") or {}
            if answer.get("action") != "run" or step.get("id") != entry["step"]:
                raise RuntimeError("%s: the run is at %s, not at %s" % (scenario["name"], json.dumps(answer)[:200], entry["step"]))
            text = entry.get("output", outputs.get(step["contract"]))
            if text is None:
                raise RuntimeError("%s: no answer is written for %s" % (scenario["name"], step["contract"]))
            for key, value in facts.items():
                text = text.replace("{%s}" % key, value)
            request.update(stepId=step["id"], attempt=step["attempt"], output=text)
        else:
            request.update(entry.get("request", {}))
        answer = call(command, request)
        if entry.get("expect") and answer.get("action") != entry["expect"]:
            raise RuntimeError("%s: %s answered %s, not %s" % (scenario["name"], command, answer.get("action"), entry["expect"]))
    status = call("status", {"runId": run_id})
    kept = tracker.runs[run_id]
    return {"name": scenario["name"], "runId": run_id, "sessionId": kept["sessionId"], "itemNumber": kept.get("itemNumber"),
            "repository": kept.get("repository"), "machine": kept.get("machine"), "definition": kept["definition"],
            "definitionHash": runner.REPORT.definition_hash(kept["definition"]), "events": kept["events"],
            "status": {"state": status["state"], "unsent": status["history"]["unsent"],
                       "rows": [dict((key, row[key]) for key in ("stepId", "status", "verdict", "attempt")) for row in status["rows"]]}}


def run_all(root=ROOT):
    runner = load_runner(root)
    counter = [0]

    def token_hex(size=16):
        counter[0] += 1  # the run ids and temporary names a scenario makes are the same every time
        return hashlib.sha256(("scenario-%d" % counter[0]).encode("utf-8")).hexdigest()[:2 * size]

    shared, outputs = read_json(SCENARIOS, root), read_json(FIXTURES, root)["outputs"]
    tracker = Tracker(read_json(SCHEMA, root))
    work = tempfile.mkdtemp(prefix="run-scenarios-")
    real_token, real_environ = runner.secrets.token_hex, dict(os.environ)
    try:
        runner.secrets.token_hex = token_hex
        # The runner's own git reads no setting of this machine's either, and finds no key of its user.
        os.environ.update(GIT_ENV, HOME=work)
        found = []
        for number, scenario in enumerate(shared["scenarios"]):
            folder = os.path.join(work, "scenario-%d" % number)
            os.makedirs(folder)
            found.append(run_scenario(runner, scenario, shared, dict(outputs, **shared.get("outputs", {})), tracker, folder, number))
    finally:
        runner.secrets.token_hex = real_token
        os.environ.clear()
        os.environ.update(real_environ)
        shutil.rmtree(work, ignore_errors=True)
    return {"pluginVersion": runner.CLAIMS.plugin_version(runner.PLUGIN_ROOT), "catalogHash": runner.catalog_hash(), "scenarios": found}


def main():
    sys.stdout.write(json.dumps(run_all(), sort_keys=True, indent=1, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
