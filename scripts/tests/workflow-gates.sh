#!/bin/bash
# Tests for the approval gate in skills/run-workflow/scripts/workflow.py: a Build fixture with a
# gate between the local checks and the review is driven end to end with canned step answers and
# canned gate answers. start accepts a gate and refuses one that does not run the reserved built-in
# reference; next hands out request-gate; done with APPROVAL: REQUESTED parks the run and reports
# the step waiting; a pending, unreadable, approved, changes, rejected or unavailable answer each
# give the right action, both in the runner's words and in get_workflow_gate's own answer (status
# pending, answered or withdrawn, with the answer approve, changes or reject); a withdrawn gate ends
# the run; the fifth attempt stops for a person; resume with the item adopts a parked run and asks
# the story claim again first. A checkpoint (a step a person does by hand) reuses all of it: it is
# requested the same way, a blocking one parks the run until the person marks it done or skipped,
# a non-blocking one lets the run go on at once, and a parked one is adopted the same way.
# Everything happens in a throwaway directory: its own
# cache folder, a copy of the plugin whose step skills are placeholders, and a small git
# repository. No network.
#
# Gates and checkpoints are NOT SWITCHED ON: the catalog lists the reserved references `gate` and
# `checkpoint` under `dormantSkills`, so `start` refuses a definition that holds one (skill-dormant),
# whatever handed it over, unless the start says `rehearsal`. Every walk here is a rehearsal; the
# cases under "not switched on" prove the refusal. To switch them on, in the change that makes the
# tracker offer the two gate tools: delete those two lines from the catalog, see that the release
# named as their `since` (the contracts approval@1 and checkpoint@1, the feature when-manual) is the
# one that first runs them, and stop passing `rehearsal` here.
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
SKILLS = ["claim-story", "story-lifecycle", "branch-feature", "ultracode-build", "risk-check", "local-checks", "review-story",
          "merge-story", "capture-findings", "sync-base"]
GATE = {"id": "approve", "name": "Approve the change", "summary": "A person approves before the review.", "contract": "approval@1",
        "kind": "gate", "run": {"source": "builtin", "ref": "gate", "version": None}, "when": {"mode": "always", "condition": None},
        "onFail": "stop", "answerers": [{"kind": "item-owner"}, {"kind": "role", "roleId": "role-lead"}]}
SINCE = "2026-11-21T16:00:00.000Z"
count, made = [0], [0]


def check(label, good, detail=""):
    count[0] += 1
    print(("ok   " if good else "FAIL ") + label + ("" if good else " -> %s" % (detail,)))


def plugin():
    root = os.path.join(WORK, "plugin")
    if os.path.isdir(root):
        return root
    for folder in (".claude-plugin", "schemas", "skills/run-workflow/scripts", "skills/build-item/scripts"):
        os.makedirs(os.path.join(root, folder))
    for path in (".claude-plugin/plugin.json", "schemas/step-contracts.json", RUNNER,
                 "skills/build-item/scripts/workflow_report.py", "skills/build-item/scripts/claim_record.py"):
        shutil.copy(os.path.join(ROOT, path), os.path.join(root, path))
    for skill in SKILLS:
        os.makedirs(os.path.join(root, "skills", skill))
        with open(os.path.join(root, "skills", skill, "SKILL.md"), "w") as out:
            out.write("---\nname: %s\n---\nA placeholder for a step skill.\n" % skill)
    return root


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


def commit(repo, name, text, message):
    with open(os.path.join(repo, name), "w") as out:
        out.write(text)
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", message)


def new_repo():
    """A repository on a branch called feature, one commit ahead of main (origin/main follows main)."""
    repo = fresh("repo")
    git(repo, "init", "-q")
    git(repo, "checkout", "-q", "-b", "main")
    commit(repo, "readme.txt", "one\n", "first")
    git(repo, "symbolic-ref", "refs/remotes/origin/main", "refs/heads/main")
    git(repo, "checkout", "-q", "-b", "feature")
    commit(repo, "export.txt", "export\n", "add the export")
    return repo


DIFF = ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-relative", "--src-prefix=a/", "--dst-prefix=b/",
        "--ignore-submodules=none", "--unified=3", "--no-renames", "--diff-algorithm=myers", "--inter-hunk-context=0"]


def canned(contract, repo):
    """The passing answer for a contract, filled from the repository the way the runner checks it."""
    patch = git(repo, "patch-id", "--verbatim", stdin=git(repo, *(DIFF + ["main...HEAD", "--"]))).decode().split()
    facts = {"head": git(repo, "rev-parse", "HEAD").decode().strip(), "tree": git(repo, "rev-parse", "HEAD^{tree}").decode().strip(),
             "patchId": patch[0] if patch else ""}
    text = FIX["outputs"][contract]
    for key, value in facts.items():
        text = text.replace("{%s}" % key, value)
    return text


def gated(edits=None):
    definition = copy.deepcopy(FIX["definitions"]["build"])
    for phase in definition["phases"]:
        for at, step in enumerate(phase["steps"]):
            if step["id"] == "local-checks":
                phase["steps"].insert(at + 1, copy.deepcopy(GATE))
                break
    gate = next(step for phase in definition["phases"] for step in phase["steps"] if step["id"] == "approve")
    for key, value in (edits or {}).items():
        if value is None:
            gate.pop(key)
        else:
            gate[key] = value
    return definition


def requested(gate_id, wrapped=True):
    body = {"id": gate_id, "status": "pending", "attempt": 1, "requestedAt": SINCE}
    return "APPROVAL: REQUESTED\nasked the item's owner\n```json\n%s\n```\n" % json.dumps({"data": body} if wrapped else body)


class Driver:
    def __init__(self, definition=None, session="s1", rehearsal=True, **more):
        self.root, self.cache, self.repo = plugin(), fresh("cache"), new_repo()
        self.session, self.answers = session, []
        request = {"definition": definition or gated(), "context": dict(FIX["context"], cwd=self.repo)}
        if rehearsal:
            request["rehearsal"] = True  # a gate or a checkpoint runs only in a rehearsal (see the top of this file)
        self.result = self.call("start", dict(request, **more))
        self.answer = self.result[1]

    def written(self):
        folder = os.path.join(self.cache, "devstride-plugin", "workflows")
        return sorted(os.listdir(folder)) if os.path.isdir(folder) else []

    def call(self, command, request, session=None):
        env = dict((k, v) for k, v in os.environ.items() if k not in ("CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID"))
        env["XDG_CACHE_HOME"] = self.cache
        request = dict(request, session=session or self.session)
        done = subprocess.run([sys.executable, "-B", os.path.join(self.root, RUNNER), command], input=json.dumps(request),
                              capture_output=True, text=True, env=env, cwd=self.repo)
        answer = json.loads(done.stdout) if done.returncode == 0 else None
        if answer is not None:
            self.answers.append(answer)
        return done.returncode, answer, done.stdout, done.stderr

    def send(self, command, request, session=None):
        self.result = self.call(command, request, session)
        if self.result[1] is not None:
            self.answer = self.result[1]
        return self.result[1]

    def done(self, output=None):
        step = self.answer["step"]
        return self.send("done", {"item": "I123", "stepId": step["id"], "attempt": step["attempt"],
                                  "output": output if output is not None else canned(step["contract"], self.repo)})

    def next(self, **request):
        return self.send("next", dict(request, item="I123"))

    def to_gate(self):
        while self.answer and self.answer["action"] == "run":
            self.done()
        return self.answer

    def state(self, session=None):
        path = os.path.join(self.cache, "devstride-plugin", "workflows", "%s.I123.json" % (session or self.session))
        return json.load(open(path))


def refused(result, code):
    rc, _, out, err = result
    return rc == 2 and out == "" and re.match(r"^workflow: %s: [^\n]+\n$" % re.escape(code), err) is not None


def gate_reports(answer, status=None):
    return [r for call in answer.get("reports", []) for r in call.get("reports", [])
            if r.get("stepId") == "approve" and (status is None or r.get("status") == status)]


def closes(answer, outcome):
    calls = answer.get("reports", [])
    return bool(calls) and calls[-1].get("run", {}).get("outcome") == outcome


# --- not switched on ------------------------------------------------------------------------------
def fetched_as_theirs(definition):
    """The tracker's answer for the item: this definition, whole, with its fingerprint."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("report_of", os.path.join(ROOT, "skills/build-item/scripts/workflow_report.py"))
    report = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(report)
    return {"organizationId": "org-1", "skills": [],
            "match": {"workflowId": "our-build", "name": "Our build", "version": 3, "startsWhen": definition["startsWhen"],
                      "minPluginVersion": definition["minPluginVersion"], "hash": report.definition_hash(definition), "definition": definition}}


plain = Driver(rehearsal=False)
check("not switched on: a definition with a gate handed to start is refused (skill-dormant) and nothing is written",
      refused(plain.result, "skill-dormant") and plain.written() == [], (plain.result[3], plain.written()))
handed = Driver(rehearsal=False)  # refused above; the same definition from a file
path = os.path.join(fresh("definition"), "gated.json")
with open(path, "w") as out:
    json.dump(gated(), out)
result = handed.call("start", {"definitionFile": path, "context": dict(FIX["context"], cwd=handed.repo)})
check("... also when it comes from a file", refused(result, "skill-dormant") and handed.written() == [], result[3])
result = handed.call("start", {"definitionFile": path, "context": dict(FIX["context"], cwd=handed.repo), "rehearsal": False})
check("... and rehearsal false is no rehearsal", refused(result, "skill-dormant"), result[3])
theirs = Driver(FIX["definitions"]["build"], rehearsal=False, fetched=fetched_as_theirs(gated()))
check("... and when the tracker answers with one: the built-in workflow runs instead, and says why",
      theirs.answer is not None and theirs.answer["action"] == "run" and theirs.answer["definitionSource"] == "builtin"
      and "could not be run by this plugin" in (theirs.answer["notice"] or "") and "not switched on" in theirs.answer["notice"], theirs.result)
theirs.to_gate()
check("... so that run never asks for a gate: it finishes with no request-gate and nothing parked",
      theirs.answer["action"] == "finished" and all(a.get("action") in ("run", "finished") for a in theirs.answers)
      and "approve" not in theirs.state()["steps"], [a.get("action") for a in theirs.answers])
rehearsed = Driver(FIX["definitions"]["build"], fetched=fetched_as_theirs(gated()))
check("in a rehearsal the tracker's workflow with a gate is the one that runs",
      rehearsed.answer is not None and rehearsed.answer["definitionSource"] == "organization" and "approve" in rehearsed.state()["steps"], rehearsed.result)

# --- start --------------------------------------------------------------------------------------
run = Driver()
check("start accepts a definition with a gate and issues the claim first",
      run.answer is not None and run.answer["action"] == "run" and run.answer["step"]["id"] == "claim", run.result[3])
for label, edits, code in (
        ("a gate that runs a skill", {"run": {"source": "builtin", "ref": "claim-story", "version": None}}, "unsupported-gate"),
        ("a gate that runs a repository file", {"run": {"source": "repo", "ref": "docs/check.md", "version": None}}, "unsupported-gate"),
        ("a gate switched off", {"run": {"source": "off", "ref": None, "version": None}}, "unsupported-gate"),
        ("a gate with another contract", {"contract": "custom@1"}, "unsupported-gate"),
        ("an approval@1 step that is not a gate", {"kind": "step", "answerers": None}, "unsupported-gate"),
        ("a gate that carries on after a failure", {"onFail": "continue"}, "unsupported-on-fail"),
        ("a manual gate", {"when": {"mode": "manual", "condition": None}}, "unsupported-when"),
        ("more than 20 answerers", {"answerers": [{"kind": "person", "username": "user%d" % n} for n in range(21)]}, "bad-schema"),
        ("an answerer of an unknown kind", {"answerers": [{"kind": "everyone"}]}, "bad-schema"),
        ("a role answerer without its role", {"answerers": [{"kind": "role"}]}, "bad-schema")):
    attempt = Driver(gated(edits))
    check("start refuses %s (%s)" % (label, code), refused(attempt.result, code), attempt.result[3])
plain = copy.deepcopy(FIX["definitions"]["build"])
plain["phases"][0]["steps"][0]["answerers"] = [{"kind": "edit-access"}]
attempt = Driver(plain)
check("answerers on a step that is not a gate is an unknown key: kept, never read, and the run starts as before",
      attempt.answer is not None and attempt.answer["action"] == "run"
      and attempt.state()["definition"]["phases"][0]["steps"][0]["answerers"] == [{"kind": "edit-access"}], attempt.result[3])

check("start accepts a gate that runs only when a condition holds", Driver(gated({"when": {"mode": "condition", "condition": "has-repository"}})).answer["action"] == "run")

# --- request-gate -------------------------------------------------------------------------------
answer = run.to_gate()
check("next hands out request-gate at the gate, attempt 1, with the tool and its arguments",
      answer["action"] == "request-gate" and answer["step"]["id"] == "approve" and answer["attempt"] == 1
      and answer["kind"] == "approval" and answer["blocking"] is True
      and answer["contract"] == "approval@1" and answer["tool"] == "request_workflow_gate"
      and answer["arguments"] == {"runId": answer["runId"], "stepId": "approve", "attempt": 1} and answer["item"] == "I123", answer)
check("request-gate carries the summary guidance and the earlier steps' verdicts, and no skill",
      "1,000 characters" in answer["summaryGuidance"] and "skill" not in answer
      and [v["stepId"] for v in answer["verdicts"]] == ["claim", "start", "branch", "build", "risk-check", "local-checks"], answer)
check("the gate is reported running, as the reserved built-in reference gate",
      [(r["status"], r["ran"]["source"], r["ran"]["ref"]) for r in gate_reports(answer)] == [("running", "builtin", "gate")], gate_reports(answer))
again = run.call("next", {"item": "I123"})[1]
check("next before done hands the same request back", again["action"] == "request-gate" and again["attempt"] == 1, again)
result = run.call("next", {"item": "I123", "gateAnswer": {"id": "gate-1", "status": "approved"}})
check("a gate answer before the gate was requested is refused (not-parked)", refused(result, "not-parked"), result[3])
before = run.state()
for verdict in ("APPROVAL: APPROVED", "APPROVAL: CHANGES do it again", "APPROVAL: REJECTED"):
    result = run.call("done", {"item": "I123", "stepId": "approve", "attempt": 1, "output": verdict + "\n"})
    check("an agent cannot answer the gate itself: %s is refused" % verdict, refused(result, "gate-answered-by-agent"), result[3])
check("a refused answer changes nothing", run.state() == before)

# --- REQUESTED parks the run --------------------------------------------------------------------
answer = run.done(requested("gate-1"))
check("APPROVAL: REQUESTED parks the run: wait, naming the gate and the one read to make",
      answer["action"] == "parked" and answer["gate"] == {"id": "gate-1", "since": SINCE} and answer["check"] == "get_workflow_gate"
      and answer["arguments"] == {"gateId": "gate-1"} and "Do not poll" in answer["advice"], answer)
check("the step is recorded and reported waiting, with its verdict",
      answer["recorded"]["status"] == "parked" and [(r["status"], r["verdict"]) for r in gate_reports(answer)] == [("waiting", "APPROVAL: REQUESTED")],
      (answer.get("recorded"), gate_reports(answer)))
check("the gate's id is kept in the run's state file", run.state()["steps"]["approve"]["gate"] == {"id": "gate-1", "since": SINCE})
first, second = run.call("next", {"item": "I123"})[1], run.call("next", {"item": "I123"})[1]
check("next while parked is wait, the same both times, and reports nothing new",
      first == second and first["action"] == "parked" and first["reports"] == [], (first, second))
status = run.call("status", {"item": "I123"})[1]
check("status names the gate the run waits at", status["parkedAt"] == {"id": "gate-1", "since": SINCE, "stepId": "approve"}
      and status["position"]["stepId"] == "approve", status)
answer = run.next(gateAnswer={"data": {"id": "gate-1", "status": "pending"}})
check("a pending answer is wait again, with the advice", answer["action"] == "parked" and "ask your agent to continue" in answer["advice"], answer)
answer = run.next(gateAnswer={"unavailable": True})
check("a gate that could not be read is wait, never approved", answer["action"] == "parked" and "never read as approved" in answer["note"], answer)
answer = run.next(gateAnswer={"id": "gate-9", "status": "approved"})
check("an approval of another gate is wait", answer["action"] == "parked" and "not for this gate" in answer["note"], answer)
for label, unnamed in (("no gate id", {"status": "approved"}), ("no gate id, wrapped", {"data": {"gate": {"status": "answered", "answer": "approve"}}}),
                       ("an id that is not text", {"id": 7, "status": "approved"}), ("an id that is no id", {"id": "gate 1!", "status": "approved"}),
                       ("an empty id", {"gateId": "", "status": "answered", "answer": "approve"})):
    answer = run.next(gateAnswer=unnamed)
    check("an approval with %s is wait: the run stays parked at its gate, and nothing is recorded" % label,
          answer["action"] == "parked" and "names no gate" in answer["note"] and answer["gate"]["id"] == "gate-1"
          and run.state()["steps"]["approve"]["status"] == "parked" and run.state()["steps"]["approve"]["verdict"] == "APPROVAL: REQUESTED", answer)
answer = run.next(gateAnswer={"id": "gate-1", "status": "maybe"})
check("an answer the runner does not know is wait", answer["action"] == "parked" and answer["gate"]["id"] == "gate-1", answer)
result = run.call("next", {"item": "I123", "gateAnswer": "approved"})
check("a gate answer that is not an object is refused", refused(result, "bad-request"), result[3])

# --- changes, a stale proof, then approval -----------------------------------------------------
answer = run.next(gateAnswer={"data": {"gate": {"id": "gate-1", "status": "changes", "note": "Rename the button to Export CSV"}}})
check("a changes answer is address-changes, with the person's note and the next attempt",
      answer["action"] == "address-changes" and answer["note"] == "Rename the button to Export CSV" and answer["attempt"] == 2, answer)
check("the runner sends no report for a person's answer (the tracker wrote it)", gate_reports(answer) == [], gate_reports(answer))
commit(run.repo, "export.txt", "export csv\n", "rename the button")
answer = run.next()
check("after the fix, an earlier step whose proof went stale runs again before the gate",
      answer["action"] == "run" and answer["step"]["id"] in ("risk-check", "local-checks"), answer)
answer = run.to_gate()
check("then the gate is requested again, attempt 2", answer["action"] == "request-gate" and answer["attempt"] == 2, answer)
answer = run.done(requested("gate-2", wrapped=False))
check("a second request parks on the new gate", answer["action"] == "parked" and answer["gate"]["id"] == "gate-2", answer)
answer = run.next(gateAnswer={"id": "gate-2", "status": "approved", "answeredBy": "pat"})
check("an approval moves the run on to the next step", answer["action"] == "run" and answer["step"]["id"] == "review", answer)
check("an approval is recorded done and reported by no one but the tracker",
      gate_reports(answer) == [] and run.state()["steps"]["approve"]["status"] == "done"
      and run.state()["steps"]["approve"]["verdict"] == "APPROVAL: APPROVED", run.state()["steps"]["approve"])
while run.answer["action"] == "run":
    run.done()
check("the approved run finishes", run.answer["action"] == "finished" and run.answer["outcome"] == "completed", run.answer)

# --- rejected, unavailable, a request with no gate --------------------------------------------
rejected = Driver()
rejected.to_gate()
rejected.done(requested("gate-r"))
answer = rejected.next(gateAnswer={"id": "gate-r", "status": "rejected", "note": "Not this sprint"})
check("a rejection stops the run with APPROVAL: REJECTED, ending it failed",
      answer["action"] == "stopped" and answer["kind"] == "failed" and answer["reason"].startswith("APPROVAL: REJECTED")
      and answer["stepId"] == "approve" and closes(answer, "failed"), answer)
unavailable = Driver()
unavailable.to_gate()
answer = unavailable.done("APPROVAL: UNAVAILABLE the gate tools are not offered\n")
check("APPROVAL: UNAVAILABLE stops the run at the gate; it never goes on unapproved",
      answer["action"] == "stopped" and answer["kind"] == "failed" and answer["stepId"] == "approve"
      and answer["reason"] == "APPROVAL: UNAVAILABLE the gate tools are not offered"
      and unavailable.call("next", {"item": "I123"})[1]["action"] == "stopped", answer)
nameless = Driver()
nameless.to_gate()
answer = nameless.done("APPROVAL: REQUESTED\n```json\n{\"status\": \"pending\"}\n```\n")
check("a request whose answer names no gate stops the run rather than waiting on nothing",
      answer["action"] == "stopped" and answer["kind"] == "failed" and "names no gate" in answer["reason"], answer)

check("an unavailable gate sends no failed report for the gate step (DevStride writes a gate's outcome), only the run's end",
      gate_reports(answer, "failed") == [] and closes(answer, "failed"), answer.get("reports"))

# --- get_workflow_gate's own answer: { gateId, runId, stepId, attempt, kind, status, answer, note, answeredAt } -----
def spec_gate(driver, gate_id, status, decision=None, note=None, wrapped=False):
    body = {"gateId": gate_id, "runId": driver.answer["runId"], "stepId": "approve", "attempt": 1, "kind": "approval",
            "status": status, "answer": decision, "note": note, "answeredAt": None if decision is None else SINCE}
    return {"data": body} if wrapped else body


for wrapped in (False, True):
    shape = "wrapped in data" if wrapped else "bare"
    spec = Driver()
    spec.to_gate()
    spec.done(requested("gate-s"))
    answer = spec.next(gateAnswer=spec_gate(spec, "gate-s", "pending", wrapped=wrapped))
    check("the tracker's pending gate (%s) is wait" % shape, answer["action"] == "parked" and "note" not in answer, answer)
    answer = spec.next(gateAnswer=spec_gate(spec, "gate-s", "answered", "approve", wrapped=wrapped))
    check("the tracker's answered approve (%s) moves the run on, sending no gate report" % shape,
          answer["action"] == "run" and answer["step"]["id"] == "review" and gate_reports(answer) == []
          and spec.state()["steps"]["approve"]["verdict"] == "APPROVAL: APPROVED", answer)
    spec = Driver()
    spec.to_gate()
    spec.done(requested("gate-c"))
    answer = spec.next(gateAnswer=spec_gate(spec, "gate-c", "answered", "changes", "Add a test", wrapped=wrapped))
    check("the tracker's answered changes (%s) is address-changes with its note" % shape,
          answer["action"] == "address-changes" and answer["note"] == "Add a test" and answer["attempt"] == 2, answer)
    spec = Driver()
    spec.to_gate()
    spec.done(requested("gate-j"))
    answer = spec.next(gateAnswer=spec_gate(spec, "gate-j", "answered", "reject", "Not now", wrapped=wrapped))
    check("the tracker's answered reject (%s) stops the run with APPROVAL: REJECTED" % shape,
          answer["action"] == "stopped" and answer["kind"] == "failed" and answer["reason"].startswith("APPROVAL: REJECTED")
          and gate_reports(answer) == [] and closes(answer, "failed"), answer)
    spec = Driver()
    spec.to_gate()
    spec.done(requested("gate-w"))
    answer = spec.next(gateAnswer=spec_gate(spec, "gate-w", "withdrawn", wrapped=wrapped))
    check("the tracker's withdrawn gate (%s) ends the run interrupted, saying why, and never goes on" % shape,
          answer["action"] == "finished" and answer["outcome"] == "interrupted" and "withdrawn" in answer["note"]
          and gate_reports(answer) == [] and closes(answer, "interrupted")
          and spec.call("next", {"item": "I123"})[1]["action"] == "finished", answer)
    spec = Driver()
    spec.to_gate()
    spec.done(requested("gate-k"))
    answer = spec.next(gateAnswer=spec_gate(spec, "gate-k", "answered", "done", wrapped=wrapped))
    check("an answered gate with a checkpoint's answer (%s) is wait, never approved" % shape,
          answer["action"] == "parked" and spec.state()["steps"]["approve"]["status"] == "parked", answer)
mcp = Driver()
mcp.to_gate()
mcp.done(requested("gate-m"))
answer = mcp.next(gateAnswer={"data": {"gate": spec_gate(mcp, "gate-m", "answered", "approve")}})
check("an answered approve wrapped twice, as an MCP answer may be, moves the run on", answer["action"] == "run"
      and answer["step"]["id"] == "review", answer)
other = Driver()
other.to_gate()
other.done(requested("gate-o"))
result = other.next(gateAnswer={"gateId": "gate-other", "status": "answered", "answer": "approve"})
check("the tracker's approve of another gate is wait", result["action"] == "parked" and "not for this gate" in result["note"], result)

# --- the fifth attempt -------------------------------------------------------------------------
looped = Driver()
looped.to_gate()
attempts = []
for n in range(1, 6):
    attempts.append(looped.answer.get("attempt"))
    looped.done(requested("gate-%d" % n))
    answer = looped.next(gateAnswer={"id": "gate-%d" % n, "status": "changes", "note": "again"})
    if answer["action"] == "address-changes":
        looped.next()
check("four changes loops ask again each time; the changes on the fifth attempt stop for a person",
      attempts == [1, 2, 3, 4, 5] and answer["action"] == "stopped" and answer["kind"] == "attempts-exhausted", (attempts, answer))
answer = looped.send("resume", {"item": "I123", "workflow": "build"})
check("a person can resume after that: the gate is requested again", answer["action"] == "request-gate" and answer["attempt"] == 6, answer)

# --- a parked run adopted by another session ------------------------------------------------------
parked = Driver()
parked.to_gate()
parked.done(requested("gate-p"))
answer = parked.send("resume", {"item": "I123", "workflow": "build"}, session="s2")
check("resume with the item adopts the parked run and asks the story claim again first",
      answer is not None and answer["action"] == "run" and answer["step"]["id"] == "claim" and answer["adoptedFrom"]["sessionId"] == "s1",
      parked.result[3] or answer)
check("the adopted run reports under the new session, and the old session's file is gone",
      all(call["sessionId"] == "s2" for call in answer["reports"]) and not os.path.exists(
          os.path.join(parked.cache, "devstride-plugin", "workflows", "s1.I123.json")), answer["reports"])
parked.session = "s2"
answer = parked.done()
check("once the claim is held again, the run is back at its gate", answer["action"] == "parked" and answer["gate"]["id"] == "gate-p", answer)
check("the claim asked again keeps its place: the steps after it are not run again", parked.state()["steps"]["start"]["attempt"] == 1)
held = Driver()
held.to_gate()
held.done(requested("gate-h"))
held.send("resume", {"item": "I123", "workflow": "build"}, session="s3")
held.session = "s3"
answer = held.done("CLAIM: HELD session-elsewhere\n```json\n{\"state\": \"held\"}\n```\n")
check("if another session holds the story now, the adopted run ends held", answer["action"] == "finished" and answer["outcome"] == "held", answer)

# --- a checkpoint: a step a person does by hand ---------------------------------------------------
CHECK = {"id": "by-hand", "name": "Try the export by hand", "summary": "Export one board to CSV and open it.", "contract": "checkpoint@1",
         "kind": "step", "run": {"source": "builtin", "ref": "checkpoint", "version": None}, "when": {"mode": "manual", "condition": None},
         "onFail": "stop", "answerers": [{"kind": "item-owner"}]}


def checked(on_fail="stop"):
    definition = copy.deepcopy(FIX["definitions"]["build"])
    for phase in definition["phases"]:
        for at, one in enumerate(phase["steps"]):
            if one["id"] == "local-checks":
                phase["steps"].insert(at + 1, dict(copy.deepcopy(CHECK), onFail=on_fail))
                return definition


def asked(gate_id):
    return "CHECKPOINT: REQUESTED\nasked the item's owner\n```json\n%s\n```\n" % json.dumps(
        {"data": {"id": gate_id, "status": "pending", "attempt": 1, "requestedAt": SINCE}})


def marked(driver, gate_id, decision):
    return {"gateId": gate_id, "runId": driver.answer["runId"], "stepId": "by-hand", "attempt": 1, "kind": "checkpoint",
            "status": "answered", "answer": decision, "note": None, "answeredAt": SINCE}


def checkpoint_reports(answer):
    return [r for call in answer.get("reports", []) for r in call.get("reports", []) if r.get("stepId") == "by-hand"]


for label, edits, code in (
        ("a checkpoint run by a skill", {"run": {"source": "builtin", "ref": "sync-base", "version": None}}, "unsupported-checkpoint"),
        ("a checkpoint that always runs", {"when": {"mode": "always", "condition": None}}, "unsupported-checkpoint"),
        ("a manual step with another contract", {"contract": "custom@1"}, "unsupported-checkpoint")):
    definition = checked()
    for phase in definition["phases"]:
        for one in phase["steps"]:
            if one["id"] == "by-hand":
                one.update(copy.deepcopy(edits))
                if one["when"]["mode"] != "manual":
                    one.pop("answerers")  # answerers belong to a gate or a manual step only (bad-schema otherwise)
    attempt = Driver(definition)
    check("start refuses %s (%s)" % (label, code), refused(attempt.result, code), attempt.result[3])
for label, definition in (("a blocking checkpoint", checked()), ("a checkpoint the run does not wait for", checked("continue"))):
    attempt = Driver(definition, rehearsal=False)
    check("not switched on: %s handed to start is refused (skill-dormant) and nothing is written" % label,
          refused(attempt.result, "skill-dormant") and attempt.written() == [], attempt.result[3])
cp = Driver(checked())
answer = cp.to_gate()
check("at a checkpoint next hands out request-gate, kind checkpoint, blocking, with the person's instruction",
      answer["action"] == "request-gate" and answer["step"]["id"] == "by-hand" and answer["kind"] == "checkpoint"
      and answer["blocking"] is True and answer["contract"] == "checkpoint@1" and answer["tool"] == "request_workflow_gate"
      and answer["instruction"] == CHECK["summary"] and answer["arguments"]["stepId"] == "by-hand", answer)
result = cp.call("done", {"item": "I123", "stepId": "by-hand", "attempt": 1, "output": "CHECKPOINT: DONE\n"})
check("an agent cannot mark a checkpoint done itself", refused(result, "gate-answered-by-agent"), result[3])
answer = cp.done(asked("cp-1"))
check("CHECKPOINT: REQUESTED parks the run at a blocking checkpoint, reported waiting",
      answer["action"] == "parked" and answer["gate"]["id"] == "cp-1"
      and [(r["status"], r["verdict"]) for r in checkpoint_reports(answer)] == [("waiting", "CHECKPOINT: REQUESTED")], answer)
status = cp.call("status", {"item": "I123"})[1]
check("status names the checkpoint the run waits at", status["parkedAt"] == {"id": "cp-1", "since": SINCE, "stepId": "by-hand"}, status)
answer = cp.next(gateAnswer=marked(cp, "cp-1", "approve"))
check("an approval is not an answer to a checkpoint: still waiting", answer["action"] == "parked", answer)
answer = cp.next(gateAnswer={"data": marked(cp, "cp-1", "done")})
check("done moves the run on to the review, and the runner sends no report for the person's answer",
      answer["action"] == "run" and answer["step"]["id"] == "review" and checkpoint_reports(answer) == []
      and cp.state()["steps"]["by-hand"]["verdict"] == "CHECKPOINT: DONE", answer)
while cp.answer["action"] == "run":
    cp.done()
check("the run with a done checkpoint finishes", cp.answer["action"] == "finished" and cp.answer["outcome"] == "completed", cp.answer)
cp = Driver(checked())
cp.to_gate()
cp.done(asked("cp-2"))
answer = cp.next(gateAnswer=marked(cp, "cp-2", "skipped"))
check("skipped moves the run on, the checkpoint recorded skipped", answer["action"] == "run" and answer["step"]["id"] == "review"
      and cp.state()["steps"]["by-hand"]["status"] == "skipped" and cp.state()["steps"]["by-hand"]["verdict"] == "CHECKPOINT: SKIPPED", answer)
cp = Driver(checked())
cp.to_gate()
cp.done(asked("cp-3"))
answer = cp.next(gateAnswer={"gateId": "cp-3", "status": "withdrawn"})
check("a withdrawn blocking checkpoint ends the run interrupted", answer["action"] == "finished" and answer["outcome"] == "interrupted", answer)
cp = Driver(checked())
cp.to_gate()
answer = cp.done("CHECKPOINT: UNAVAILABLE the checkpoint tools are not offered\n")
check("a blocking checkpoint that cannot be requested stops the run", answer["action"] == "stopped" and answer["stepId"] == "by-hand"
      and answer["reason"] == "CHECKPOINT: UNAVAILABLE the checkpoint tools are not offered", answer)
cp = Driver(checked("continue"))
answer = cp.to_gate()
check("a non-blocking checkpoint is requested with blocking false", answer["action"] == "request-gate" and answer["blocking"] is False, answer)
answer = cp.done(asked("cp-4"))
check("once requested, a non-blocking checkpoint is left waiting and the run goes on to the review at once",
      answer["action"] == "run" and answer["step"]["id"] == "review" and cp.state()["steps"]["by-hand"]["status"] == "open", answer)
while cp.answer["action"] == "run":
    cp.done()
check("the finished run lists the checkpoint still open", cp.answer["action"] == "finished"
      and cp.answer["openCheckpoints"] == [{"stepId": "by-hand", "gateId": "cp-4"}], cp.answer)
cp = Driver(checked("continue"))
cp.to_gate()
answer = cp.done("CHECKPOINT: UNAVAILABLE the checkpoint tools are not offered\n")
check("a non-blocking checkpoint that cannot be requested is recorded failed and the run goes on",
      answer["action"] == "run" and answer["step"]["id"] == "review" and cp.state()["steps"]["by-hand"]["status"] == "failed", answer)
cp = Driver(checked(), session="s4")
cp.to_gate()
cp.done(asked("cp-5"))
answer = cp.send("resume", {"item": "I123", "workflow": "build"}, session="s5")
check("a run parked at a checkpoint is adopted by resume, asking the story claim again first",
      answer is not None and answer["action"] == "run" and answer["step"]["id"] == "claim" and answer["adoptedFrom"]["sessionId"] == "s4", answer)
cp.session = "s5"
answer = cp.done()
check("then it is back at its checkpoint", answer["action"] == "parked" and answer["gate"]["id"] == "cp-5", answer)

PY
OUT="$(python3 -B "$WORK/cases.py" "$ROOT" "$WORK" 2>&1)"; RC=$?
printf '%s\n' "$OUT" | sed 's/^/  /'
N="$(printf '%s\n' "$OUT" | grep -c '^ok')"
if [ $RC -ne 0 ] || printf '%s\n' "$OUT" | grep -q '^FAIL'; then bad "a case failed or the script did not finish (exit $RC)"
elif [ "$N" -lt 95 ]; then bad "only $N cases ran, expected at least 95"
else ok "(all $N cases passed)"; fi
exit $FAIL
