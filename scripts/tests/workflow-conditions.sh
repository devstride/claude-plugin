#!/bin/bash
# Tests for conditional steps, non-blocking steps and checkpoints in
# skills/run-workflow/scripts/workflow.py. Every string in schemas/when-condition-fixtures.json is
# accepted or refused by the runner's parser and by start exactly as the fixture file says (the same
# file DevStride's own parser reads). Then small workflows are driven with canned answers: each
# predicate true, false and negated; need-facts when a fact is missing; a fact passed as null runs the
# step and says why; touches through the one glob matcher (routing.py), anchored; step-verdict and
# review-path from the run's own record; the skipped report and its cap; a non-blocking step whose
# failure is recorded and gone past, never a held run; blocking and non-blocking checkpoints; a
# required step found skipped in the state file still blocks the step that needs its proof. And no
# built-in workflow holds a gate, a manual step, a step that carries on, or a condition other than
# the review path. Everything happens in a throwaway directory: its own cache folder, a copy of the
# plugin whose step skills are placeholders, and small git repositories. No network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
# The step runner sends a run's history itself, with this machine's own DevStride key. No test may
# find one: each runs with a home folder of its own, no key in its environment, and the one
# address a call could go to set to a port of this machine that nothing listens on.
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/home/.config" DEVSTRIDE_PLUGIN_TEST_URL="http://127.0.0.1:9"; mkdir -p "$HOME"
unset CLAUDE_CONFIG_DIR DEVSTRIDE_API_KEY DEVSTRIDE_API_SECRET DEVSTRIDE_ORG_ID DEVSTRIDE_ORG_SLUG DEVSTRIDE_BASE_URL
export PYTHONDONTWRITEBYTECODE=1
unset CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID XDG_CACHE_HOME GIT_DIR GIT_WORK_TREE

cat > "$WORK/cases.py" <<'PY'
import copy, glob, importlib.util, json, os, re, shutil, subprocess, sys

ROOT, WORK = sys.argv[1], sys.argv[2]


def told(answer, cache):
    """The runner hands out no step reports: it journals one event a transition and sends them
    itself. Nothing here has a DevStride to send to, so `reports` on an answer below is what that
    one command journaled, read from the run's outbox by the scenario driver (run_scenarios.py)."""
    if not TOLD:
        import importlib.util
        spec = importlib.util.spec_from_file_location("run_scenarios", os.path.join(ROOT, "scripts/tests/run_scenarios.py"))
        TOLD.append(importlib.util.module_from_spec(spec))
        spec.loader.exec_module(TOLD[0])
        TOLD.append({})
    return TOLD[0].told(answer, cache, TOLD[1])


TOLD = []
RUNNER = "skills/run-workflow/scripts/workflow.py"
FIX = json.load(open(os.path.join(ROOT, "skills/run-workflow/scripts/workflow-fixtures.json"), encoding="utf-8"))
CASES = json.load(open(os.path.join(ROOT, "schemas/when-condition-fixtures.json"), encoding="utf-8"))["cases"]
CATALOG = json.load(open(os.path.join(ROOT, "schemas/step-contracts.json"), encoding="utf-8"))["contracts"]
SKILLS = ["claim-story", "story-lifecycle", "branch-feature", "ultracode-build", "risk-check", "local-checks", "review-story",
          "merge-story", "capture-findings", "sync-base"]
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
    for path in (".claude-plugin/plugin.json", "schemas/step-contracts.json", "schemas/when-condition-fixtures.json", RUNNER,
                 "skills/build-item/scripts/workflow_report.py", "skills/build-item/scripts/claim_record.py",
                 "skills/build-item/scripts/session_stop.py", "skills/build-item/scripts/portable.py",
                 "skills/build-item/scripts/routing.py"):
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


def new_repo(remote=True):
    """A repository on a branch called feature, one commit ahead of main (origin/main follows main)."""
    repo = fresh("repo")
    git(repo, "init", "-q")
    git(repo, "checkout", "-q", "-b", "main")
    commit(repo, "readme.txt", "one\n", "first")
    git(repo, "symbolic-ref", "refs/remotes/origin/main", "refs/heads/main")
    git(repo, "checkout", "-q", "-b", "feature")
    commit(repo, "export.txt", "export\n", "add the export")
    if remote:
        git(repo, "remote", "add", "origin", "https://github.com/acme/widgets.git")
    return repo


DIFF = ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-relative", "--src-prefix=a/", "--dst-prefix=b/",
        "--ignore-submodules=none", "--unified=3", "--no-renames", "--diff-algorithm=myers", "--inter-hunk-context=0"]


def canned(contract, repo):
    patch = git(repo, "patch-id", "--verbatim", stdin=git(repo, *(DIFF + ["main...HEAD", "--"]))).decode().split()
    facts = {"head": git(repo, "rev-parse", "HEAD").decode().strip(), "tree": git(repo, "rev-parse", "HEAD^{tree}").decode().strip(),
             "patchId": patch[0] if patch else ""}
    text = FIX["outputs"].get(contract, "")
    for key, value in facts.items():
        text = text.replace("{%s}" % key, value)
    return text


def step(step_id, contract="start@1", mode="always", condition=None, on_fail="stop", **extra):
    ref = {"start@1": "story-lifecycle", "claim@1": "claim-story", "checkpoint@1": "checkpoint", "approval@1": "gate"}[contract]
    kind = "gate" if contract == "approval@1" else "step"
    out = {"id": step_id, "name": step_id.replace("-", " ").capitalize(), "summary": extra.pop("summary", ""), "contract": contract,
           "kind": kind, "run": {"source": "builtin", "ref": ref, "version": None},
           "when": {"mode": mode, "condition": condition}, "onFail": on_fail}
    out.update(extra)
    return out


def small(*steps):
    """A one-phase workflow of the given steps, after a first step that always runs."""
    build = FIX["definitions"]["build"]
    return {"schema": 1, "id": "conditions", "version": 1, "name": "Conditions", "startsWhen": "item-picked-up", "endsBy": None,
            "appliesTo": {"workTypes": [], "tags": [], "repositories": []}, "minPluginVersion": build["minPluginVersion"],
            "phases": [{"id": "only", "name": "Only", "steps": [step("first")] + list(steps)}]}


def in_build(after, extra):
    definition = copy.deepcopy(FIX["definitions"]["build"])
    for phase in definition["phases"]:
        for at, one in enumerate(phase["steps"]):
            if one["id"] == after:
                phase["steps"].insert(at + 1, copy.deepcopy(extra))
                return definition
    raise KeyError(after)


START_OUT = {"MOVED": FIX["outputs"]["start@1"], "UNCHANGED": FIX["outputs"]["start@1"].replace("START: MOVED In Progress", "START: UNCHANGED")}


class Driver:
    def __init__(self, definition, remote=True, facts=None, session="s1"):
        self.root, self.cache, self.repo = plugin(), fresh("cache"), new_repo(remote)
        self.session = session
        request = {"definition": definition, "context": dict(FIX["context"], cwd=self.repo)}
        if facts is not None:
            request["facts"] = facts
        if any(one["kind"] == "gate" or one["when"]["mode"] == "manual" for phase in definition["phases"] for one in phase["steps"]):
            # A gate or a checkpoint is not switched on yet (scripts/tests/workflow-gates.sh): a walk through one is a rehearsal.
            request["rehearsal"] = True
        self.result = self.call("start", request)
        self.answer = self.result[1]

    def call(self, command, request):
        env = dict((k, v) for k, v in os.environ.items() if k not in ("CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID"))
        env["XDG_CACHE_HOME"] = self.cache
        request = dict(request, session=self.session)
        done = subprocess.run([sys.executable, "-B", os.path.join(self.root, RUNNER), command], input=json.dumps(request),
                              capture_output=True, text=True, env=env, cwd=self.repo)
        answer = told(json.loads(done.stdout), self.cache) if done.returncode == 0 else None
        return done.returncode, answer, done.stdout, done.stderr

    def send(self, command, request):
        self.result = self.call(command, request)
        if self.result[1] is not None:
            self.answer = self.result[1]
        return self.result[1]

    def done(self, output=None, **extra):
        one = self.answer["step"]
        if output is None:
            output = START_OUT["MOVED"] if one["contract"] == "start@1" else canned(one["contract"], self.repo)
        return self.send("done", dict(extra, item="I123", stepId=one["id"], attempt=one["attempt"], output=output))

    def next(self, **request):
        return self.send("next", dict(request, item="I123"))

    def through(self, **extra):
        """Answer every run action with its passing answer until something else comes."""
        while self.answer and self.answer["action"] == "run":
            self.done(**extra)
        return self.answer

    def state(self):
        return json.load(open(os.path.join(self.cache, "devstride-plugin", "workflows", "%s.I123.json" % self.session)))

    def put_state(self, state):
        path = os.path.join(self.cache, "devstride-plugin", "workflows", "%s.I123.json" % self.session)
        with open(path, "w") as out:
            json.dump(state, out)


def refused(result, code):
    rc, _, out, err = result
    return rc == 2 and out == "" and re.match(r"^workflow: %s: [^\n]+\n$" % re.escape(code), err) is not None


def reports(answer, step_id):
    return [r for call in (answer or {}).get("reports", []) for r in call.get("reports", []) if r.get("stepId") == step_id]


def requested(gate_id):
    return "CHECKPOINT: REQUESTED\nasked the person\n```json\n%s\n```\n" % json.dumps(
        {"data": {"id": gate_id, "status": "pending", "attempt": 1, "requestedAt": SINCE}})


def answered(gate_id, word):
    return {"gateId": gate_id, "stepId": "by-hand", "attempt": 1, "kind": "checkpoint", "status": "answered", "answer": word,
            "note": None, "answeredAt": SINCE}


# --- the grammar: every fixture, through the parser and through start ----------------------------
spec = importlib.util.spec_from_file_location("workflow_under_test", os.path.join(ROOT, RUNNER))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
runner.load_helpers()
wrong = []
for case in CASES:
    try:
        runner.parse_condition(case["text"])
        accepted = True
    except runner.BadCondition:
        accepted = False
    if accepted != case["valid"]:
        wrong.append(case["text"][:60])
check("the parser accepts and refuses every one of the %d fixture strings as the fixture file says" % len(CASES), wrong == [], wrong)
check("the fixture file holds both kinds and each predicate", len([c for c in CASES if c["valid"]]) >= 15
      and len([c for c in CASES if not c["valid"]]) >= 30
      and all(any(c["valid"] and c["text"].lstrip("!").startswith(name) for c in CASES) for name in runner.PREDICATES))

build_steps = dict((one["id"], one["contract"]) for phase in FIX["definitions"]["build"]["phases"] for one in phase["steps"])
root = plugin()
cache, repo = fresh("cache"), new_repo()
env = dict((k, v) for k, v in os.environ.items() if k not in ("CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID"))
env["XDG_CACHE_HOME"] = cache
mismatched = []
for n, case in enumerate(CASES):
    extra = step("extra", contract="claim@1", mode="condition", condition=case["text"])
    definition = in_build("sync", extra)
    expected = case["valid"]
    if case["valid"] and case["text"].lstrip("!").startswith("step-verdict:"):
        named, _, word = case["text"].lstrip("!")[len("step-verdict:"):].partition(":")
        # A step-verdict the grammar accepts is checked against the definition too, as DevStride's validator does.
        expected = named in build_steps and word in [v["value"] for v in CATALOG[build_steps[named]]["verdict"]["values"]]
    request = {"definition": definition, "context": dict(FIX["context"], cwd=repo), "session": "grammar-%d" % n}
    done = subprocess.run([sys.executable, "-B", os.path.join(root, RUNNER), "start"], input=json.dumps(request),
                          capture_output=True, text=True, env=env, cwd=repo)
    good = done.returncode == 0 if expected else refused((done.returncode, None, done.stdout, done.stderr), "bad-condition")
    if not good:
        mismatched.append((case["text"][:60], done.returncode, done.stderr.strip()[:160]))
check("start accepts every fixture the grammar accepts and refuses every other with bad-condition", mismatched == [], mismatched)

# --- each predicate, true, false and negated ---------------------------------------------------
def outcome(condition, facts=None, remote=True):
    """What becomes of a conditional step after the first: (ran, the answer at it)."""
    run = Driver(small(step("maybe", mode="condition", condition=condition)), remote=remote)
    run.done(facts=facts or {})
    return run.answer["action"] == "run" and run.answer["step"]["id"] == "maybe", run


for label, condition, facts, remote, ran in (
        ("an item that carries the tag", "item-tag:needs-qa", {"itemTags": ["needs-qa", "export"]}, True, True),
        ("a tag compared without regard to case", "item-tag:Needs-QA", {"itemTags": ["needs-qa"]}, True, True),
        ("an item without the tag", "item-tag:needs-qa", {"itemTags": ["export"]}, True, False),
        ("NOT the tag, on an item without it", "!item-tag:needs-qa", {"itemTags": []}, True, True),
        ("NOT the tag, on an item with it", "!item-tag:needs-qa", {"itemTags": ["needs-qa"]}, True, False),
        ("a tag with a colon in it", "item-tag:area:billing", {"itemTags": ["area:billing"]}, True, True),
        ("the item's type", "item-work-type:Defect", {"workType": "defect"}, True, True),
        ("another type", "item-work-type:Defect", {"workType": "Story"}, True, False),
        ("NOT the type", "!item-work-type:Defect", {"workType": "Story"}, True, True),
        ("**/events/** against a file in an events folder", "touches:**/events/**", {"changedPaths": ["backend/src/events/x.ts"]}, True, True),
        ("events alone, which matches no path but events itself", "touches:events", {"changedPaths": ["backend/src/events/x.ts"]}, True, False),
        ("* is one path segment", "touches:docs/*.md", {"changedPaths": ["docs/guide/start.md"]}, True, False),
        ("* within one segment", "touches:docs/*.md", {"changedPaths": ["readme.txt", "docs/start.md"]}, True, True),
        ("a changed-paths list with no match", "touches:backend/**", {"changedPaths": ["frontend/a.vue", "docs/b.md"]}, True, False),
        ("no changed paths at all", "touches:backend/**", {"changedPaths": []}, True, False),
        ("NOT touching, with no match", "!touches:backend/**", {"changedPaths": ["docs/b.md"]}, True, True),
        ("a repository is present", "has-repository", None, True, True),
        ("no repository the tracker can name", "has-repository", None, False, False),
        ("NOT a repository, where there is none", "!has-repository", None, False, True),
        ("an earlier step's verdict", "step-verdict:first:MOVED", None, True, True),
        ("an earlier step's other verdict", "step-verdict:first:UNCHANGED", None, True, False),
        ("NOT an earlier step's verdict", "!step-verdict:first:UNCHANGED", None, True, True)):
    did, run = outcome(condition, facts if facts is not None else {}, remote)
    check("%s: %s %s" % (condition, label, "runs the step" if ran else "skips it"), did == ran,
          (run.answer.get("action"), run.answer.get("step"), run.result[3]))
    if not ran:
        check("%s: the skipped step is reported skipped, its reason the condition, and the run goes on" % condition,
              [(r["status"], r.get("verdict")) for r in reports(run.answer, "maybe")] == [("skipped", "SKIPPED: %s was false" % condition)]
              and run.answer["action"] == "finished" and run.answer["skippedByCondition"] == ["maybe"], reports(run.answer, "maybe"))

# --- facts: asked for when missing, and a fact nobody knows runs the step --------------------------
run = Driver(small(step("maybe", mode="condition", condition="touches:**/*.md")))
answer = run.done()
check("a missing fact is asked for: need-facts names it, and nothing is recorded for the step",
      answer["action"] == "need-facts" and answer["needs"] == ["changedPaths"] and answer["step"]["id"] == "maybe"
      and answer["condition"] == "touches:**/*.md" and run.state()["steps"]["maybe"]["status"] == "pending", answer)
again = run.next()
check("asked again without the facts, the answer is the same", again["action"] == "need-facts" and again["needs"] == ["changedPaths"], again)
answer = run.next(facts={"changedPaths": ["docs/a.md"]})
check("next with the facts decides it: the step runs", answer["action"] == "run" and answer["step"]["id"] == "maybe", answer)
run.done()
check("the run then finishes, with nothing skipped or failed", run.answer["action"] == "finished" and run.answer["skippedByCondition"] == []
      and run.answer["continuedPastFailures"] == [] and run.answer["openCheckpoints"] == [], run.answer)
run = Driver(small(step("maybe", mode="condition", condition="item-tag:needs-qa")))
answer = run.done(facts={"itemTags": None})
check("a fact passed as null: the step runs", answer["action"] == "run" and answer["step"]["id"] == "maybe", answer)
answer = run.done()
check("its evidence says the condition could not be decided, and why",
      [r["evidence"][0] for r in reports(answer, "maybe") if r["status"] == "done"] == ["condition could not be decided: itemTags unknown"],
      reports(answer, "maybe"))
run = Driver(small(step("maybe", mode="condition", condition="!touches:**/*.md")), facts={"changedPaths": None})
check("facts given to start decide a condition there; a negated undecided condition runs the step too",
      run.answer["action"] == "run" and run.answer["step"]["id"] == "first", run.answer)
answer = run.done(facts={"changedPaths": None})
check("... the undecided negated condition runs its step", answer["action"] == "run" and answer["step"]["id"] == "maybe", answer)
run = Driver(small(step("maybe", mode="condition", condition="has-repository")))
result = run.call("next", {"item": "I123", "facts": {"changedPaths": "docs/a.md"}})
check("facts of the wrong shape are refused (bad-request)", refused(result, "bad-request"), result[3])
result = run.call("next", {"item": "I123", "facts": ["docs/a.md"]})
check("facts that are not an object are refused (bad-request)", refused(result, "bad-request"), result[3])

# --- the glob matcher is routing.py's, and the skipped verdict is capped -----------------------------
source = open(os.path.join(ROOT, RUNNER), encoding="utf-8").read()
check("touches uses routing.py's one matcher, loaded by path, and the runner defines none of its own",
      "build-item/scripts/routing.py" in source and "first_match(" in source and "def pattern_regex" not in source
      and "fnmatch" not in source and "glob.translate" not in source and not re.search(r"^def \w*glob\w*\(", source.replace("def glob_matcher(", ""), re.M))
result = Driver(small(step("maybe", mode="condition", condition="touches:release/<YY-MM-DD>/**"))).result
check("a touches glob with a branch date token is refused by start (bad-condition)", refused(result, "bad-condition"), result[3])
long_glob = "touches:" + "a/" * 74 + "**"
did, run = outcome(long_glob, {"changedPaths": ["b/c.txt"]})
verdicts = [r["verdict"] for r in reports(run.answer, "maybe")]
check("the skipped verdict carries the whole condition, at most 200 characters",
      not did and verdicts == ["SKIPPED: %s was false" % long_glob] and all(len(v) <= 200 for v in verdicts), verdicts)
check("the runner's skipped verdict is cut at 200 characters", len(runner.REPORT.clean_verdict("SKIPPED: %s was false" % ("x" * 300))) == 200)

# --- review-path and a gate on a condition, in the Build workflow --------------------------------
for condition, ran in (("review-path:fast", True), ("review-path:pull-request", False), ("!review-path:pull-request", True)):
    run = Driver(in_build("review", step("after-review", mode="condition", condition=condition)))
    answer = run.answer
    while answer["action"] == "run" and answer["step"]["id"] != "after-review":
        answer = run.done()
    if ran:
        check("%s after a fast local review runs the step" % condition, answer["action"] == "run" and answer["step"]["id"] == "after-review", answer)
    else:
        check("%s after a fast local review skips the step" % condition, run.state()["steps"]["after-review"]["status"] == "skipped"
              and run.state()["steps"]["after-review"]["verdict"] == "SKIPPED: %s was false" % condition, run.state()["steps"]["after-review"])
gate = step("approve", contract="approval@1", mode="condition", condition="item-tag:needs-approval")
run = Driver(in_build("local-checks", gate))
answer = run.through(facts={"itemTags": ["export"]})
check("a gate whose condition is false is skipped with its reason, and no approval is asked",
      run.state()["steps"]["approve"]["status"] == "skipped" and run.state()["steps"]["approve"]["verdict"].startswith("SKIPPED: item-tag")
      and answer["action"] == "finished" and answer["skippedByCondition"] == ["approve"], (answer.get("action"), run.state()["steps"]["approve"]))
run = Driver(in_build("local-checks", gate))
answer = run.through(facts={"itemTags": ["needs-approval"]})
check("a gate whose condition holds asks for approval as usual", answer["action"] == "request-gate" and answer["kind"] == "approval"
      and answer["blocking"] is True and answer["step"]["id"] == "approve", answer)

# --- non-blocking steps ---------------------------------------------------------------------------
loose = small(step("may-fail", on_fail="continue"), step("after"))
run = Driver(loose)
run.done()
answer = run.done("START: FAILED the board is locked\n")
check("a FAIL of a non-blocking step is recorded failed, and the run goes on to the next step",
      answer["action"] == "run" and answer["step"]["id"] == "after" and answer["recorded"]["status"] == "failed"
      and [(r["status"], r.get("verdict")) for r in reports(answer, "may-fail")] == [("failed", "START: FAILED the board is locked")], answer)
answer = run.done()
check("the finished answer lists the failure it went past, with its verdict, never as passed",
      answer["action"] == "finished" and answer["outcome"] == "completed"
      and answer["continuedPastFailures"] == [{"stepId": "may-fail", "verdict": "START: FAILED the board is locked"}]
      and run.state()["steps"]["may-fail"]["status"] == "failed", answer)
run = Driver(loose)
run.done()
answer = run.done("I could not do it\n")
check("a missing verdict on a non-blocking step is recorded failed and gone past too",
      answer["action"] == "run" and answer["step"]["id"] == "after" and run.state()["steps"]["may-fail"]["verdict"] == "No verdict", answer)
run = Driver(small(step("may-hold", contract="claim@1", on_fail="continue"), step("after")))
run.done()
answer = run.done("CLAIM: HELD session-elsewhere\n```json\n{\"state\": \"held\"}\n```\n")
check("a non-blocking step that holds the run still ends it held: an end is never gone past",
      answer["action"] == "finished" and answer["outcome"] == "held", answer)
run = Driver(small(step("strict"), step("after")))
run.done()
answer = run.done("START: FAILED the board is locked\n")
check("a step that stops on failure still stops the run", answer["action"] == "stopped" and answer["kind"] == "failed", answer)
for target, code in (("review", "required-not-stop"), ("merge", "required-not-stop"), ("risk-check", "required-not-stop"), ("local-checks", "required-not-stop")):
    definition = copy.deepcopy(FIX["definitions"]["build"])
    for phase in definition["phases"]:
        for one in phase["steps"]:
            if one["id"] == target:
                one["onFail"] = "continue"
    result = Driver(definition).result
    check("a required step (%s) may never carry on after a failure (%s)" % (target, code), refused(result, code), result[3])

# --- checkpoints ------------------------------------------------------------------------------------
def by_hand(on_fail="stop"):
    return step("by-hand", contract="checkpoint@1", mode="manual", on_fail=on_fail, summary="Click through the export by hand.",
                answerers=[{"kind": "item-owner"}])


run = Driver(small(by_hand(), step("after")))
answer = run.done()
check("a manual step hands out request-gate, kind checkpoint, blocking, with the person's instruction and no skill",
      answer["action"] == "request-gate" and answer["kind"] == "checkpoint" and answer["blocking"] is True
      and answer["contract"] == "checkpoint@1" and answer["instruction"] == "Click through the export by hand."
      and answer["tool"] == "request_workflow_gate" and "CHECKPOINT: REQUESTED" in answer["then"] and "skill" not in answer
      and [(r["status"], r["ran"]["ref"]) for r in reports(answer, "by-hand")] == [("running", "checkpoint")], answer)
before = run.state()
for verdict in ("CHECKPOINT: DONE", "CHECKPOINT: SKIPPED"):
    result = run.call("done", {"item": "I123", "stepId": "by-hand", "attempt": 1, "output": verdict + "\n"})
    check("an agent cannot answer a checkpoint itself: %s is refused" % verdict, refused(result, "gate-answered-by-agent"), result[3])
check("a refused answer changes nothing", run.state() == before)
answer = run.done(requested("cp-1"))
check("CHECKPOINT: REQUESTED on a blocking checkpoint parks the run", answer["action"] == "parked" and answer["gate"]["id"] == "cp-1"
      and [(r["status"], r.get("verdict")) for r in reports(answer, "by-hand")] == [("waiting", "CHECKPOINT: REQUESTED")], answer)
answer = run.next(gateAnswer=dict(answered("cp-1", "approve")))
check("an approval's answer on a checkpoint keeps it waiting", answer["action"] == "parked", answer)
answer = run.next(gateAnswer={"data": answered("cp-1", "done")})
check("the person's done moves the run on, journaled as the person's answer to that checkpoint",
      answer["action"] == "run" and answer["step"]["id"] == "after"
      and [(e["actor"], e["payload"]["gate"]["id"], e["payload"]["gate"]["status"]) for call in answer.get("reports", [])
           for e in call["events"] if e.get("stepId") == "by-hand"] == [("person", "cp-1", "done")]
      and run.state()["steps"]["by-hand"]["status"] == "done" and run.state()["steps"]["by-hand"]["verdict"] == "CHECKPOINT: DONE", answer)
run.done()
check("the run finishes with no checkpoint left open", run.answer["action"] == "finished" and run.answer["openCheckpoints"] == [], run.answer)
run = Driver(small(by_hand(), step("after")))
run.done()
run.done(requested("cp-2"))
answer = run.next(gateAnswer=answered("cp-2", "skipped"))
check("the person's skip moves the run on, the checkpoint recorded skipped",
      answer["action"] == "run" and answer["step"]["id"] == "after" and run.state()["steps"]["by-hand"]["status"] == "skipped"
      and run.state()["steps"]["by-hand"]["verdict"] == "CHECKPOINT: SKIPPED", answer)
run = Driver(small(by_hand(), step("after")))
run.done()
answer = run.done("CHECKPOINT: UNAVAILABLE the checkpoint tool is not offered\n")
check("CHECKPOINT: UNAVAILABLE stops a blocking checkpoint, journaled failed as the agent's own answer, naming no person's decision",
      answer["action"] == "stopped" and answer["kind"] == "failed" and answer["stepId"] == "by-hand"
      and [(e["actor"], e["payload"]["status"], "gate" in e["payload"]) for call in answer.get("reports", [])
           for e in call["events"] if e.get("stepId") == "by-hand"] == [("agent", "failed", False)], answer)
run = Driver(small(by_hand("continue"), step("after")))
answer = run.done()
check("a non-blocking checkpoint is requested with blocking false", answer["action"] == "request-gate" and answer["blocking"] is False, answer)
answer = run.done(requested("cp-3"))
check("a non-blocking checkpoint, once requested, is left waiting and the run goes on at once",
      answer["action"] == "run" and answer["step"]["id"] == "after" and run.state()["steps"]["by-hand"]["status"] == "open"
      and [r["status"] for r in reports(answer, "by-hand")] == ["waiting"], answer)
answer = run.done()
check("the finished answer lists the checkpoint still open", answer["action"] == "finished"
      and answer["openCheckpoints"] == [{"stepId": "by-hand", "gateId": "cp-3"}] and answer["continuedPastFailures"] == [], answer)
judged = runner.judge_run({"reports": [{"stepId": "first", "attempt": 1, "status": "done"}, {"stepId": "by-hand", "attempt": 1, "status": "waiting"},
                                       {"stepId": "after", "attempt": 1, "status": "done"}]}, small(by_hand("continue"), step("after")))
check("judge counts a run whose non-blocking checkpoint still waits as complete", judged == ("complete", []), judged)
run = Driver(small(by_hand("continue"), step("after")))
run.done()
answer = run.done("CHECKPOINT: UNAVAILABLE the checkpoint tool is not offered\n")
check("CHECKPOINT: UNAVAILABLE on a non-blocking checkpoint is recorded failed and gone past",
      answer["action"] == "run" and answer["step"]["id"] == "after" and run.state()["steps"]["by-hand"]["status"] == "failed", answer)
answer = run.done()
check("... and listed among the failures the run went past", answer["continuedPastFailures"] == [
    {"stepId": "by-hand", "verdict": "CHECKPOINT: UNAVAILABLE the checkpoint tool is not offered"}], answer)

# --- defence in depth: a required step found skipped -------------------------------------------------
run = Driver(copy.deepcopy(FIX["definitions"]["build"]))
while run.answer["action"] == "run" and run.answer["step"]["id"] != "risk-check":
    run.done()
state = run.state()
state["current"] = None
state["steps"]["build"].update(status="skipped", verdict="SKIPPED: has-repository was false")
state["steps"]["build"]["class"] = "skipped"
state["steps"]["risk-check"].update(status="pending", attempt=0)
run.put_state(state)
answer = run.next()
check("a required step marked skipped in the state file blocks the step that needs its proof, naming it",
      answer["action"] == "stopped" and answer["kind"] == "proof" and answer["stepId"] == "risk-check" and "build" in answer["reason"], answer)

# --- no built-in workflow uses any of it ------------------------------------------------------------
found = []
for path in sorted(glob.glob(os.path.join(ROOT, "workflows", "*.json"))):
    if os.path.basename(path) == "registry.json":
        continue  # the version record beside the definitions, not a definition
    for phase in json.load(open(path, encoding="utf-8"))["phases"]:
        for one in phase["steps"]:
            if (one["kind"] == "gate" or one["when"]["mode"] == "manual" or one["onFail"] != "stop"
                    or (one["when"]["condition"] or "review-path:").split(":")[0] != "review-path"):
                found.append("%s %s" % (os.path.basename(path), one["id"]))
check("no built-in workflow holds a gate, a manual step, a step that carries on, or a condition other than the review path", found == [], found)
PY
OUT="$(python3 -B "$WORK/cases.py" "$ROOT" "$WORK" 2>&1)"; RC=$?
printf '%s\n' "$OUT" | sed 's/^/  /'
N="$(printf '%s\n' "$OUT" | grep -c '^ok')"
if [ $RC -ne 0 ] || printf '%s\n' "$OUT" | grep -q '^FAIL'; then bad "a case failed or the script did not finish (exit $RC)"
elif [ "$N" -lt 70 ]; then bad "only $N cases ran, expected at least 70"
else ok "(all $N cases passed)"; fi
exit $FAIL
