#!/bin/bash
# scripts/tests/workflow-combined.sh — where the step runner's two sets of abilities meet.
#
# One set came with the Release workflow (the yes-or-no stop, the `wait` command, runs with no
# item kept by run id, going back to an earlier step, counted redos); the other with composable
# workflows (approval gates and checkpoints that park a run, conditions, carrying on after a
# failure, recorded run endings). Each has its own suite. This one drives the real runner through
# the places they touch, as skills/run-workflow/references/workflow-runner.md states them:
#
#   1. Waiting and parked are two things: `wait` marks an issued step, a requested gate parks the
#      run, and `status`, `status` with `all` and the position name each correctly.
#   2. Going back (rewind) over a conditional step, a failure the run carried on past, a gate, a
#      blocking checkpoint and a checkpoint left open.
#   3. One counting rule for re-issues: an adoption's claim is never counted, a person's changes
#      at a gate are, and a gate asked again by a rewind is not.
#   4. Run-keyed state beside adoption by item: a session holds a run with no item and a parked
#      run for an item; another session adopts the parked one by its item only; a run with no
#      item never has a gate; a state file an earlier plugin wrote is carried on.
#   5. Run endings: a no at a yes-or-no stop is told to the tracker as interrupted, never as the
#      landing an earlier step recorded.
#   6. A step skill that is not switched on is refused, and run only in a rehearsal.
# Gates and checkpoints are themselves not switched on (scripts/tests/workflow-gates.sh says how
# they are, and proves the refusal), so every walk here through one starts as a rehearsal.
# Everything happens in a throwaway directory. No network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export PYTHONDONTWRITEBYTECODE=1
unset CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID XDG_CACHE_HOME GIT_DIR GIT_WORK_TREE

cat > "$WORK/cases.py" <<'PY'
import copy, json, os, re, shutil, subprocess, sys

ROOT, WORK = sys.argv[1], sys.argv[2]
RUNNER = "skills/run-workflow/scripts/workflow.py"
FIX = json.load(open(os.path.join(ROOT, "skills/run-workflow/scripts/workflow-fixtures.json"), encoding="utf-8"))
CATALOG = json.load(open(os.path.join(ROOT, "schemas/step-contracts.json"), encoding="utf-8"))
SKILLS = ["claim-story", "story-lifecycle", "branch-feature", "ultracode-build", "risk-check", "local-checks", "review-story",
          "merge-story", "capture-findings", "sync-base"]
SINCE = "2026-11-21T16:00:00.000Z"
made = [0]


def check(label, good, detail=""):
    print(("ok   " if good else "FAIL ") + label + ("" if good else " -> %s" % (detail,)))


def plugin(name, change=None):
    """A copy of the plugin whose step skills are placeholders, its catalog changed by `change`."""
    root = os.path.join(WORK, name)
    if os.path.isdir(root):
        return root
    for folder in (".claude-plugin", "schemas", "skills/run-workflow/scripts", "skills/build-item/scripts"):
        os.makedirs(os.path.join(root, folder))
    for path in (".claude-plugin/plugin.json", RUNNER, "skills/build-item/scripts/workflow_report.py",
                 "skills/build-item/scripts/claim_record.py", "skills/build-item/scripts/routing.py"):
        shutil.copy(os.path.join(ROOT, path), os.path.join(root, path))
    catalog = copy.deepcopy(CATALOG)
    if change:
        change(catalog)
    with open(os.path.join(root, "schemas/step-contracts.json"), "w", encoding="utf-8") as out:
        json.dump(catalog, out)
    for skill in SKILLS:
        os.makedirs(os.path.join(root, "skills", skill))
        with open(os.path.join(root, "skills", skill, "SKILL.md"), "w") as out:
            out.write("---\nname: %s\n---\nA placeholder for a step skill.\n" % skill)
    return root


def rewinding(catalog):
    """The merge's REFRESHED sends the run back to the local checks."""
    next(v for v in catalog["contracts"]["merge@1"]["verdict"]["values"] if v["value"] == "REFRESHED")["class"] = "rewind:local-checks@1"


def rewinding_to_start(catalog):
    next(v for v in catalog["contracts"]["merge@1"]["verdict"]["values"] if v["value"] == "REFRESHED")["class"] = "rewind:start@1"


def confirming(catalog):
    """A test-only check a person may confirm, run by a placeholder skill."""
    catalog["contracts"]["confirm-check@1"] = {
        "summary": "A test-only step.", "builtinSkill": "sync-base", "payload": {"answer": "step.answer?"}, "argument": None,
        "verdict": {"label": "CHECK", "values": [{"value": "CLEAR", "detail": "none", "class": "continue"},
                                                 {"value": "NOT RUN", "detail": "none", "class": "confirm"}]},
        "result": {"required": [], "types": {"answer": "string"}}, "proof": {"binding": "none"},
        "requires": [], "claimPhase": None, "shipIntentStage": None}


def sleeping(catalog):
    catalog["dormantSkills"] = {"sync-base": "it waits for its rehearsal"}


def fresh(name):
    made[0] += 1
    path = os.path.join(WORK, "%s-%d" % (name, made[0]))
    os.makedirs(path)
    return path


def git(repo, *args, **kw):
    done = subprocess.run(["git", "-C", repo, "-c", "user.name=Test", "-c", "user.email=test@example.com",
                           "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + list(args),
                          capture_output=True, input=kw.get("stdin"))
    if done.returncode != 0:
        raise RuntimeError("git %s: %s" % (" ".join(args), done.stderr.decode()))
    return done.stdout


def new_repo():
    """A repository on a branch called feature, one commit ahead of main (origin/main follows main)."""
    repo = fresh("repo")
    git(repo, "init", "-q")
    git(repo, "checkout", "-q", "-b", "main")
    for name, text, message, branch in (("readme.txt", "one\n", "first", None), ("export.txt", "export\n", "add the export", "feature")):
        if branch:
            git(repo, "symbolic-ref", "refs/remotes/origin/main", "refs/heads/main")
            git(repo, "checkout", "-q", "-b", branch)
        with open(os.path.join(repo, name), "w") as out:
            out.write(text)
        git(repo, "add", "-A")
        git(repo, "commit", "-q", "-m", message)
    return repo


DIFF = ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-relative", "--src-prefix=a/", "--dst-prefix=b/",
        "--ignore-submodules=none", "--unified=3", "--no-renames", "--diff-algorithm=myers", "--inter-hunk-context=0"]


def canned(contract, repo):
    patch = git(repo, "patch-id", "--verbatim", stdin=git(repo, *(DIFF + ["main...HEAD", "--"]))).decode().split()
    known = {"head": git(repo, "rev-parse", "HEAD").decode().strip(), "tree": git(repo, "rev-parse", "HEAD^{tree}").decode().strip(),
             "patchId": patch[0] if patch else ""}
    text = FIX["outputs"][contract]
    for key, value in known.items():
        text = text.replace("{%s}" % key, value)
    return text


def step(step_id, contract="start@1", mode="always", condition=None, on_fail="stop", **extra):
    ref = {"start@1": "story-lifecycle", "checkpoint@1": "checkpoint", "approval@1": "gate", "confirm-check@1": "sync-base"}[contract]
    out = {"id": step_id, "name": step_id.replace("-", " ").capitalize(), "summary": extra.pop("summary", ""), "contract": contract,
           "kind": "gate" if contract == "approval@1" else "step", "run": {"source": "builtin", "ref": ref, "version": None},
           "when": {"mode": mode, "condition": condition}, "onFail": on_fail}
    out.update(extra)
    return out


def build_with(after, *extra):
    """The Build fixture with the given steps put in after one of its own, in order."""
    definition = copy.deepcopy(FIX["definitions"]["build"])
    for phase in definition["phases"]:
        for at, one in enumerate(phase["steps"]):
            if one["id"] == after:
                phase["steps"][at + 1:at + 1] = [copy.deepcopy(s) for s in extra]
                return definition
    raise KeyError(after)


GATE = step("approve", "approval@1")
EVERYTHING = build_with("review",
                        step("maybe", mode="condition", condition="item-tag:needs-extra"),
                        step("may-fail", on_fail="continue"),
                        GATE,
                        step("by-hand", "checkpoint@1", mode="manual", summary="Check the staging page by hand."),
                        step("fyi", "checkpoint@1", mode="manual", on_fail="continue", summary="Tell the support desk."))


class Driver:
    def __init__(self, root, definition, session="s1", context=None, repo=None, cache=None, **more):
        self.root, self.cache, self.repo = root, cache or fresh("cache"), repo or new_repo()
        self.session = session
        context = dict(FIX["context"], cwd=self.repo, **(context or {}))
        if "rehearsal" not in more and any(one["kind"] == "gate" or one["when"]["mode"] == "manual"
                                           for phase in definition["phases"] for one in phase["steps"]):
            more["rehearsal"] = True  # a gate or a checkpoint is not switched on yet: a walk through one is a rehearsal
        self.result = self.call("start", dict({"definition": definition, "context": context}, **more))
        self.answer = self.result[1]

    def call(self, command, request, session=None):
        env = dict((k, v) for k, v in os.environ.items() if k not in ("CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID"))
        env["XDG_CACHE_HOME"] = self.cache
        done = subprocess.run([sys.executable, "-B", os.path.join(self.root, RUNNER), command],
                              input=json.dumps(dict(request, session=session or self.session)),
                              capture_output=True, text=True, env=env, cwd=self.repo)
        return done.returncode, (json.loads(done.stdout) if done.returncode == 0 else None), done.stdout, done.stderr

    def send(self, command, request, session=None):
        self.result = self.call(command, request, session)
        if self.result[1] is not None:
            self.answer = self.result[1]
        return self.result[1]

    def done(self, output=None, session=None, **more):
        at = self.answer["step"]
        return self.send("done", dict({"item": "I123", "stepId": at["id"], "attempt": at["attempt"],
                                       "output": output if output is not None else canned(at["contract"], self.repo)}, **more), session)

    def next(self, session=None, **request):
        return self.send("next", dict(request, item="I123"), session)

    def until(self, step_id, session=None, **more):
        """Answer issued steps with their passing answers until `step_id` is issued, or the run asks for something else."""
        while self.answer and self.answer["action"] == "run" and self.answer["step"]["id"] != step_id:
            self.done(session=session, **more)
        return self.answer

    def state(self, name=None):
        with open(os.path.join(self.cache, "devstride-plugin", "workflows", name or "%s.I123.json" % self.session)) as handle:
            return json.load(handle)

    def files(self):
        folder = os.path.join(self.cache, "devstride-plugin", "workflows")
        return sorted(name for name in os.listdir(folder) if name.endswith(".json")) if os.path.isdir(folder) else []


def refused(result, code):
    rc, _, out, err = result
    return rc == 2 and out == "" and re.match(r"^workflow: %s: [^\n]+\n$" % re.escape(code), err) is not None


def requested(label, gate_id):
    return "%s: REQUESTED\nasked\n```json\n%s\n```\n" % (label, json.dumps({"id": gate_id, "status": "pending", "requestedAt": SINCE}))


def answered(gate_id, word):
    return {"gateAnswer": {"id": gate_id, "status": "answered", "answer": word}}


def reports(answer, step_id=None):
    return [r for call in (answer or {}).get("reports", []) for r in call.get("reports", []) if step_id in (None, r.get("stepId"))]


def closes(answer, outcome):
    calls = (answer or {}).get("reports", [])
    return bool(calls) and calls[-1].get("run", {}).get("outcome") == outcome


TAGGED, UNTAGGED = {"facts": {"itemTags": ["needs-extra"]}}, {"facts": {"itemTags": []}}

# --- 1. waiting and parked ------------------------------------------------------------------------
run = Driver(plugin("plain"), build_with("local-checks", GATE))
run.until("build")
waited = run.call("wait", {"item": "I123", "stepId": "build", "attempt": 1, "reason": "the build queue"})[1]
status, listing = run.call("status", {"item": "I123"})[1], run.call("status", {"all": True})[1]["runs"]
check("wait: the issued step is waiting, the run is running, and nothing is parked",
      waited["waiting"]["reason"] == "the build queue" and status["state"] == "running" and status["parkedAt"] is None
      and status["position"]["stepId"] == "build" and [r["status"] for r in status["rows"] if r["stepId"] == "build"] == ["waiting"]
      and [(r["state"], r["waiting"], r["parkedAt"], r["position"]["stepId"]) for r in listing] == [("running", "the build queue", None, "build")],
      (status["state"], status["parkedAt"], listing))
answer = run.until("approve")
check("the gate is handed out as a request, never as a step to run", answer["action"] == "request-gate" and answer["step"]["id"] == "approve", answer)
check("wait on a requested gate is refused: a gate parks the run, it does not wait inside itself",
      refused(run.call("wait", {"item": "I123", "stepId": "approve", "attempt": 1, "reason": "the owner"}), "wait-not-a-step"), run.result[3])
answer = run.done(requested("APPROVAL", "gate-1"))
status, listing = run.call("status", {"item": "I123"})[1], run.call("status", {"all": True})[1]["runs"]
at = {"id": "gate-1", "since": SINCE, "stepId": "approve"}
check("a requested gate parks the run: the action, the step's row and the run's state all say parked",
      answer["action"] == "parked" and answer["recorded"]["status"] == "parked" and status["state"] == "parked"
      and [r["status"] for r in status["rows"] if r["stepId"] == "approve"] == ["parked"], (answer, status["state"]))
check("status names the gate and puts the position on it", status["parkedAt"] == at and status["position"]["stepId"] == "approve"
      and status["position"]["index"] == 7, (status["parkedAt"], status["position"]))
check("status with all lists the run as parked, at its gate, with no waiting reason",
      [(r["state"], r["waiting"], r["parkedAt"], r["position"]["stepId"], r["stopped"]) for r in listing] == [("parked", None, at, "approve", None)], listing)
check("the tracker is told waiting for a parked gate, its one word for both", [r["status"] for r in reports(answer, "approve")] == ["waiting"], reports(answer))
check("a parked run has no issued step, so wait and done are refused",
      refused(run.call("wait", {"item": "I123", "stepId": "approve", "attempt": 1}), "not-current-step")
      and refused(run.call("done", {"item": "I123", "stepId": "approve", "attempt": 1, "output": "APPROVAL: REQUESTED\n"}), "not-current-step"))
answer = run.next(**answered("gate-1", "approve"))
status = run.call("status", {"item": "I123"})[1]
check("once approved the run is running again and nothing is parked",
      answer["action"] == "run" and answer["step"]["id"] == "review" and status["state"] == "running" and status["parkedAt"] is None, status["state"])
check("a gate answer for a run that is not parked is refused (not-parked)", refused(run.call("next", dict(answered("gate-1", "approve"), item="I123")), "not-parked"))

# --- 2. going back ---------------------------------------------------------------------------------
root = plugin("rewinding", rewinding)
run = Driver(root, EVERYTHING, **TAGGED)
answer = run.until("maybe", **TAGGED)
check("the first time through, the condition holds and the conditional step runs", answer["action"] == "run" and answer["step"]["id"] == "maybe", answer)
run.done(**TAGGED)
answer = run.done("START: FAILED the board is locked\n", **TAGGED)
check("a failure the run carries on past is followed by the gate", answer["action"] == "request-gate" and answer["step"]["id"] == "approve", answer)
run.done(requested("APPROVAL", "gate-1"))
answer = run.next(**answered("gate-1", "approve"))
check("the approved gate is followed by the blocking checkpoint", answer["action"] == "request-gate" and answer["step"]["id"] == "by-hand", answer)
run.done(requested("CHECKPOINT", "cp-1"))
answer = run.next(**answered("cp-1", "done"))
check("... then the checkpoint the run does not wait for", answer["action"] == "request-gate" and answer["step"]["id"] == "fyi" and answer["blocking"] is False, answer)
answer = run.done(requested("CHECKPOINT", "cp-open"), **TAGGED)
check("... which is left open while the run goes on to the merge",
      answer["action"] == "run" and answer["step"]["id"] == "merge" and run.state()["steps"]["fyi"]["status"] == "open", answer)
answer = run.done("MERGE: REFRESHED\n")
check("the merge's rewind goes back to the local checks, as a second attempt",
      answer["action"] == "run" and answer["step"] == dict(answer["step"], id="local-checks", attempt=2)
      and answer["recorded"]["class"] == "rewind:local-checks@1", answer)
state = run.state()
check("everything in between is pending again, except the checkpoint the run never waited for",
      [state["steps"][s]["status"] for s in ("review", "maybe", "may-fail", "approve", "by-hand", "fyi")]
      == ["pending"] * 5 + ["open"] and "gate" not in state["steps"]["approve"] and state["steps"]["fyi"]["gate"]["id"] == "cp-open"
      and "continued" not in state["steps"]["may-fail"], dict((k, v["status"]) for k, v in state["steps"].items()))
run.done()            # the local checks, again
answer = run.done()   # the review, again: no facts passed with it
check("a conditional step in the range is decided again: the run asks for its fact once more",
      answer["action"] == "need-facts" and answer["step"]["id"] == "maybe" and answer["needs"] == ["itemTags"], answer)
answer = run.next(**UNTAGGED)
check("... and this time its condition is false, so it is skipped although it ran before",
      answer["action"] == "run" and answer["step"] == dict(answer["step"], id="may-fail", attempt=2)
      and run.state()["steps"]["maybe"]["status"] == "skipped" and run.state()["steps"]["maybe"]["verdict"] == "SKIPPED: item-tag:needs-extra was false",
      (answer, run.state()["steps"]["maybe"]))
answer = run.done(**UNTAGGED)
check("the step that failed and was carried on past ran again, and the gate is asked again as a new attempt",
      answer["action"] == "request-gate" and answer["step"]["id"] == "approve" and answer["attempt"] == 2
      and answer["arguments"]["attempt"] == 2, answer)
check("a gate asked again by a rewind is not counted against it", run.state()["steps"]["approve"]["autoRedo"] == 0
      and run.state()["steps"]["local-checks"]["autoRedo"] == 0, run.state()["steps"]["approve"])
run.done(requested("APPROVAL", "gate-2"))
answer = run.next(**answered("gate-1", "approve"))
check("the earlier approval does not answer the new request", answer["action"] == "parked" and answer["gate"]["id"] == "gate-2", answer)
answer = run.next(**answered("gate-2", "approve"))
check("the blocking checkpoint is asked again too", answer["action"] == "request-gate" and answer["step"]["id"] == "by-hand" and answer["attempt"] == 2, answer)
run.done(requested("CHECKPOINT", "cp-2"))
answer = run.next(**dict(answered("cp-2", "done"), **UNTAGGED))
check("the open checkpoint is never asked twice: the merge comes next", answer["action"] == "run" and answer["step"] == dict(answer["step"], id="merge", attempt=2), answer)
answer = run.until(None, **UNTAGGED)
check("the run finishes and says what did not stop it: the open checkpoint and the skipped step, and no failure",
      answer["action"] == "finished" and answer["outcome"] == "completed" and answer["openCheckpoints"] == [{"stepId": "fyi", "gateId": "cp-open"}]
      and answer["skippedByCondition"] == ["maybe"] and answer["continuedPastFailures"] == [], answer)
again = Driver(root, EVERYTHING, **TAGGED)
again.until("maybe", **TAGGED)
again.done(**TAGGED)
again.done("START: FAILED the board is locked\n", **TAGGED)
again.done(requested("APPROVAL", "gate-1"))
again.next(**answered("gate-1", "approve"))
again.done(requested("CHECKPOINT", "cp-1"))
again.next(**answered("cp-1", "skipped"))
again.done(requested("CHECKPOINT", "cp-open"), **TAGGED)
answer = again.until(None, **TAGGED)
check("without a rewind the same run ends with its failure and its open checkpoint listed",
      answer["action"] == "finished" and [f["stepId"] for f in answer["continuedPastFailures"]] == ["may-fail"]
      and answer["openCheckpoints"] == [{"stepId": "fyi", "gateId": "cp-open"}] and answer["skippedByCondition"] == [], answer)
conditional_target = build_with("review", step("extra", mode="condition", condition="has-repository"))
attempt = Driver(plugin("rewinding-to-start", rewinding_to_start), conditional_target)
check("start refuses a rewind whose step to go back to is conditional (rewind-not-always)", refused(attempt.result, "rewind-not-always"), attempt.result[3])
attempt = Driver(plugin("rewinding-to-start", rewinding_to_start), build_with("review", step("extra", on_fail="continue")))
check("... or carries on after a failure (rewind-not-always)", refused(attempt.result, "rewind-not-always"), attempt.result[3])
attempt = Driver(plugin("rewinding-to-start", rewinding_to_start), build_with("review", step("extra")))
check("... and accepts one that always runs and stops on failure", attempt.answer is not None and attempt.answer["action"] == "run", attempt.result[3])

# --- 3. one counting rule --------------------------------------------------------------------------
run = Driver(plugin("plain"), build_with("local-checks", GATE))
run.until("approve")
run.done(requested("APPROVAL", "gate-1"))
session = "s1"
for number in range(2, 9):  # seven adoptions in a row: the claim is asked again each time and never counted
    adopter = "s%d" % number
    answer = run.send("resume", {"item": "I123", "workflow": "build"}, adopter)
    if not (answer and answer["action"] == "run" and answer["step"]["id"] == "claim"):
        break
    answer = run.done(session=adopter)
    session = adopter
run.session = session
check("a parked run adopted seven times asks the story claim again each time and is never stopped for it",
      session == "s8" and answer["action"] == "parked" and run.state()["steps"]["claim"]["autoRedo"] == 0
      and run.state()["steps"]["claim"]["attempt"] == 8, (session, answer, run.state()["steps"]["claim"]))
answer = run.next(**{"gateAnswer": {"id": "gate-1", "status": "answered", "answer": "changes", "note": "say why"}})
check("a person's changes are an address-changes action for the next attempt", answer["action"] == "address-changes" and answer["attempt"] == 2, answer)
answer = run.next()
check("... and the request that follows is counted", answer["action"] == "request-gate" and run.state()["steps"]["approve"]["autoRedo"] == 1, run.state()["steps"]["approve"])
run.done(requested("APPROVAL", "gate-2"))
run.next(**answered("gate-2", "approve"))
check("an approval puts the count back to zero", run.state()["steps"]["approve"]["autoRedo"] == 0, run.state()["steps"]["approve"])
source = open(os.path.join(ROOT, RUNNER), encoding="utf-8").read()
check("the runner counts in one place: one condition, naming reclaim and the contract's maxAutoRedo",
      source.count('record["autoRedo"] += 1') == 1
      and 'if cause and cause != "reclaim" and (cause != "redo" or "maxAutoRedo" in entry):' in source)

# --- 4. run-keyed state beside adoption by item ----------------------------------------------------
run = Driver(plugin("plain"), build_with("local-checks", GATE))
run.until("approve")
run.done(requested("APPROVAL", "gate-1"))
loose = run.call("start", {"definition": FIX["definitions"]["claim-only"], "context": dict(FIX["context"], cwd=run.repo, item=None)})[1]
check("a session holds a run with no item, kept by its run id, beside a parked run kept by its item",
      run.files() == sorted(["s1.I123.json", "s1.%s.json" % loose["runId"]]), run.files())
listing = run.call("status", {"all": True})[1]["runs"]
check("status with all lists both, the parked one as parked and the other as running",
      sorted((r["item"] or "", r["state"]) for r in listing) == [("", "running"), ("I123", "parked")], listing)
answer = run.call("resume", {"item": "I123", "workflow": "build"}, "s2")[1]
check("another session adopts the parked run by its item, and the claim is asked again first",
      answer is not None and answer["action"] == "run" and answer["step"]["id"] == "claim" and answer["adoptedFrom"]["sessionId"] == "s1", answer)
check("the run with no item stays where it was, untouched",
      run.files() == sorted(["s2.I123.json", "s1.%s.json" % loose["runId"]])
      and [r["runId"] for r in run.call("status", {"all": True})[1]["runs"]] == [loose["runId"]], run.files())
check("a run with no item is adopted only by its run id",
      refused(run.call("resume", {"workflow": "claim-only"}, "s3"), "no-run")
      and (run.call("resume", {"runId": loose["runId"], "workflow": "claim-only"}, "s3")[1] or {}).get("adoptedFrom", {}).get("sessionId") == "s1")
attempt = Driver(plugin("plain"), build_with("local-checks", GATE), context={"item": None})
check("a gate in a run with no item is refused at start (gate-needs-item), so a parked run always has an item",
      refused(attempt.result, "gate-needs-item") and attempt.files() == [], attempt.result[3])
attempt = Driver(plugin("plain"), build_with("local-checks", step("by-hand", "checkpoint@1", mode="manual")), context={"item": None})
check("... and so is a checkpoint", refused(attempt.result, "gate-needs-item"), attempt.result[3])
old = Driver(plugin("plain"), FIX["definitions"]["claim-only"], context={"item": None}, session="s5")
folder = os.path.join(old.cache, "devstride-plugin", "workflows")
os.rename(os.path.join(folder, "s5.%s.json" % old.answer["runId"]), os.path.join(folder, "s5.run.json"))  # as an earlier plugin kept it
listing = old.call("status", {"all": True})[1]["runs"]
carried = old.call("next", {})[1]
check("a state file an earlier plugin wrote for a run with no item is listed, and carried on under its run id by the next command",
      [r["runId"] for r in listing] == [old.answer["runId"]] and carried["step"]["id"] == "claim"
      and old.files() == ["s5.%s.json" % old.answer["runId"]], (listing, old.files()))

# --- 5. run endings --------------------------------------------------------------------------------
root = plugin("confirming", confirming)
ending = build_with("complete", step("check", "confirm-check@1"))
accepts = {"match": None, "runOutcomes": ["landed", "handed-up", "shipped"]}
run = Driver(root, ending, fetched=accepts)
while run.answer["action"] == "run" and run.answer["step"]["id"] != "check":
    at = run.answer["step"]
    run.done("COMPLETE: LANDED\n" + canned("complete@1", run.repo).split("\n", 1)[1] if at["contract"] == "complete@1" else None)
answer = run.done("CHECK: NOT RUN\n")
check("the yes-or-no stop is a stop, not a parked run", answer["action"] == "stopped" and answer.get("confirm") is True
      and run.call("status", {"item": "I123"})[1]["state"] == "stopped", answer)
answer = run.send("resume", {"item": "I123", "workflow": "build", "answer": "no, not today"})
check("a no ends the run as declined, and the tracker is told interrupted, never the landing an earlier step recorded",
      answer["action"] == "finished" and answer["outcome"] == "declined" and answer["recordedOutcome"] is None
      and closes(answer, "interrupted") and run.state()["steps"]["complete"]["recordsOutcome"] == "landed", answer)
run = Driver(root, ending, fetched=accepts)
while run.answer["action"] == "run" and run.answer["step"]["id"] != "check":
    at = run.answer["step"]
    run.done("COMPLETE: LANDED\n" + canned("complete@1", run.repo).split("\n", 1)[1] if at["contract"] == "complete@1" else None)
run.done("CHECK: NOT RUN\n")
answer = run.send("resume", {"item": "I123", "workflow": "build", "answer": "yes"})
answer = run.until(None)
check("a yes goes on, and the finished run is told as the landing the tracker accepts",
      answer["action"] == "finished" and answer["outcome"] == "completed" and answer["recordedOutcome"] == "landed" and closes(answer, "landed"), answer)

# --- 6. a step skill that is not switched on --------------------------------------------------------
root = plugin("sleeping", sleeping)
attempt = Driver(root, FIX["definitions"]["build"])
check("a definition that runs a step skill not switched on yet is refused (skill-dormant), with the reason, and nothing is written",
      refused(attempt.result, "skill-dormant") and "it waits for its rehearsal" in attempt.result[3] and attempt.files() == [], attempt.result[3])
rehearsed = Driver(root, FIX["definitions"]["build"], rehearsal=True)
check("the same start as a rehearsal runs it, and the run remembers it is one",
      rehearsed.answer is not None and rehearsed.answer["action"] == "run" and rehearsed.state().get("rehearsal") is True, rehearsed.result[3])
check("a run that is no rehearsal does not say it is one", "rehearsal" not in Driver(plugin("plain"), FIX["definitions"]["build"]).state())
attempt = Driver(root, FIX["definitions"]["build"], rehearsal="yes")
check("rehearsal is only ever true or false", refused(attempt.result, "bad-request"), attempt.result[3])
ours = dict(copy.deepcopy(FIX["definitions"]["build"]), id="ours", name="Ours", version=2)
spec = __import__("importlib.util").util.spec_from_file_location("report_of", os.path.join(ROOT, "skills/build-item/scripts/workflow_report.py"))
report = __import__("importlib.util").util.module_from_spec(spec)
spec.loader.exec_module(report)
fetched = {"organizationId": "org-1", "skills": [], "match": {"workflowId": "ours", "name": "Ours", "version": 2, "startsWhen": "item-picked-up",
                                                               "minPluginVersion": ours["minPluginVersion"], "hash": report.definition_hash(ours), "definition": ours}}
mostly = copy.deepcopy(FIX["definitions"]["claim-only"])
answer = Driver(root, mostly, fetched=fetched).answer
check("an organization's workflow that runs one falls back to the built-in workflow, with a notice",
      answer is not None and answer["definitionSource"] == "builtin" and "could not be run by this plugin" in (answer.get("notice") or ""), answer)
runner_catalog = __import__("importlib.util").util.spec_from_file_location("runner_of", os.path.join(ROOT, RUNNER))
module = __import__("importlib.util").util.module_from_spec(runner_catalog)
runner_catalog.loader.exec_module(module)
bad = copy.deepcopy(CATALOG)
bad["dormantSkills"] = {"no-such-skill": "why"}
check("the catalog check refuses a dormant skill no contract names", any(f.startswith("dormant-skill: no-such-skill") for f in module.check_catalog(bad)), module.check_catalog(bad))
bad["dormantSkills"] = {"sync-base": ""}
check("... and one with no reason", module.check_catalog(bad) == ["shape: dormantSkills: each entry is a step skill's name, or gate or checkpoint, and one line on what it waits for"], module.check_catalog(bad))
check("the shipped catalog lists the release steps, the approval gate and the checkpoint as not switched on, and nothing else",
      sorted(CATALOG.get("dormantSkills", {})) == ["checkpoint", "gate", "release-steps"] and module.check_catalog(CATALOG) == [], CATALOG.get("dormantSkills"))
attempt = Driver(plugin("plain"), build_with("local-checks", GATE), rehearsal=False)
check("so a gate handed to start outside a rehearsal is refused like a dormant skill, with the catalog's reason, and nothing is written",
      refused(attempt.result, "skill-dormant") and CATALOG["dormantSkills"]["gate"] in attempt.result[3] and attempt.files() == [], attempt.result[3])
reference = " ".join(open(os.path.join(ROOT, "skills/run-workflow/references/workflow-runner.md"), encoding="utf-8").read().split())
check("the runner reference states each rule this suite drives",
      all(heading in reference for heading in ("## Waiting and parked", "## Going back", "## Counting a step's re-issues"))
      and "`gate-needs-item`" in reference and "declined (a no at a `confirm` stop)" in reference and "`skill-dormant`" in reference)
PY

OUT="$(python3 -B "$WORK/cases.py" "$ROOT" "$WORK" 2>&1)"; RC=$?
printf '%s\n' "$OUT" | sed 's/^/  /'
N="$(printf '%s\n' "$OUT" | grep -c '^ok')"
if [ $RC -ne 0 ] || printf '%s\n' "$OUT" | grep -q '^FAIL'; then bad "a case failed or the script did not finish (exit $RC)"
elif [ "$N" -lt 50 ]; then bad "only $N cases ran, expected at least 50"
else ok "(all $N cases passed)"; fi
exit $FAIL
