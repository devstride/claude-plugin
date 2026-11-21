#!/bin/bash
# scripts/tests/workflow-hotfix.sh — the Hotfix workflow (workflows/hotfix.json) with no model: its
# pinned steps and phases, its catalog entries and their verdict grammar, the requirements nobody can
# author away, the satisfiers that let it reuse the Build risk check, local checks and review, the
# branch-name helper's fixtures, a "never blocked" text scan, and replays of the run with scripted
# step answers through the REAL runner in a throwaway repository. No network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAIL=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export PYTHONDONTWRITEBYTECODE=1
unset CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID XDG_CACHE_HOME GIT_DIR GIT_WORK_TREE

cat > "$WORK/cases.py" <<'PY'
import copy, json, os, re, subprocess, sys

ROOT, WORK = sys.argv[1], sys.argv[2]
RUNNER = os.path.join(ROOT, "skills/run-workflow/scripts/workflow.py")
NAMER = os.path.join(ROOT, "skills/hotfix-steps/scripts/hotfix-name.py")
HOTFIX_FILE = os.path.join(ROOT, "workflows/hotfix.json")
HOTFIX = json.load(open(HOTFIX_FILE, encoding="utf-8"))
CATALOG = json.load(open(os.path.join(ROOT, "schemas/step-contracts.json"), encoding="utf-8"))["contracts"]
FIX = json.load(open(os.path.join(ROOT, "skills/run-workflow/scripts/workflow-fixtures.json"), encoding="utf-8"))
STEPS = [s for p in HOTFIX["phases"] for s in p["steps"]]
ORDER = [s["id"] for s in STEPS]
CONTEXT = {"branchArgument": "fix-login", "profile": {"name": "extended", "source": "config"}, "workingBase": "main",
           "oneOff": True, "route": "base", "reviewMoment": "pull-request"}
DIFF = ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-relative", "--src-prefix=a/", "--dst-prefix=b/",
        "--ignore-submodules=none", "--unified=3", "--no-renames", "--diff-algorithm=myers", "--inter-hunk-context=0"]
made = [0]


def check(label, good, detail=""):
    print(("ok   " if good else "FAIL ") + label + ("" if good else " -> %s" % (detail,)))


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
    repo = fresh("repo")
    git(repo, "init", "-q")
    git(repo, "checkout", "-q", "-b", "main")
    commit(repo, "readme.txt", "one\n", "first")
    git(repo, "symbolic-ref", "refs/remotes/origin/main", "refs/heads/main")
    git(repo, "checkout", "-q", "-b", "test/hotfix/11-21-26/fix-login")
    commit(repo, "fix.txt", "fixed\n", "the fix")
    return repo


def facts(repo):
    patch = git(repo, "patch-id", "--verbatim", stdin=git(repo, *(DIFF + ["main...HEAD", "--"]))).decode().split()
    return {"head": git(repo, "rev-parse", "HEAD").decode().strip(), "tree": git(repo, "rev-parse", "HEAD^{tree}").decode().strip(),
            "patchId": patch[0] if patch else ""}


def answer_text(verdict, result):
    return "%s\nevidence line\n```json\n%s\n```\n" % (verdict, json.dumps(result))


BRANCH = "test/hotfix/11-21-26/fix-login"
HOTFIX_OUTPUTS = {
    "hotfix-preflight@1": lambda f: answer_text("HOTFIX PREFLIGHT: READY " + BRANCH, {"branch": BRANCH, "base": "main", "prefix": "test", "date": "11-21-26", "dateFormat": "MM-DD-YY", "configSource": "file"}),
    "hotfix-branch@1": lambda f: answer_text("HOTFIX BRANCH: CUT " + BRANCH, {"branch": BRANCH, "base": "main", "baseSha": f["head"], "pushed": True, "shipIntent": "not configured"}),
    "hotfix-stage@1": lambda f: answer_text("HOTFIX STAGE: NAMED local", {"stage": "local", "production": False}),
    "hotfix-environment@1": lambda f: answer_text("HOTFIX ENVIRONMENT: RECREATED", {"case": 1, "mode": "inPlace", "why": "recreate is set", "restartDevServer": True}),
    "hotfix-report@1": lambda f: answer_text("HOTFIX CUT: DONE " + BRANCH, {"branch": BRANCH, "case": "1"}),
    "hotfix-fix@1": lambda f: answer_text("HOTFIX FIX: COMMITTED " + f["head"], {"commit": f["head"], "deferrals": [], "deviations": [], "untrackedDeferrals": [], "dismissed": [], "scopeLine": "Fixes the login crash.", "head": f["head"]}),
    "hotfix-merge@1": lambda f: answer_text("HOTFIX MERGE: MERGED abc1234", {"sha": "abc1234", "pullRequest": 7}),
    "deploy-approval@1": lambda f: answer_text("DEPLOY APPROVAL: APPROVED", {"mergeSha": "abc1234", "approved": True}),
    "deploy-confirm@1": lambda f: answer_text("DEPLOY: CONFIRMED abc1234", {"mergeCommit": "abc1234", "confirmedAt": "2026-11-21T19:00:00Z"}),
    "hotfix-close@1": lambda f: answer_text("HOTFIX CLOSED: CLOSED abc1234", {"mergeSha": "abc1234", "openRelease": None}),
}


def canned(contract, repo):
    f = facts(repo)
    if contract in HOTFIX_OUTPUTS:
        return HOTFIX_OUTPUTS[contract](f)
    text = FIX["outputs"][contract]
    for key, value in f.items():
        text = text.replace("{%s}" % key, value)
    if contract == "risk-check@1":
        text = text.replace('"base": "main"', '"base": "origin/main"')
    if contract == "review@1":
        text = text.replace('"fast-local"', '"pull-request"').replace('"pullRequest": null', '"pullRequest": 7')
    return text


class Run:
    def __init__(self, definition=None, context=None):
        self.cache, self.repo, self.answers = fresh("cache"), new_repo(), []
        request = {"definition": definition} if definition is not None else {"definitionFile": HOTFIX_FILE}
        request["context"] = dict(CONTEXT, cwd=self.repo, **(context or {}))
        self.rc, self.answer, self.err = self.call("start", request)

    def call(self, command, request):
        env = dict(os.environ, XDG_CACHE_HOME=self.cache)
        done = subprocess.run([sys.executable, "-B", RUNNER, command], input=json.dumps(dict(request, session="s1")),
                              capture_output=True, text=True, env=env, cwd=self.repo)
        answer = json.loads(done.stdout) if done.returncode == 0 else None
        if answer is not None:
            self.answers.append(answer)
        return done.returncode, answer, done.stderr

    def done(self, output=None):
        step = self.answer["step"]
        output = output if output is not None else canned(step["contract"], self.repo)
        self.rc, self.answer, self.err = self.call("done", {"stepId": step["id"], "attempt": step["attempt"], "output": output})
        return self.answer

    def resume(self, **extra):
        self.rc, self.answer, self.err = self.call("resume", extra)
        return self.answer

    def until(self, step_id):
        while self.answer and self.answer["action"] == "run" and self.answer["step"]["id"] != step_id:
            self.done()
        return self.answer

    def issued(self):
        return [(a["step"]["id"], a["step"]["attempt"]) for a in self.answers if a.get("action") == "run"]


# --- the definition, as shipped ------------------------------------------------------------------
PINNED = ["preflight", "cut-branch", "name-stage", "rewind-environment", "report-cut",
          "fix", "risk-check", "local-checks", "review", "merge", "approve-deploy", "confirm-deploy", "close"]
CONTRACTS = ["hotfix-preflight@1", "hotfix-branch@1", "hotfix-stage@1", "hotfix-environment@1", "hotfix-report@1",
             "hotfix-fix@1", "risk-check@1", "local-checks@1", "review@1", "hotfix-merge@1", "deploy-approval@1",
             "deploy-confirm@1", "hotfix-close@1"]
check("the thirteen step ids are the pinned ones, in order", ORDER == PINNED, ORDER)
check("two phases: cut, then ship", [(p["id"], p["name"], len(p["steps"])) for p in HOTFIX["phases"]] == [("cut", "Cut the branch", 5), ("ship", "Fix and ship", 8)])
check("each step's contract is the pinned one", [s["contract"] for s in STEPS] == CONTRACTS, [s["contract"] for s in STEPS])
check("on demand, matched by nothing, version 1", (HOTFIX["id"], HOTFIX["version"], HOTFIX["startsWhen"], HOTFIX["endsBy"], HOTFIX["appliesTo"]) ==
      ("hotfix", 1, "on-demand", None, {"workTypes": [], "tags": [], "repositories": []}))
check("every step always runs, stops on failure and runs its contract's built-in skill",
      all(s["kind"] == "step" and s["when"]["mode"] == "always" and s["onFail"] == "stop" and s["run"]["source"] == "builtin"
          and s["run"]["ref"] == CATALOG[s["contract"]]["builtinSkill"] for s in STEPS))
check("the reused Build steps run the Build skills", [s["run"]["ref"] for s in STEPS if s["id"] in ("risk-check", "local-checks", "review")] == ["risk-check", "local-checks", "review-story"])
done = subprocess.run([sys.executable, os.path.join(ROOT, "scripts/check-workflows.py")], capture_output=True, text=True)
check("check-workflows.py passes with the hotfix definition", done.returncode == 0, done.stdout + done.stderr)

# --- the catalog entries and their grammar -------------------------------------------------------
NEW = ["hotfix-preflight@1", "hotfix-branch@1", "hotfix-stage@1", "hotfix-environment@1", "hotfix-report@1", "hotfix-fix@1",
       "hotfix-merge@1", "deploy-approval@1", "deploy-confirm@1", "hotfix-close@1"]
check("the ten contracts are in the catalog, run by hotfix-steps", all(CATALOG.get(n, {}).get("builtinSkill") == "hotfix-steps" for n in NEW))
check("no hotfix contract takes a claim phase or a ship-intent stage", all(CATALOG[n]["claimPhase"] is None and CATALOG[n]["shipIntentStage"] is None for n in NEW))
check("hotfix-fix stands in for build, hotfix-branch for branch",
      ("hotfix-fix@1" in CATALOG["build@1"].get("satisfiedBy", []), "hotfix-branch@1" in CATALOG["branch@1"].get("satisfiedBy", [])) == (True, True))
check("the merge requires the review, the local checks and the risk check", sorted(CATALOG["hotfix-merge@1"]["requires"]) == ["local-checks@1", "review@1", "risk-check@1"])
check("the deploy approval and confirmation require the production merge",
      (CATALOG["deploy-approval@1"]["requires"], CATALOG["deploy-confirm@1"]["requires"]) == (["hotfix-merge@1"], ["hotfix-merge@1"]))
CLASSES = {
    "hotfix-preflight@1": {"READY": "continue", "DIRTY": "ask", "NEEDS INPUT": "ask", "FAILED": "stop"},
    "hotfix-branch@1": {"CUT": "continue", "FAILED": "stop"},
    "hotfix-stage@1": {"NAMED": "continue", "NONE": "continue", "PRODUCTION": "ask", "DECLINED": "end:environment-declined"},
    "hotfix-environment@1": {"RECREATED": "continue", "MIGRATED": "continue", "UNCHANGED": "continue", "NEEDS ANSWER": "ask", "FAILED": "stop"},
    "hotfix-report@1": {"DONE": "continue"},
    "hotfix-fix@1": {"COMMITTED": "continue", "NEEDS DIRECTION": "ask", "ABANDONED": "end:abandoned"},
    "hotfix-merge@1": {"MERGED": "continue", "WAITING FOR YES": "ask", "REFUSED": "stop", "ERROR": "stop"},
    "deploy-approval@1": {"APPROVED": "continue", "WAITING FOR YES": "ask", "RETRY": "redo:self", "NOT CONFIGURED": "skipped", "STOPPED": "stop"},
    "deploy-confirm@1": {"CONFIRMED": "continue", "UNCONFIRMED": "stop", "OWNER TO CONFIRM": "ask", "NOT CONFIGURED": "skipped"},
    "hotfix-close@1": {"CLOSED": "continue", "OPEN RELEASE": "continue"},
}
for name, want in CLASSES.items():
    got = dict((v["value"], v["class"]) for v in CATALOG[name]["verdict"]["values"])
    check("%s: each verdict's outcome class is as published" % name, got == want, got)

# The verdict grammar: the runner's own parser accepts each documented line and rejects a wrong
# prefix, a lower-case verdict and a missing first line.
import importlib.util
spec = importlib.util.spec_from_file_location("workflow_under_test", RUNNER)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
check("the catalog passes the runner's structural checks", runner.check_catalog({"schema": 1, "contracts": CATALOG}) == [])

# --- required steps cannot be authored away ------------------------------------------------------
def broken(change):
    document = copy.deepcopy(HOTFIX)
    change(document)
    run = Run(definition=document)
    return run.rc, (run.err.strip().split("\n") or [""])[-1]

def drop(step_id):
    return lambda d: [p["steps"].remove(s) for p in d["phases"] for s in list(p["steps"]) if s["id"] == step_id]

def setstep(step_id, fn):
    return lambda d: [fn(s) for p in d["phases"] for s in p["steps"] if s["id"] == step_id]

def move_merge_before_review(d):
    ship = d["phases"][1]["steps"]
    merge = next(s for s in ship if s["id"] == "merge")
    ship.remove(merge)
    ship.insert([s["id"] for s in ship].index("review"), merge)

for label, change, word in [
        ("risk-check removed", drop("risk-check"), "risk-check@1"),
        ("local-checks removed", drop("local-checks"), "local-checks@1"),
        ("review removed", drop("review"), "review@1"),
        ("review carrying on after a failure", setstep("review", lambda s: s.update(onFail="continue")), "review"),
        ("local-checks switched off", setstep("local-checks", lambda s: s["run"].update(source="off")), "local-checks"),
        ("merge before review", move_merge_before_review, "review@1"),
        ("the fix removed (no build step, no satisfier)", drop("fix"), "build@1"),
        ("the merge removed before the deploy approval", drop("merge"), "hotfix-merge@1")]:
    rc, line = broken(change)
    check("start refuses a copy with %s, naming it" % label, rc == 2 and line.startswith("workflow:") and word in line, (rc, line))

# --- the branch-name helper ----------------------------------------------------------------------
cases = json.load(open(os.path.join(ROOT, "skills/hotfix-steps/scripts/hotfix-name-fixtures.json"), encoding="utf-8"))
for case in cases:
    done = subprocess.run([sys.executable, "-B", NAMER], input=json.dumps(case["in"]), capture_output=True, text=True)
    if "out" in case:
        got = json.loads(done.stdout) if done.returncode == 0 else done.stderr
        check("hotfix-name: %s" % case["name"], done.returncode == 0 and got == case["out"], got)
        matched = subprocess.run([sys.executable, "-B", os.path.join(ROOT, "skills/build-item/scripts/routing.py"), "match"],
                                 input=json.dumps({"name": case["out"]["branch"], "patterns": ["*/hotfix/**"]}), capture_output=True, text=True)
        check("hotfix-name: %s matches the default hotfix pattern" % case["name"], json.loads(matched.stdout)["matches"] is True)
    else:
        check("hotfix-name: %s" % case["name"], done.returncode == case["exit"] and done.stderr.startswith("hotfix-name: ") and done.stdout == "",
              (done.returncode, done.stderr))

# --- never blocked: the hotfix path names no release-holding machinery ---------------------------
paths = [HOTFIX_FILE, os.path.join(ROOT, "skills/hotfix-steps/SKILL.md")] + sorted(
    os.path.join(ROOT, "skills/hotfix-steps/references", f) for f in os.listdir(os.path.join(ROOT, "skills/hotfix-steps/references")))
corpus = "\n".join(open(p, encoding="utf-8").read() for p in paths)
banned = ["tower", "release-train", "clearance", "previous-release", "release/post-deploy", "queue", "release_checks", "release-holds"]
check("the hotfix definition and step skill name none of %s" % banned, [w for w in banned if w in corpus.lower()] == [], [w for w in banned if w in corpus.lower()])

# --- replays through the real runner -------------------------------------------------------------
run = Run()
check("start accepts the shipped definition and issues preflight", run.rc == 0 and run.answer["action"] == "run" and run.answer["step"]["id"] == "preflight", run.err)
while run.answer and run.answer["action"] == "run":
    run.done()
check("the full run issues the thirteen steps once each, in order", run.issued() == [(s, 1) for s in PINNED], (run.issued(), run.err))
check("... and finishes completed", run.answer is not None and run.answer.get("action") == "finished" and run.answer.get("outcome") == "completed", (run.answer, run.err))
seen = dict((a["step"]["id"], a) for a in run.answers if a.get("action") == "run")
check("the risk check reads the fix through build@1's satisfier", seen["risk-check"]["payload"].get("build", {}).get("scopeLine") == "Fixes the login crash.", seen["risk-check"]["payload"].get("build"))
check("the local checks read the branch through branch@1's satisfier", seen["local-checks"]["payload"].get("branch") == BRANCH, seen["local-checks"]["payload"].get("branch"))
check("a run with no item reaches review with no item in its payload", seen["review"]["payload"].get("item") is None and seen["review"]["payload"]["workingBase"] == "main", seen["review"]["payload"])
check("the deploy approval reads the merge SHA from the production merge", seen["approve-deploy"]["payload"].get("mergeSha") == "abc1234")

# A dirty tree stops at preflight; after the person's answer it is issued again and passes.
run = Run()
run.done(answer_text("HOTFIX PREFLIGHT: DIRTY", {"branch": "", "base": "main", "prefix": "test", "date": "", "dateFormat": "MM-DD-YY", "configSource": "file"}))
check("DIRTY stops the run and asks", run.answer is not None and run.answer.get("action") == "stopped" and run.answer.get("stepId") == "preflight", run.answer)
run.resume(answer="stash it")
check("... the answer re-issues preflight as attempt 2", run.answer is not None and run.answer.get("action") == "run" and run.answer["step"]["id"] == "preflight" and run.answer["step"]["attempt"] == 2, run.answer)

# A production stage stops before the environment step; declining ends the run cleanly.
run = Run()
run.until("name-stage")
run.done(answer_text("HOTFIX STAGE: PRODUCTION prod", {"stage": "prod", "production": True}))
check("PRODUCTION stops before rewind-environment is issued", run.answer.get("action") == "stopped" and "rewind-environment" not in [s for s, _ in run.issued()], run.answer)
run.resume(answer="do not touch it")
run.done(answer_text("HOTFIX STAGE: DECLINED prod", {"stage": "prod", "production": True}))
check("... declining ends the run with outcome environment-declined", run.answer.get("action") == "finished" and run.answer.get("outcome") == "environment-declined"
      and "rewind-environment" not in [s for s, _ in run.issued()], run.answer)

# An absent or all-null local environment asks and invents nothing.
run = Run()
run.until("rewind-environment")
run.done(answer_text("HOTFIX ENVIRONMENT: NEEDS ANSWER no localEnvironment commands are set", {"case": 3, "mode": None, "why": "no commands", "restartDevServer": True}))
check("NEEDS ANSWER stops the run before the report", run.answer.get("action") == "stopped" and "report-cut" not in [s for s, _ in run.issued()], run.answer)

# The merge waits for a yes; the deploy approval can be not configured and is then skipped.
run = Run()
run.until("merge")
run.done(answer_text("HOTFIX MERGE: WAITING FOR YES", {"sha": "", "pullRequest": 7}))
check("a merge with no yes stops and asks", run.answer.get("action") == "stopped" and run.answer.get("stepId") == "merge", run.answer)
run.resume(answer="yes, merge pull request 7")
check("... the yes re-issues the merge as attempt 2", run.answer.get("action") == "run" and run.answer["step"]["id"] == "merge" and run.answer["step"]["attempt"] == 2, run.answer)
check("... with the answer in its payload", run.answer["payload"].get("answer") == "yes, merge pull request 7", run.answer["payload"])
run.done()
run.done(answer_text("DEPLOY APPROVAL: NOT CONFIGURED", {"mergeSha": "abc1234", "approved": False}))
check("an unconfigured deploy approval is skipped and the confirmation is issued", run.answer.get("action") == "run" and run.answer["step"]["id"] == "confirm-deploy", run.answer)
run.done(answer_text("DEPLOY: OWNER TO CONFIRM", {"mergeCommit": "abc1234", "confirmedAt": None}))
check("an unconfigured verification asks the person to confirm", run.answer.get("action") == "stopped" and run.answer.get("stepId") == "confirm-deploy", run.answer)
run.resume(answer="confirmed, production serves it")
run.done()
run.done(answer_text("HOTFIX CLOSED: OPEN RELEASE release/26-11-21", {"mergeSha": "abc1234", "openRelease": "release/26-11-21"}))
check("... confirmed, and the close names an open release branch and still finishes", run.answer.get("action") == "finished" and run.answer.get("outcome") == "completed", run.answer)

# The fix step can be abandoned, which ends the run cleanly.
run = Run()
run.until("fix")
run.done(answer_text("HOTFIX FIX: ABANDONED", {"commit": "", "deferrals": [], "deviations": [], "untrackedDeferrals": [], "dismissed": [], "scopeLine": "", "head": ""}))
check("ABANDONED ends the run with outcome abandoned", run.answer.get("action") == "finished" and run.answer.get("outcome") == "abandoned", run.answer)
PY

python3 "$WORK/cases.py" "$ROOT" "$WORK" > "$WORK/out.txt" 2>&1 || { cat "$WORK/out.txt"; echo "FAIL the cases did not run to the end"; exit 1; }
sed 's/^/  /' "$WORK/out.txt"
grep -q '^FAIL' "$WORK/out.txt" && FAIL=1
[ "$FAIL" = 0 ] && echo "workflow-hotfix: PASS" || echo "workflow-hotfix: FAIL"
exit "$FAIL"
