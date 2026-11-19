#!/bin/bash
# scripts/tests/build-workflow-run.sh — the Build loop end to end with no model: the step runner
# drives the REAL workflows/build.json against the real catalog and the real plugin root, in a
# throwaway git repository, with each step's answer canned (the passing answers in
# skills/run-workflow/scripts/workflow-fixtures.json). It walks the fast path and the pull-request
# path, a review fix, a base refresh, a held claim and a held merge, a question and its answer, a
# dirty checkout, local checks with nothing configured, and a definition with a step removed; and
# every report the run produces goes back through the reporting helper's own validation.
# Everything lives in a temporary directory: its own cache folder and repositories. No network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export PYTHONDONTWRITEBYTECODE=1
unset CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID XDG_CACHE_HOME GIT_DIR GIT_WORK_TREE

cat > "$WORK/cases.py" <<'PY'
import copy, importlib.util, json, os, re, subprocess, sys

ROOT, WORK = sys.argv[1], sys.argv[2]
RUNNER = os.path.join(ROOT, "skills/run-workflow/scripts/workflow.py")
BUILD_FILE = os.path.join(ROOT, "workflows/build.json")
BUILD = json.load(open(BUILD_FILE, encoding="utf-8"))
CATALOG = json.load(open(os.path.join(ROOT, "schemas/step-contracts.json"), encoding="utf-8"))["contracts"]
FIX = json.load(open(os.path.join(ROOT, "skills/run-workflow/scripts/workflow-fixtures.json"), encoding="utf-8"))
STEPS = [step for phase in BUILD["phases"] for step in phase["steps"]]
ORDER = [s["id"] for s in STEPS]
CONTEXT = {"item": "I123", "goal": "Add the export button", "profile": {"name": "extended", "source": "config"},
           "workingBase": "main", "oneOff": False, "route": "epic-release", "releaseUnit": "I120",
           "reviewMoment": "release-deferred", "branchSlug": "export-button", "mode": "named"}
spec = importlib.util.spec_from_file_location("workflow_report", os.path.join(ROOT, "skills/build-item/scripts/workflow_report.py"))
REPORT = importlib.util.module_from_spec(spec)
spec.loader.exec_module(REPORT)
counter, made = [0], [0]
DIFF = ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-relative", "--src-prefix=a/", "--dst-prefix=b/",
        "--ignore-submodules=none", "--unified=3", "--no-renames", "--diff-algorithm=myers", "--inter-hunk-context=0"]


def check(label, good, detail=""):
    counter[0] += 1
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
    git(repo, "checkout", "-q", "-b", "feature")
    commit(repo, "export.txt", "export\n", "add the export")
    return repo


def facts(repo):
    patch = git(repo, "patch-id", "--verbatim", stdin=git(repo, *(DIFF + ["main...HEAD", "--"]))).decode().split()
    return {"head": git(repo, "rev-parse", "HEAD").decode().strip(), "tree": git(repo, "rev-parse", "HEAD^{tree}").decode().strip(),
            "patchId": patch[0] if patch else ""}


def canned(contract, repo, **change):
    """The passing answer for a contract with the repository's facts filled in, its result changed
    by `change` (a dotted key: value), and its verdict line replaced by `verdict`."""
    verdict = change.pop("verdict", None)
    text = FIX["outputs"][contract]
    for key, value in facts(repo).items():
        text = text.replace("{%s}" % key, value)
    head, _, block = text.partition("```json\n")
    result = json.loads(block.split("```")[0])
    for path, value in change.items():
        target = result
        keys = path.split(".")
        for key in keys[:-1]:
            target = target.setdefault(key, {})
        target[keys[-1]] = value
    lines = head.split("\n")
    if verdict:
        lines[0] = verdict
    return "\n".join(lines) + "```json\n" + json.dumps(result) + "\n```\n"


class Run:
    def __init__(self, definition=None, context=None, session="s1"):
        self.cache = fresh("cache")
        self.repo = new_repo()
        self.session = session
        self.answers = []
        request = {"definition": definition} if definition is not None else {"definitionFile": BUILD_FILE}
        request["context"] = dict(CONTEXT, cwd=self.repo, **(context or {}))
        self.rc, self.answer, self.out, self.err = self.call("start", request)

    def call(self, command, request):
        env = dict((k, v) for k, v in os.environ.items() if k not in ("CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID"))
        env["XDG_CACHE_HOME"] = self.cache
        request = dict(request, session=self.session)
        done = subprocess.run([sys.executable, "-B", RUNNER, command], input=json.dumps(request), capture_output=True,
                              text=True, env=env, cwd=self.repo)
        answer = json.loads(done.stdout) if done.returncode == 0 else None
        if answer is not None:
            self.answers.append(answer)
        return done.returncode, answer, done.stdout, done.stderr

    def done(self, output=None, **change):
        step = self.answer["step"]
        if output is None:
            output = canned(step["contract"], self.repo, **change)
        self.rc, self.answer, self.out, self.err = self.call("done", {"item": "I123", "stepId": step["id"], "attempt": step["attempt"], "output": output})
        return self.answer

    def resume(self, **extra):
        self.rc, self.answer, self.out, self.err = self.call("resume", dict({"item": "I123"}, **extra))
        return self.answer

    def until(self, step_id):
        while self.answer and self.answer["action"] == "run" and self.answer["step"]["id"] != step_id:
            self.done()
        return self.answer

    def issued(self):
        return [(a["step"]["id"], a["step"]["attempt"]) for a in self.answers if a.get("action") == "run"]


def is_run(answer, step_id, attempt=None):
    return (answer is not None and answer.get("action") == "run" and answer["step"]["id"] == step_id
            and (attempt is None or answer["step"]["attempt"] == attempt))


def finished(answer, outcome):
    return answer is not None and answer.get("action") == "finished" and answer.get("outcome") == outcome


def stopped(answer, kind, step_id):
    return answer is not None and answer.get("action") == "stopped" and answer.get("kind") == kind and answer.get("stepId") == step_id


def closes(answer, outcome):
    calls = answer.get("reports", [])
    return bool(calls) and calls[-1].get("run", {}).get("outcome") == outcome


def unique(seq):
    out = []
    for item in seq:
        if item not in out:
            out.append(item)
    return out


# --- the definition, as shipped -------------------------------------------------------------
plugin = json.load(open(os.path.join(ROOT, ".claude-plugin/plugin.json"), encoding="utf-8"))["version"]
check("every step's skill exists in this plugin", [s["run"]["ref"] for s in STEPS if not os.path.isfile(os.path.join(ROOT, "skills", s["run"]["ref"], "SKILL.md"))] == [])
check("every step's contract is in the catalog", [s["contract"] for s in STEPS if s["contract"] not in CATALOG] == [])
check("every step's claim phase is at most 64 characters",
      [s["contract"] for s in STEPS if len(CATALOG[s["contract"]]["claimPhase"] or "") > 64] == [])
check("every step runs its contract's own built-in skill", [s["run"]["ref"] for s in STEPS] == [CATALOG[s["contract"]]["builtinSkill"] for s in STEPS])
required = [name for name, entry in CATALOG.items() if entry["builtinSkill"]]
check("the definition's step order is the catalog's order", [s["contract"] for s in STEPS] == required, [s["contract"] for s in STEPS])
check("each requirement comes earlier in the definition",
      all(ORDER.index(next(t["id"] for t in STEPS if t["contract"] == need)) < ORDER.index(s["id"]) for s in STEPS for need in CATALOG[s["contract"]]["requires"]))
check("the definition needs this plugin's version", BUILD["minPluginVersion"] == plugin, (BUILD["minPluginVersion"], plugin))

# --- the fast path: an epic story -------------------------------------------------------------
run = Run()
check("start succeeds on the real plugin root with the shipped file", run.rc == 0 and is_run(run.answer, "claim", 1), run.err)
seen = {}
while run.answer and run.answer["action"] == "run":
    seen[run.answer["step"]["id"]] = run.answer
    run.done()
final = run.answer
check("the fast path issues the eleven steps once each, in order", run.issued() == [(s, 1) for s in ORDER], run.issued())
check("... and finishes completed, closing the run", finished(final, "completed") and closes(final, "completed"), final)
check("the start and complete steps both run story-lifecycle, each told its contract",
      [(seen[s]["skill"]["ref"], seen[s]["payload"]["contract"], json.loads(seen[s]["argument"])["contract"]) for s in ("start", "complete")]
      == [("story-lifecycle", "start@1", "start@1"), ("story-lifecycle", "complete@1", "complete@1")])
check("the branch step is handed the working base explicitly", seen["branch"]["argument"] == "export-button base: main", seen["branch"]["argument"])
check("the build step is handed the item, goal, profile and review moment",
      seen["build"]["argument"] == "I123 Add the export button profile: extended review-moment: release-deferred", seen["build"]["argument"])
check("the merge is handed the commit the review saw",
      seen["merge"]["payload"].get("commit") == facts(run.repo)["head"], seen["merge"]["payload"])
statuses = [(r["stepId"], r["status"]) for a in run.answers for c in a.get("reports", []) for r in c.get("reports", [])]
check("each step is reported running, then done", [s for s in unique(statuses)] == [(s, st) for s in ORDER for st in ("running", "done")], unique(statuses))
check("the reports name each step's skill", set((r["stepId"], r.get("ran", {}).get("ref")) for a in run.answers for c in a.get("reports", []) for r in c.get("reports", []))
      == set((s["id"], s["run"]["ref"]) for s in STEPS))

# every report object round-trips through the helper's own validation
calls = [c for a in run.answers for c in a.get("reports", [])]
rebuilt = []
for call in calls:
    reports = [dict(r, step=r["stepId"]) for r in call.get("reports", [])]
    try:
        rebuilt.append(REPORT.build_report_arguments(call["runId"], call["sessionId"], reports, item_number=call.get("itemNumber"),
                                                    repository=call.get("repository"), definition=call.get("definition"), run=call.get("run")) == call)
    except ValueError as error:
        rebuilt.append(str(error))
check("every report the run produced is accepted by the reporting helper unchanged (%d calls)" % len(calls), calls and all(r is True for r in rebuilt), rebuilt)
check("the first report carries the shipped definition", calls[0].get("definition") == BUILD)

# --- the pull-request path ----------------------------------------------------------------
run = Run(context={"route": "one-off", "oneOff": True, "reviewMoment": "pr-boundary", "workingBase": "main"})
run.until("review")
answer = run.done(**{"path": "pull-request", "proof.path": "pull-request", "pullRequest": 7, "mergeBody": "Merge pull request #7"})
check("the pull-request review hands the merge its path", is_run(answer, "merge", 1) and answer["payload"]["review"]["path"] == "pull-request", answer)
answer = run.done(**{"pullRequest": 7, "links": {"pullRequest": "https://example.com/pull/7", "commit": "https://example.com/commit/1"}})
links = [r.get("links") for c in answer.get("reports", []) for r in c.get("reports", []) if r["stepId"] == "merge" and r["status"] == "done"]
check("the merge's links reach the report", links == [{"pullRequest": "https://example.com/pull/7", "commit": "https://example.com/commit/1"}], links)
while run.answer["action"] == "run":
    run.done()
check("the pull-request path finishes completed", finished(run.answer, "completed"), run.answer)

# --- a review fix after the local checks --------------------------------------------------
run = Run()
run.until("review")
commit(run.repo, "export.txt", "export\nfixed\n", "a review fix")
answer = run.done()
check("a review fix re-issues the risk check before the merge, handed the head it last covered",
      is_run(answer, "risk-check", 2) and answer["payload"]["previousProof"]["head"] != facts(run.repo)["head"], answer)
answer = run.done()
check("... then the local checks", is_run(answer, "local-checks", 2), answer)
answer = run.done()
check("... while the review, of the patch as it now is, stays valid: the merge is next", is_run(answer, "merge", 1), answer)

# --- REFRESHED -----------------------------------------------------------------------------
run = Run()
run.until("merge")
git(run.repo, "checkout", "-q", "main"); commit(run.repo, "readme.txt", "one\ntwo\n", "base moves"); git(run.repo, "checkout", "-q", "feature")
git(run.repo, "rebase", "-q", "main")
answer = run.done("MERGE: REFRESHED\n")
check("REFRESHED re-issues the stale local checks first", is_run(answer, "local-checks", 2), answer)
answer = run.done()
check("... then the merge again, the review untouched", is_run(answer, "merge", 2) and ("review", 2) not in run.issued(), run.issued())

# --- held ---------------------------------------------------------------------------------
run = Run()
answer = run.done(canned("claim@1", run.repo, verdict="CLAIM: HELD m2 session s2 since 9:00 AM CST", state="held", heldBy="m2 s2", since="9:00 AM CST"))
check("a held claim ends the run as held, reported interrupted", finished(answer, "held") and closes(answer, "interrupted"), answer)
check("... and nothing after the claim was issued", run.issued() == [("claim", 1)], run.issued())
run = Run()
run.until("merge")
answer = run.done("MERGE: HELD a release is merging\n")
check("a held merge ends the run as held, nothing landed", finished(answer, "held") and ("complete", 1) not in run.issued(), answer)

# --- a question, then its answer ----------------------------------------------------------
run = Run()
run.until("build")
answer = run.done("BUILD: NEEDS DECISION keep the old export format?\nthe spec does not say\n")
check("NEEDS DECISION stops the run for a person", answer["action"] == "stopped" and answer["kind"] == "needs-person" and "keep the old export format?" in json.dumps(answer), answer)
answer = run.resume(answer="yes, keep it")
check("resume with the answer re-issues the build with it", is_run(answer, "build", 2) and answer["payload"]["answer"] == "yes, keep it", answer)
check("... and the run then continues to the risk check", is_run(run.done(), "risk-check", 1), run.answer)
run = Run()
run.until("risk-check")
answer = run.done("RISK CHECK: NEEDS DECISION ship the schema change without a backfill?\n")
answer = run.resume(answer="no, add the backfill")
check("the risk check's question resumes the same way", is_run(answer, "risk-check", 2) and answer["payload"]["answer"] == "no, add the backfill", answer)

# --- red gate, dirty checkout --------------------------------------------------------------
run = Run()
run.until("local-checks")
answer = run.done("LOCAL CHECKS: FAIL unit\nunit: 2 failed\n")
check("a red local gate stops the run before the review", stopped(answer, "failed", "local-checks") and ("review", 1) not in run.issued(), answer)
commit(run.repo, "export.txt", "export\nfixed the unit test\n", "fix the red check")
answer = run.resume()
check("... and after the fix a resume screens the fix first: the risk check again", is_run(answer, "risk-check", 2), answer)
check("... then the local checks again", is_run(run.done(), "local-checks", 2), run.answer)
check("... then the review", is_run(run.done(), "review", 1), run.answer)

# --- a gate fix that adds a migration is screened before the merge (the fast path launches no finders)
run = Run()
run.until("local-checks")
run.done("LOCAL CHECKS: FAIL unit\nunit: 1 failed\n")
commit(run.repo, "migration-0001.sql", "alter table items add column archived boolean;\n", "fix the red check with a migration")
order = []
answer = run.resume()
while answer and answer["action"] == "run" and answer["step"]["id"] != "merge":
    order.append(answer["step"]["id"])
    answer = run.done()
check("a migration added by a gate fix gets the risk check again before the review and the merge",
      order[:1] == ["risk-check"] and "review" in order and is_run(answer, "merge"), (order, answer))
# a base refresh alone (the story unchanged) does not
run = Run()
run.until("merge")
git(run.repo, "checkout", "-q", "main"); commit(run.repo, "base.txt", "moved\n", "base moves"); git(run.repo, "checkout", "-q", "feature")
git(run.repo, "rebase", "-q", "main")
check("a base refresh that leaves the story unchanged does not screen it again",
      is_run(run.done("MERGE: REFRESHED\n"), "local-checks", 2) and ("risk-check", 2) not in run.issued(), run.issued())
run = Run()
run.until("sync")
answer = run.done("SYNC: DIRTY notes.txt\n")
check("a dirty checkout after landing stops the run", stopped(answer, "failed", "sync"), answer)
answer = run.resume()
check("... and a resume after the merge landed starts at sync, never re-merging", is_run(answer, "sync", 2) and ("merge", 2) not in run.issued(), answer)

# --- nothing configured locally -----------------------------------------------------------
for path, allowed in (("fast-local", False), ("pull-request", True)):
    run = Run()
    run.until("local-checks")
    run.done(canned("local-checks@1", run.repo, verdict="LOCAL CHECKS: NOT CONFIGURED", **{"proof.kind": "none-configured"}))
    answer = run.done(**{"path": path, "proof.path": path})
    if allowed:
        check("local checks with nothing configured are accepted by the merge after a pull-request review", is_run(answer, "merge", 1), answer)
    else:
        check("... and refused after a fast review", stopped(answer, "proof", "merge") and "none-configured-needs-pull-request-route" in answer["reason"], answer)

# --- a step removed -----------------------------------------------------------------------
# a step another step's contract requires cannot be left out; the four nothing requires (the claim,
# the start, and the two after completion) are the catalog's to leave optional, not this test's
needed = [s["id"] for s in STEPS if any(s["contract"] in CATALOG[t["contract"]]["requires"] for t in STEPS)]
check("the required steps are the branch through the completion", needed == ["branch", "build", "risk-check", "local-checks", "review", "merge", "complete"], needed)
for step_id in needed:
    edited = copy.deepcopy(BUILD)
    for phase in edited["phases"]:
        phase["steps"] = [s for s in phase["steps"] if s["id"] != step_id]
    edited["phases"] = [phase for phase in edited["phases"] if phase["steps"]]
    run = Run(definition=edited)
    check("a definition without the %s step is refused" % step_id, run.rc == 2 and re.match(r"^workflow: requires-missing: [^\n]+\n$", run.err) is not None and run.answer is None, (run.rc, run.err))

# --- a review whose result and proof name different paths is refused -------------------------
run = Run()
run.until("local-checks")
run.done(canned("local-checks@1", run.repo, verdict="LOCAL CHECKS: NOT CONFIGURED", **{"proof.kind": "none-configured"}))
answer = run.done(**{"path": "fast-local", "proof.path": "pull-request"})
check("a review answering the fast path with a pull-request proof is refused, never merged fast",
      stopped(answer, "proof", "review") and "review-names-one-path" in answer["reason"] and ("merge", 1) not in run.issued(), answer)

# --- a cleared conversation after the merge landed: the new session resumes, never starts again
run = Run()
answer = run.until("merge")
story = answer["payload"]["commit"]
git(run.repo, "checkout", "-q", "main"); git(run.repo, "merge", "-q", "--no-ff", "-m", "merge: I123", story)
run.session = "s2"
check("(a new session sees no run of its own)", run.call("status", {"item": "I123"})[0] == 2)
answer = run.resume()
check("resume with the item adopts the run left unfinished, handing back the merge and its commit",
      is_run(answer, "merge", 1) and answer["payload"]["commit"] == story, answer)
answer = run.done(canned("merge@1", run.repo, **{"proof.head": story}))
check("... the merge that already landed, reported with done, leads to the remaining steps", is_run(answer, "complete", 1), answer)
while run.answer and run.answer["action"] == "run":
    run.done()
check("... which finish the run completed", finished(run.answer, "completed"), run.answer)
run2 = Run()
run2.until("merge")
run2.session = "s3"
rc, second, _, err = run2.call("start", {"definitionFile": BUILD_FILE, "context": dict(CONTEXT, cwd=run2.repo)})
check("a start in a new session would open a second run at the claim, leaving the merge behind: why the loop resumes first",
      rc == 0 and is_run(second, "claim", 1), (rc, second, err))

# --- a merge that landed and then reported BLOCKED is repaired with done, never resumed ------
run = Run()
answer = run.until("merge")
story = answer["payload"]["commit"]
git(run.repo, "checkout", "-q", "main"); git(run.repo, "merge", "-q", "--no-ff", "-m", "merge: I123", story)
answer = run.done("MERGE: BLOCKED pushed, but deleting the remote story branch was refused\n")
check("(a merge reported BLOCKED after it landed stops the run)", stopped(answer, "failed", "merge"), answer)
answer = run.call("done", {"item": "I123", "stepId": "merge", "attempt": 1, "output": canned("merge@1", run.repo, **{"proof.head": story})})[1]
check("reporting the landed merge with done on the stopped step carries the run on to completion",
      is_run(answer, "complete", 1), answer)
run = Run()
answer = run.until("merge")
story = answer["payload"]["commit"]
git(run.repo, "checkout", "-q", "main"); git(run.repo, "merge", "-q", "--no-ff", "-m", "merge: I123", story)
answer = run.done("MERGE: BLOCKED pushed, but deleting the remote story branch was refused\n")
answer = run.resume()
check("whereas resume after it landed reads the moved checkout as new work (why the loop reports it with done)",
      answer is not None and answer.get("action") == "run" and answer["step"]["id"] in ("risk-check", "local-checks", "review"), answer)
run = Run()
run.until("merge")
commit(run.repo, "late.txt", "late\n", "a commit after the merge was issued")
answer = run.done()
check("a merge stop for another commit tells the person to report a landing with done, never to resume",
      stopped(answer, "proof", "merge") and "report it with done" in answer["reason"] and "never resume" in answer["reason"], answer)

# --- a refused fast-merge push: the checkout put back on the story branch before BLOCKED -----
run = Run()
answer = run.until("merge")
story = answer["payload"]["commit"]
git(run.repo, "checkout", "-q", "main"); git(run.repo, "merge", "-q", "--no-ff", "-m", "merge: I123", story)
git(run.repo, "reset", "-q", "--hard", "HEAD~1"); git(run.repo, "checkout", "-q", "feature")  # as merge-paths restores it
answer = run.done("MERGE: BLOCKED push refused: the remote rejected it\n")
answer = run.resume()
check("after a refused push, restored as merge-paths says, resume hands the merge the story commit again",
      is_run(answer, "merge", 2) and answer["payload"]["commit"] == story, answer)

# --- a train one-off moved off the train for excluded paths: the new run on the moved branch ---
run = Run(context={"route": "train", "oneOff": True, "workingBase": "train", "reviewMoment": "release-deferred"})
git(run.repo, "branch", "-q", "train", "main")
answer = run.until("merge")
answer = run.done("MERGE: BLOCKED excluded paths: migrations/0001.sql\n")
check("(a merge blocked on excluded paths stops the run)", stopped(answer, "failed", "merge"), answer)
git(run.repo, "rebase", "-q", "--onto", "main", "train")
rc, answer, _, err = run.call("start", {"definitionFile": BUILD_FILE, "replace": True,
                                        "context": dict(CONTEXT, cwd=run.repo, route="develop-pr", oneOff=True, workingBase="main", reviewMoment="pr-boundary")})
check("start with replace on the moved branch opens a new run", rc == 0 and is_run(answer, "claim", 1), err)
run.answer = answer
run.until("branch")
answer = run.done(canned("branch@1", run.repo, verdict="BRANCH: EXISTS feature", created=False))
check("... whose branch step answers EXISTS on the built branch and hands on to the build", is_run(answer, "build", 1), answer)
order = []
while run.answer["action"] == "run" and run.answer["step"]["id"] != "merge":
    order.append(run.answer["step"]["id"])
    run.done(**({"path": "pull-request", "proof.path": "pull-request", "pullRequest": 9} if run.answer["step"]["id"] == "review" else {}))
check("... then screens, checks and reviews the moved branch on the pull-request path before the merge",
      order == ["build", "risk-check", "local-checks", "review"] and run.answer["payload"]["review"]["path"] == "pull-request"
      and run.answer["payload"]["reviewProof"]["path"] == "pull-request", (order, run.answer))

# --- the merge payload carries what the merge reads after a compaction ----------------------
check("the merge is handed the review's proof and the local checks' receipt",
      set(seen["merge"]["payload"]["reviewProof"]) >= {"head", "base", "path", "patchId"}
      and seen["merge"]["payload"]["localChecks"]["receipt"] and seen["merge"]["payload"]["localChecks"]["commands"], seen["merge"]["payload"])
check("the complete step is handed the profile's source", seen["complete"]["payload"]["profileSource"] == "config", seen["complete"]["payload"])

# --- a report the tracker refused for want of the definition is sent again with it ----------
run = Run()
run.until("build")
refused_call = [c for c in run.answer["reports"] if c.get("reports")][-1]
rc, status, _, _ = run.call("status", {"item": "I123", "includeDefinition": True})
definition = status["reports"][0]["definition"]
check("(the status object alone carries no step reports: sending only it would lose the refused batch)",
      status["reports"][0].get("reports") in (None, []), status["reports"][0])
resent = dict(refused_call, definition=definition)
rebuilt = REPORT.build_report_arguments(resent["runId"], resent["sessionId"], [dict(r, step=r["stepId"]) for r in resent["reports"]],
                                        item_number=resent.get("itemNumber"), repository=resent.get("repository"),
                                        definition=definition, run=resent.get("run"))
check("the refused object with the definition added is a report the helper accepts unchanged, carrying the refused steps",
      rebuilt == resent and resent["reports"] == refused_call["reports"], (rebuilt, resent))

# --- what looks like a credential never reaches a report ----------------------------------
token = "".join(FIX["credentials"]["caught"][3])  # stored in two parts: never one literal in the repository
run = Run()
run.until("build")
run.done(canned("build@1", run.repo).replace("3 files changed", "used %s to read the repository" % token))
sent = json.dumps([a.get("reports") for a in run.answers])
check("a token in a step's evidence is never sent on", token not in sent)
PY
OUT="$(python3 -B "$WORK/cases.py" "$ROOT" "$WORK" 2>&1)"; RC=$?
printf '%s\n' "$OUT" | sed 's/^/  /'
N="$(printf '%s\n' "$OUT" | grep -c '^ok')"
if [ $RC -ne 0 ] || printf '%s\n' "$OUT" | grep -q '^FAIL'; then bad "a case failed or the script did not finish (exit $RC)"
elif [ "$N" -lt 70 ]; then bad "only $N cases ran, expected at least 70"
else ok "(all $N cases passed)"; fi
exit $FAIL
