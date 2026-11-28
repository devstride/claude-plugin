#!/bin/bash
# scripts/tests/run-scenarios.sh — the shared scenarios (skills/run-workflow/scripts/run-scenarios.json)
# driven through the step runner by scripts/tests/run_scenarios.py: the driver prints the same thing
# every time, every event it prints fits schemas/run-events.schema.json, each run's history is
# numbered from 1 with no hole, and the steps as the events alone show them are the steps the
# runner's own status shows. Everything happens in temporary folders, with an empty environment
# and a home folder made for the test: no key of this machine can be found, and the runner's one
# network call is answered in memory. No network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home"
clean() { env -i PATH="$PATH" HOME="$WORK/home" TMPDIR="$WORK" PYTHONDONTWRITEBYTECODE=1 "$@"; }

clean python3 -B "$ROOT/scripts/tests/run_scenarios.py" > "$WORK/one.json" 2> "$WORK/one.err"; RC1=$?
clean python3 -B "$ROOT/scripts/tests/run_scenarios.py" > "$WORK/two.json" 2> "$WORK/two.err"; RC2=$?
if [ "$RC1" = 0 ] && [ "$RC2" = 0 ] && [ ! -s "$WORK/one.err" ]; then ok "the driver runs the scenarios and says nothing on stderr"
else bad "the driver failed ($RC1, $RC2): $(tail -3 "$WORK/one.err")"; fi
if [ -s "$WORK/one.json" ] && cmp -s "$WORK/one.json" "$WORK/two.json"; then ok "two runs of the driver print the same bytes"
else bad "two runs of the driver differ"; fi

cat > "$WORK/cases.py" <<'PY'
import copy, importlib.util, json, os, sys

ROOT, WORK = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("run_scenarios", os.path.join(ROOT, "scripts/tests/run_scenarios.py"))
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)
SCHEMA = driver.read_json(driver.SCHEMA)
text = open(os.path.join(WORK, "one.json"), encoding="utf-8").read()
printed = json.loads(text)
scenarios = dict((scenario["name"], scenario) for scenario in printed["scenarios"])
counter = [0]


def check(label, good, detail=""):
    counter[0] += 1
    print(("ok   " if good else "FAIL ") + label + ("" if good else " -> %s" % (detail,)))


check("the three scenarios are a Build run to the end, a stop and resume, and a rewind",
      sorted(scenarios) == ["build-to-the-end", "rewind", "stop-and-resume"], sorted(scenarios))
check("the driver names the plugin version and the catalog by its hash",
      isinstance(printed.get("pluginVersion"), str) and len(printed.get("catalogHash", "")) == 64, printed.get("catalogHash"))
check("nothing printed names a folder on this machine", WORK not in text and "run-scenarios-" not in text and '"cwd"' not in text)

for name, scenario in sorted(scenarios.items()):
    events = scenario["events"]
    faults = [(event["clientSequence"], fault) for event in events for fault in driver.schema_faults(event, SCHEMA)]
    check("%s: every event fits the schema" % name, events and not faults, faults[:3])
    check("%s: the events are numbered from 1 with no hole" % name,
          [event["clientSequence"] for event in events] == list(range(1, len(events) + 1)))
    check("%s: it opens with run-started and ends with run-finished" % name,
          events[0]["type"] == "run-started" and events[-1]["type"] == "run-finished" and scenario["status"]["state"] == "finished",
          (events[0]["type"], events[-1]["type"]))
    commands = [event["payload"].get("command") for event in events]
    check("%s: every event names the command that made it, and the commands only count up" % name,
          all(isinstance(c, dict) and c["n"] >= 1 for c in commands) and [c["n"] for c in commands] == sorted(c["n"] for c in commands), commands[:3])
    first = {}
    for event in events:
        first.setdefault(event["payload"]["command"]["n"], event["clientSequence"])
    check("%s: what a command read is on its first event only" % name,
          all(first[event["payload"]["command"]["n"]] == event["clientSequence"] for event in events if "observed" in event["payload"]))
    started = events[0]["payload"]
    check("%s: run-started carries the definition's hash and the catalog's, and the definition goes with it" % name,
          started["definitionHash"] == scenario["definitionHash"] and started["catalogHash"] == printed["catalogHash"]
          and isinstance(scenario["definition"], dict) and "cwd" not in started["context"], started.get("definitionHash"))
    check("%s: nothing is left unsent" % name, scenario["status"]["unsent"] == 0, scenario["status"])
    # The steps as the events alone show them are the steps the runner's own status shows.
    shown = {}
    for row in driver.step_reports(events):
        shown[row["stepId"]] = row
    told = [(row["stepId"], shown[row["stepId"]]["status"], shown[row["stepId"]]["verdict"], shown[row["stepId"]]["attempt"])
            if row["stepId"] in shown else (row["stepId"], "pending", None, 0) for row in scenario["status"]["rows"]]
    held = [(row["stepId"], row["status"], row["verdict"], row["attempt"]) for row in scenario["status"]["rows"]]
    check("%s: the steps the events show are the steps the runner's status shows" % name, told == held, (told, held))
    check("%s: the run's ending, read from the events, is completed" % name, driver.run_ending(events) == "completed")

build = scenarios["build-to-the-end"]["events"]
check("a Build run to the end is one step-issued and one step-answered a step, each on its first attempt",
      [event["type"] for event in build[1:-1]] == ["step-issued", "step-answered"] * 11 and all(event["attempt"] == 1 for event in build[1:-1]))
check("... its item, repository and machine go with the run, and a check that read the checkout says what it saw",
      scenarios["build-to-the-end"]["itemNumber"] == "I123" and scenarios["build-to-the-end"]["repository"] == "example.com/acme/app"
      and scenarios["build-to-the-end"]["machine"] == "scenario-machine"
      and any(event["payload"].get("observed", {}).get("bindings") for event in build), scenarios["build-to-the-end"]["repository"])
stopped = scenarios["stop-and-resume"]["events"]
kinds = [event["type"] for event in stopped]
at = kinds.index("run-stopped")
check("a stop and resume: the failed answer, the stop, the resume, then the same step's second attempt",
      kinds[at - 1:at + 3] == ["step-answered", "run-stopped", "run-resumed", "step-issued"]
      and stopped[at - 1]["payload"]["status"] == "failed" and stopped[at]["payload"]["kind"] == "failed"
      and stopped[at]["payload"]["trackerOutcome"] == "failed" and stopped[at + 2]["stepId"] == "build" and stopped[at + 2]["attempt"] == 2,
      kinds[at - 1:at + 3])
check("... and while it is stopped, the events alone say the run ended failed", driver.run_ending(stopped[:at + 1]) == "failed")
rewound = scenarios["rewind"]["events"]
back = next(event for event in rewound if event["type"] == "run-rewound")
check("a rewind names the step that asked for it, the step it goes back to and the steps run again",
      back["payload"]["fromStepId"] == "post-deploy-status" and back["payload"]["toStepId"] == "post-deploy-check"
      and back["payload"]["resetStepIds"] == ["post-deploy-check"] and scenarios["rewind"]["itemNumber"] is None, back["payload"])
check("... and both steps then run a second attempt",
      [(event["stepId"], event["attempt"]) for event in rewound if event["type"] == "step-issued"][-2:]
      == [("post-deploy-check", 2), ("post-deploy-status", 2)])

# The check itself refuses what the schema refuses: a pass above means something.
good = build[2]


def changed(**change):
    event = copy.deepcopy(good)
    for key, value in change.items():
        target, keys = event, key.split(".")
        for part in keys[:-1]:
            target = target[part]
        if value is KeyError:
            del target[keys[-1]]
        else:
            target[keys[-1]] = value
    return driver.schema_faults(event, SCHEMA)


bad_started = copy.deepcopy(build[0])
bad_started["payload"]["context"]["cwd"] = "somewhere"
refusals = {"an unknown envelope key": changed(sentBy="me"), "a missing payload.command": changed(**{"payload.command": KeyError}),
            "an unknown status": changed(**{"payload.status": "paused"}), "a step event with no stepId": changed(stepId=KeyError),
            "a float": changed(attempt=1.5), "attempt 0": changed(attempt=0), "a verdict line over 200": changed(**{"payload.verdictLine": "x" * 201}),
            "a time with no Z": changed(occurredAt="2026-01-02T03:04:05+00:00"), "an unknown actor": changed(actor="devstride"),
            "a link key that is not one": changed(**{"payload.links": {"wiki": "https://example.com"}}),
            "a context that names cwd": driver.schema_faults(bad_started, SCHEMA)}
check("the schema check refuses each kind of bad event", all(refusals.values()), [name for name, found in refusals.items() if not found])
check("... and takes the good one", not driver.schema_faults(good, SCHEMA))

# The stand-in tracker refuses what the tracker refuses.
tracker = driver.Tracker(SCHEMA)


def refused(arguments):
    try:
        tracker.call(driver.RECORD_TOOL, arguments)
    except driver.Refused:
        return True
    return False


run = {"runId": "r" * 32, "sessionId": "s1", "definition": scenarios["build-to-the-end"]["definition"]}
check("the stand-in tracker asks for the catalog first, then for nothing more",
      tracker.call(driver.RECORD_TOOL, dict(run, events=build[:2])) == {"outcome": "CATALOG_REQUIRED"}
      and "hash" in tracker.call(driver.CATALOG_TOOL, {"catalog": driver.read_json("schemas/step-contracts.json"), "pluginVersion": "1.0.0"})
      and tracker.call(driver.RECORD_TOOL, dict(run, events=build[:2]))["acceptedThrough"] == 2)
check("... a hole is answered OUT_OF_ORDER with the event it expects, and a replay is skipped",
      tracker.call(driver.RECORD_TOOL, dict(run, events=build[3:5])) == {"outcome": "OUT_OF_ORDER", "expectedClientSequence": 3}
      and tracker.call(driver.RECORD_TOOL, dict(run, events=build[0:4]))["acceptedThrough"] == 4)
check("... a run that does not open with run-started, an event the schema refuses and 51 events are tool errors",
      refused({"runId": "q" * 32, "sessionId": "s1", "events": build[1:2], "definition": run["definition"]})
      and refused(dict(run, events=[dict(build[4], sentBy="me")])) and refused(dict(run, events=[build[4]] * 51)))
check("... a first batch with no definition is answered DEFINITION_REQUIRED",
      tracker.call(driver.RECORD_TOOL, {"runId": "p" * 32, "sessionId": "s1", "events": build[:1]}) == {"outcome": "DEFINITION_REQUIRED"})
small = driver.Tracker(SCHEMA, catalogs=[printed["catalogHash"]], limit=3)
check("... and a run that holds all it may is answered HISTORY_FULL",
      small.call(driver.RECORD_TOOL, dict(run, events=build[:5])) == {"outcome": "HISTORY_FULL"} and len(small.events("r" * 32)) == 3)
print("cases: %d" % counter[0])
PY
OUT="$(clean python3 -B "$WORK/cases.py" "$ROOT" "$WORK" 2>&1)"; RC=$?
echo "$OUT" | grep -v '^ok ' | grep -v '^cases: ' | sed 's/^/  /'
RAN="$(echo "$OUT" | grep -c '^ok ')"; FAILED="$(echo "$OUT" | grep -c '^FAIL ')"
if [ "$RC" = 0 ] && [ "$FAILED" = 0 ] && [ "$RAN" -ge 40 ]; then ok "the scenarios hold ($RAN checks)"
else bad "the scenarios: $RAN checks passed, $FAILED failed, exit $RC"; fi

exit "$FAIL"
