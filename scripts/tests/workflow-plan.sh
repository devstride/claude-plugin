#!/bin/bash
# scripts/tests/workflow-plan.sh — the Plan and Rebalance workflows (workflows/plan.json and
# workflows/rebalance.json) against the real step runner and catalog: both definitions validate,
# their step ids and phases are the pinned ones, every contract is as published, the creation and
# write-order floors are refused when a copy drops, reorders or switches them off, and a run with
# canned answers stops, asks and ends where each step's verdict says. A step skill is prose run by
# a model; this proves the runner's sequence, stops and proofs, not what a model does in a step.
# Everything lives in a temporary directory. No network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export PYTHONDONTWRITEBYTECODE=1
unset CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID XDG_CACHE_HOME GIT_DIR GIT_WORK_TREE

cat > "$WORK/cases.py" <<'PY'
import copy, importlib.util, json, os, subprocess, sys

ROOT, WORK = sys.argv[1], sys.argv[2]
RUNNER = os.path.join(ROOT, "skills/run-workflow/scripts/workflow.py")
CATALOG = json.load(open(os.path.join(ROOT, "schemas/step-contracts.json"), encoding="utf-8"))["contracts"]
FILES = dict((w, os.path.join(ROOT, "workflows", w + ".json")) for w in ("plan", "rebalance"))
DEFS = dict((w, json.load(open(f, encoding="utf-8"))) for w, f in FILES.items())
spec = importlib.util.spec_from_file_location("runner_under_test", RUNNER)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
runner.load_helpers()
PLUGIN = json.load(open(os.path.join(ROOT, ".claude-plugin/plugin.json"), encoding="utf-8"))["version"]
n = [0]


def check(label, good, detail=""):
    print(("ok   " if good else "FAIL ") + label + ("" if good else " -> %r" % (detail,)))


def steps(definition):
    return [s for p in definition["phases"] for s in p["steps"]]


PLAN_PHASES = [("orient", ["session-check", "orient", "ground"]), ("discover", ["discover", "record-sign-off"]),
               ("draft", ["draft-specs", "confirm-drafts"]),
               ("build", ["create-items", "wire-edges", "rationalize-dates", "number-titles"]), ("hand-off", ["hand-off"])]
REBALANCE_PHASES = [("safety", ["session-check", "gates"]), ("read", ["ground", "partition"]), ("propose", ["propose"]),
                    ("write", ["scheduler-probe", "create-successors", "rewire", "renumber", "archive-originals", "rewrite-marker", "redate"]),
                    ("report", ["report"])]
CONTRACTS = {
    "plan": ["session-model@1", "plan-orient@1", "plan-ground@1", "plan-discovery@1", "plan-sign-off-record@1", "plan-draft@1",
             "plan-draft-approval@1", "plan-create@1", "plan-wire@1", "rationalize-gantt@1", "plan-number@1", "plan-hand-off@1"],
    "rebalance": ["session-model@1", "rebalance-gates@1", "plan-ground@1", "rebalance-partition@1", "rebalance-proposal@1",
                  "rebalance-probe@1", "rebalance-successors@1", "rebalance-rewire@1", "rebalance-renumber@1", "rebalance-archive@1",
                  "rebalance-marker@1", "rationalize-gantt@1", "rebalance-report@1"],
}
# What was published, value by value: the skill, each verdict and its class, and the requirements.
PUBLISHED = {
    "session-model@1": ("plan-steps", "SESSION MODEL: MATCH=continue | UNKNOWN=continue | OFF=continue | MISMATCH=ask | MISMATCH UNATTENDED=continue", []),
    "plan-orient@1": ("plan-steps", "PLAN ORIENTATION: READY=continue | NEEDS ANSWER=ask | FAILED=stop", []),
    "plan-ground@1": ("comprehend-plan", "PLAN STATE: EMPTY=continue | PARTIAL=continue | SHALLOW=continue | FAILED=stop", []),
    "plan-discovery@1": ("plan-steps", "PLAN SHAPE: SIGNED OFF=continue | SIGNED OFF WITH ASSUMPTIONS=continue | NOT SIGNED OFF=ask", ["plan-orient@1", "plan-ground@1"]),
    "plan-sign-off-record@1": ("plan-steps", "SIGN-OFF RECORDED: RECORDED=continue | LINK MODE ON=ask | FAILED=stop", ["plan-discovery@1"]),
    "plan-draft@1": ("plan-steps", "PLAN DRAFTED: DRAFTED=continue | FAILED=stop", ["plan-sign-off-record@1"]),
    "plan-draft-approval@1": ("plan-steps", "PLAN DRAFT REVIEW: APPROVED=continue | NOT APPROVED=ask", ["plan-draft@1"]),
    "plan-create@1": ("plan-steps", "PLAN CREATED: CREATED=continue | PARTIAL=stop | FAILED=stop", ["plan-sign-off-record@1", "plan-draft-approval@1"]),
    "plan-wire@1": ("plan-steps", "PLAN WIRED: WIRED=continue | ORPHANS=stop | FAILED=stop", ["plan-create@1"]),
    "rationalize-gantt@1": ("rationalize-gantt", "GANTT: DATED=continue | CYCLE=stop | SCHEDULER ON=ask | FAILED=stop", ["plan-wire@1"]),
    "plan-number@1": ("plan-steps", "PLAN NUMBERED: NUMBERED=continue | EXTENDED=continue | ALREADY NUMBERED=continue | UNNUMBERED PLAN KEPT=continue | FAILED=stop", ["rationalize-gantt@1"]),
    "plan-hand-off@1": ("plan-steps", "PLAN HANDED OFF: HANDED OFF=continue | ANOTHER ROUND WANTED=end:another-round", ["plan-number@1"]),
    "rebalance-gates@1": ("plan-steps", "REBALANCE GATES: CLEAR=continue | BUILD LOOP ACTIVE=stop | SCHEDULER ON=ask | BAD ARGUMENTS=ask", []),
    "rebalance-partition@1": ("plan-steps", "REBALANCE PARTITION: PARTITIONED=continue | NO CHANGE NEEDED=ask", ["rebalance-gates@1", "plan-ground@1"]),
    "rebalance-proposal@1": ("plan-steps", "REBALANCE PROPOSAL: SIGNED OFF=continue | DRY RUN=end:dry-run | DECLINED=end:declined", ["rebalance-partition@1"]),
    "rebalance-probe@1": ("plan-steps", "SCHEDULER PROBE: HELD=continue | OVERWRITTEN=stop | LOOP ACTIVE=stop", ["rebalance-proposal@1"]),
    "rebalance-successors@1": ("plan-steps", "REBALANCE SUCCESSORS: CREATED=continue | FAILED=stop", ["rebalance-probe@1"]),
    "rebalance-rewire@1": ("plan-steps", "REBALANCE REWIRE: DONE=continue | ORPHANS=stop | FAILED=stop", ["rebalance-successors@1"]),
    "rebalance-renumber@1": ("plan-steps", "REBALANCE RENUMBER: DONE=continue | UNNUMBERED PLAN KEPT=continue | FAILED=stop", ["rebalance-rewire@1"]),
    "rebalance-archive@1": ("plan-steps", "REBALANCE ARCHIVE: ARCHIVED=continue | FAILED=stop", ["rebalance-renumber@1"]),
    "rebalance-marker@1": ("plan-steps", "REBALANCE MARKER: REWRITTEN=continue | FAILED=stop", ["rebalance-archive@1"]),
    "rebalance-report@1": ("plan-steps", "REBALANCE REPORT: RE-SLICED=continue | FAILED=stop", ["rationalize-gantt@1"]),
}

# --- the two definitions, as shipped -----------------------------------------------------------
for wid, phases in (("plan", PLAN_PHASES), ("rebalance", REBALANCE_PHASES)):
    d = DEFS[wid]
    check("%s: header fields (on-demand, no end, empty appliesTo, version 1)" % wid,
          (d["schema"], d["id"], d["version"], d["startsWhen"], d["endsBy"], d["appliesTo"]) ==
          (1, wid, 1, "on-demand", None, {"workTypes": [], "tags": [], "repositories": []}), d)
    check("%s: the phases and step ids are the pinned ones" % wid,
          [(p["id"], [s["id"] for s in p["steps"]]) for p in d["phases"]] == phases, [(p["id"], [s["id"] for s in p["steps"]]) for p in d["phases"]])
    check("%s: each step runs the pinned contract with its contract's built-in skill, always, stopping on failure" % wid,
          [(s["contract"], s["run"]["source"], s["run"]["ref"], s["when"]["mode"], s["onFail"], s["kind"]) for s in steps(d)] ==
          [(c, "builtin", CATALOG[c]["builtinSkill"], "always", "stop", "step") for c in CONTRACTS[wid]])
    try:
        check("%s: the runner accepts it" % wid, len(runner.validate_definition(d, CATALOG, PLUGIN, True)) == len(CONTRACTS[wid]))
    except runner.Refuse as error:
        check("%s: the runner accepts it" % wid, False, str(error))
    check("%s: no step ever lists insert-story or insert-defect" % wid, not any(s["run"]["ref"] in ("insert-story", "insert-defect") for s in steps(d)))
check("twelve plan steps and thirteen rebalance steps", (len(steps(DEFS["plan"])), len(steps(DEFS["rebalance"]))) == (12, 13))

for name, want in PUBLISHED.items():
    e = CATALOG.get(name)
    said = e and (e["builtinSkill"], "%s: %s" % (e["verdict"]["label"], " | ".join("%s=%s" % (v["value"], v["class"]) for v in e["verdict"]["values"])), e["requires"])
    check("%s is as published" % name, said == want, said)
check("plan-draft@1 is the only delegating contract", sorted(n for n, e in CATALOG.items() if e.get("delegates")) == ["plan-draft@1"])
check("the three interactive contracts", sorted(n for n, e in CATALOG.items() if e.get("interactive")) ==
      ["plan-discovery@1", "plan-draft-approval@1", "rebalance-proposal@1"])
check("dating accepts a verified rebalance rewire in place of the plan's wiring", CATALOG["plan-wire@1"].get("satisfiedBy") == ["rebalance-rewire@1"])
check("every plan-steps contract's argument begins with its mode",
      all(e["argument"].startswith(n.split("@")[0] + " ") for n, e in CATALOG.items() if e["builtinSkill"] == "plan-steps"))
check("the sign-off, the draft approval and the two wirings each carry their proof kind",
      dict((n, CATALOG[n]["proof"]["values"]["kind"]) for n in ("plan-sign-off-record@1", "plan-draft-approval@1", "plan-wire@1", "rebalance-rewire@1"))
      == {"plan-sign-off-record@1": ["sign-off"], "plan-draft-approval@1": ["draft-approval"], "plan-wire@1": ["wired-plan"], "rebalance-rewire@1": ["wired-plan"]})

rule = " ".join(open(os.path.join(ROOT, "skills/release/references/step-skills.md"), encoding="utf-8").read().split())
check("the step-skill rule carries the delegates and interactive amendments",
      "**`delegates: true`** (only `plan-draft@1`)" in rule and "**`interactive: true`**" in rule and "It still never asks a flow question." in rule)

# --- the floors: a copy that drops, reorders or switches off a required step is refused --------
def start(definition):
    n[0] += 1
    cache = os.path.join(WORK, "cache%d" % n[0])
    os.makedirs(cache)
    repo = os.path.join(WORK, "repo%d" % n[0])
    os.makedirs(repo)
    subprocess.run(["git", "init", "-q", repo], check=True)
    env = dict((k, v) for k, v in os.environ.items() if k not in ("CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID"))
    env["XDG_CACHE_HOME"] = cache
    request = {"definition": definition, "context": {"item": "I100", "cwd": repo}, "session": "s%d" % n[0]}
    done = subprocess.run([sys.executable, "-B", RUNNER, "start"], input=json.dumps(request), capture_output=True, text=True, env=env, cwd=repo)
    return done.returncode, done.stdout, done.stderr, cache, repo, env


def without(definition, step_id):
    copy_ = copy.deepcopy(definition)
    for p in copy_["phases"]:
        p["steps"] = [s for s in p["steps"] if s["id"] != step_id]
    copy_["phases"] = [p for p in copy_["phases"] if p["steps"]]
    return copy_


def edited(definition, step_id, change):
    copy_ = copy.deepcopy(definition)
    for s in steps(copy_):
        if s["id"] == step_id:
            change(s)
    return copy_


def moved_before(definition, step_id, before_id):
    copy_ = copy.deepcopy(definition)
    found = None
    for p in copy_["phases"]:
        for s in list(p["steps"]):
            if s["id"] == step_id:
                found = s
                p["steps"].remove(s)
    for p in copy_["phases"]:
        for i, s in enumerate(p["steps"]):
            if s["id"] == before_id:
                p["steps"].insert(i, found)
                return copy_


def refused(label, definition):
    rc, out, err, *_ = start(definition)
    check(label, rc == 2, (rc, out[:200], err[:200]))


plan = DEFS["plan"]
for step_id in ("record-sign-off", "confirm-drafts", "wire-edges"):
    refused("plan without %s is refused" % step_id, without(plan, step_id))
    refused("plan with %s carrying on after a failure is refused" % step_id, edited(plan, step_id, lambda s: s.update(onFail="continue")))
    refused("plan with %s switched off is refused" % step_id, edited(plan, step_id, lambda s: s["run"].update(source="off")))
refused("plan with create-items before the sign-off is refused", moved_before(plan, "create-items", "record-sign-off"))
refused("plan with create-items before the draft approval is refused", moved_before(plan, "create-items", "confirm-drafts"))
refused("plan with the dating step before the wiring is refused", moved_before(plan, "rationalize-dates", "wire-edges"))
refused("plan with the wiring made conditional is refused", edited(plan, "wire-edges", lambda s: s["when"].update(mode="manual")))
reb = DEFS["rebalance"]
order = ["scheduler-probe", "create-successors", "rewire", "renumber", "archive-originals", "rewrite-marker", "redate", "report"]
for earlier, later in zip(order, order[1:]):
    if (earlier, later) == ("rewrite-marker", "redate"):
        continue  # the shared dating step requires a verified wiring, not the marker (next case)
    refused("rebalance with %s before %s is refused" % (later, earlier), moved_before(reb, later, earlier))
    refused("rebalance without %s is refused" % earlier, without(reb, earlier))
refused("rebalance with the dating step before the rewire is refused", moved_before(reb, "redate", "rewire"))
rc, *_ = start(reb)
check("rebalance with the rewire before the dating step, as shipped, is accepted", rc == 0)


# --- runs with canned answers ------------------------------------------------------------------
class Run:
    def __init__(self, definition):
        self.rc, out, err, self.cache, self.repo, self.env = start(definition)
        self.answer = json.loads(out) if self.rc == 0 else None
        self.issued = [self.answer["step"]["id"]] if self.answer and self.answer.get("action") == "run" else []

    def call(self, command, request):
        request = dict(request, session="s%d" % n[0])
        done = subprocess.run([sys.executable, "-B", RUNNER, command], input=json.dumps(request), capture_output=True, text=True,
                              env=self.env, cwd=self.repo)
        self.answer = json.loads(done.stdout) if done.returncode == 0 else {"rc": done.returncode, "err": done.stderr}
        if self.answer.get("action") == "run":
            self.issued.append(self.answer["step"]["id"])
        return self.answer

    def done(self, verdict, result=None, proof=None):
        step = self.answer["step"]
        entry = CATALOG[step["contract"]]
        body = dict((k, default(t)) for k, t in entry["result"]["types"].items())
        body.update(result or {})
        if proof is None and entry["proof"].get("required"):
            proof = dict((k, entry["proof"]["values"].get(k, [default(t)])[0]) for k, t in entry["proof"]["types"].items())
        if proof is not None:
            body["proof"] = proof
        output = "%s\nevidence\n```json\n%s\n```\n" % (verdict, json.dumps(body))
        return self.call("done", {"item": "I100", "stepId": step["id"], "attempt": step["attempt"], "output": output})

    def resume(self, **extra):
        return self.call("resume", dict({"item": "I100"}, **extra))


def default(types):
    first = types.split("|")[0]
    return {"string": "x", "number": 0, "count": 0, "boolean": False, "array": [], "object": {}, "null": None}[first]


CLEAN = {
    "session-model@1": "SESSION MODEL: MATCH", "plan-orient@1": "PLAN ORIENTATION: READY I100", "plan-ground@1": "PLAN STATE: EMPTY",
    "plan-discovery@1": "PLAN SHAPE: SIGNED OFF", "plan-sign-off-record@1": "SIGN-OFF RECORDED: RECORDED extended",
    "plan-draft@1": "PLAN DRAFTED: DRAFTED 1-1-3", "plan-draft-approval@1": "PLAN DRAFT REVIEW: APPROVED",
    "plan-create@1": "PLAN CREATED: CREATED 5", "plan-wire@1": "PLAN WIRED: WIRED 4", "rationalize-gantt@1": "GANTT: DATED 3",
    "plan-number@1": "PLAN NUMBERED: NUMBERED 1-3", "plan-hand-off@1": "PLAN HANDED OFF: HANDED OFF I100",
    "rebalance-gates@1": "REBALANCE GATES: CLEAR", "rebalance-partition@1": "REBALANCE PARTITION: PARTITIONED 4-1",
    "rebalance-proposal@1": "REBALANCE PROPOSAL: SIGNED OFF", "rebalance-probe@1": "SCHEDULER PROBE: HELD",
    "rebalance-successors@1": "REBALANCE SUCCESSORS: CREATED 2", "rebalance-rewire@1": "REBALANCE REWIRE: DONE 3",
    "rebalance-renumber@1": "REBALANCE RENUMBER: DONE 2.1-3.1", "rebalance-archive@1": "REBALANCE ARCHIVE: ARCHIVED 4",
    "rebalance-marker@1": "REBALANCE MARKER: REWRITTEN standard", "rebalance-report@1": "REBALANCE REPORT: RE-SLICED 4-2",
}


def walk(run, answers=None, limit=40):
    """Answer every issued step cleanly, or with answers[step id] (a list, one per attempt)."""
    answers = dict((k, list(v)) for k, v in (answers or {}).items())
    for _ in range(limit):
        if not run.answer or run.answer.get("action") != "run":
            return run.answer
        step = run.answer["step"]
        queue = answers.get(step["id"])
        verdict = queue.pop(0) if queue else CLEAN[step["contract"]]
        run.done(verdict)
    return run.answer


run = Run(plan)
end = walk(run)
check("a clean plan run issues the twelve steps in the pinned order and finishes", (run.issued, end.get("action"), end.get("outcome")) ==
      ([s for _, ids in PLAN_PHASES for s in ids], "finished", "completed"), (run.issued, end))

run = Run(plan)
end = walk(run, {"discover": ["PLAN SHAPE: NOT SIGNED OFF"]})
check("a shape not yet signed off asks, and the sign-off is never recorded", end.get("action") == "stopped" and end.get("stepId") == "discover"
      and "record-sign-off" not in run.issued, (end, run.issued))
run.resume(answer="yes, build this")
end = walk(run)
check("after the person's answer the discovery step runs again and the plan finishes", run.issued.count("discover") == 2 and end.get("outcome") == "completed", (run.issued, end))

run = Run(plan)
end = walk(run, {"confirm-drafts": ["PLAN DRAFT REVIEW: NOT APPROVED"]})
check("drafts not approved stop at the review, and nothing is created", end.get("stepId") == "confirm-drafts" and "create-items" not in run.issued, (end, run.issued))

run = Run(plan)
end = walk(run, {"record-sign-off": ["SIGN-OFF RECORDED: LINK MODE ON"]})
check("Link Mode on asks at the sign-off", end.get("action") == "stopped" and end.get("stepId") == "record-sign-off", end)
run.resume(answer="switched off")
check("after the answer the sign-off is re-issued as attempt 2", run.answer.get("action") == "run" and run.answer["step"]["id"] == "record-sign-off"
      and run.answer["step"]["attempt"] == 2, run.answer)

for step_id, verdict, never in (("create-items", "PLAN CREATED: PARTIAL 3/5", "wire-edges"), ("wire-edges", "PLAN WIRED: ORPHANS I101", "rationalize-dates"),
                                ("rationalize-dates", "GANTT: CYCLE I101>I102>I101", "number-titles")):
    run = Run(plan)
    end = walk(run, {step_id: [verdict]})
    check("%s stops the plan at %s and %s is never issued" % (verdict.split(": ")[1].split(" ")[0], step_id, never),
          end.get("action") == "stopped" and end.get("stepId") == step_id and never not in run.issued, (end, run.issued))

for state in ("EMPTY", "PARTIAL", "SHALLOW"):
    run = Run(plan)
    end = walk(run, {"ground": ["PLAN STATE: %s" % state]})
    check("a %s plan carries on to discovery" % state, "discover" in run.issued and end.get("outcome") == "completed", (run.issued, end))
run = Run(plan)
end = walk(run, {"orient": ["PLAN ORIENTATION: NEEDS ANSWER the argument says standard, the root says extended"]})
check("a profile that disagrees with the marker is a question at orient", end.get("action") == "stopped" and end.get("stepId") == "orient", end)
for verdict in ("PLAN NUMBERED: UNNUMBERED PLAN KEPT", "PLAN NUMBERED: ALREADY NUMBERED"):
    run = Run(plan)
    check("%s carries on" % verdict.split(": ")[1], walk(run, {"number-titles": [verdict]}).get("outcome") == "completed")
run = Run(plan)
end = walk(run, {"hand-off": ["PLAN HANDED OFF: ANOTHER ROUND WANTED"]})
check("hand-off ends with another-round when asked", end.get("action") == "finished" and end.get("outcome") == "another-round", end)
for verdict in ("SESSION MODEL: UNKNOWN", "SESSION MODEL: OFF", "SESSION MODEL: MISMATCH UNATTENDED"):
    run = Run(plan)
    check("%s carries on without asking" % verdict.split(": ")[1], walk(run, {"session-check": [verdict]}).get("outcome") == "completed")
run = Run(plan)
check("a model mismatch asks once", walk(run, {"session-check": ["SESSION MODEL: MISMATCH"]}).get("stepId") == "session-check")

run = Run(reb)
end = walk(run)
check("a clean rebalance issues the thirteen steps in the pinned order and finishes",
      (run.issued, end.get("outcome")) == ([s for _, ids in REBALANCE_PHASES for s in ids], "completed"), (run.issued, end))
for step_id, verdict, outcome in (("propose", "REBALANCE PROPOSAL: DRY RUN", "dry-run"), ("propose", "REBALANCE PROPOSAL: DECLINED", "declined")):
    run = Run(reb)
    end = walk(run, {step_id: [verdict]})
    check("%s ends %s and no write step is issued" % (verdict, outcome), end.get("outcome") == outcome
          and not set(run.issued) & set(order), (end, run.issued))
for step_id, verdict in (("gates", "REBALANCE GATES: BUILD LOOP ACTIVE I105"), ("scheduler-probe", "SCHEDULER PROBE: OVERWRITTEN")):
    run = Run(reb)
    end = walk(run, {step_id: [verdict]})
    check("%s stops before any successor is created" % verdict, end.get("stepId") == step_id and "create-successors" not in run.issued, (end, run.issued))
for verdict in ("REBALANCE GATES: SCHEDULER ON", "REBALANCE GATES: BAD ARGUMENTS no profile word"):
    run = Run(reb)
    end = walk(run, {"gates": [verdict]})
    check("%s asks" % verdict, end.get("action") == "stopped" and end.get("stepId") == "gates", end)
run = Run(reb)
end = walk(run, {"rewire": ["REBALANCE REWIRE: ORPHANS I103"]})
check("rebalance orphans stop at the rewire; the originals are never archived", end.get("stepId") == "rewire" and "archive-originals" not in run.issued, (end, run.issued))
PY
OUT="$(python3 "$WORK/cases.py" "$ROOT" "$WORK" 2>&1)"; RC=$?
while IFS= read -r line; do
  case "$line" in "ok   "*) ok "${line#ok   }" ;; "FAIL "*) bad "${line#FAIL }" ;; *) echo "       $line" ;; esac
done <<< "$OUT"
[ "$RC" -eq 0 ] || bad "a case failed or the script did not finish (exit $RC)"
exit $FAIL
