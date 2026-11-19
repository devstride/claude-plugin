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
    # origin/main follows main: the base a risk check screens against, with no remote to fetch.
    git(repo, "symbolic-ref", "refs/remotes/origin/main", "refs/heads/main")
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
        self.base = request["context"]["workingBase"]
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
            if step["contract"] == "risk-check@1":
                change.setdefault("proof.base", "origin/" + self.base)  # the base the run screens against
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
# The release that introduced version 2 of the definition, not the plugin's current one: a later
# release that leaves the step list alone must leave the definition, and so its hash, alone too.
check("the definition needs the release that introduced it, never a newer one than this plugin",
      BUILD["minPluginVersion"] == "4.3.0" and tuple(map(int, plugin.split("."))) >= (4, 3, 0), (BUILD["minPluginVersion"], plugin))

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
check("resume after a merge stop answers with the stop, naming the merge's commit, until told it did not land",
      stopped(answer, "failed", "merge") and answer.get("mayHaveLanded") is True and answer.get("commit") == story, answer)
answer = run.resume(landed=False)
check("... and told wrongly that it did not land, reads the moved checkout as new work (why the loop checks first)",
      answer is not None and answer.get("action") == "run" and answer["step"]["id"] in ("risk-check", "local-checks", "review"), answer)
run = Run()
run.until("merge")
commit(run.repo, "late.txt", "late\n", "a commit after the merge was issued")
answer = run.done()
check("a merge stop for another commit tells the person to report a landing with done, and when an unproven one is not done",
      stopped(answer, "proof", "merge") and "report it with done" in answer["reason"] and "done if no later story commit landed, else close" in answer["reason"]
      and answer["reason"].endswith("else close") and "resume" not in answer["reason"], answer)  # never cut off at the cap

# --- a refused fast-merge push: the checkout put back on the story branch before BLOCKED -----
run = Run()
answer = run.until("merge")
story = answer["payload"]["commit"]
git(run.repo, "checkout", "-q", "main"); git(run.repo, "merge", "-q", "--no-ff", "-m", "merge: I123", story)
git(run.repo, "reset", "-q", "--hard", "HEAD~1"); git(run.repo, "checkout", "-q", "feature")  # as merge-paths restores it
answer = run.done("MERGE: BLOCKED push refused: the remote rejected it\n")
answer = run.resume(landed=False)
check("after a refused push, restored as merge-paths says, resume told it did not land hands the merge the story commit again",
      is_run(answer, "merge", 2) and answer["payload"]["commit"] == story, answer)

# --- a train one-off moved off the train for excluded paths: the new run on the moved branch ---
run = Run(context={"route": "train", "oneOff": True, "workingBase": "train", "reviewMoment": "release-deferred"})
git(run.repo, "branch", "-q", "train", "main")
git(run.repo, "symbolic-ref", "refs/remotes/origin/train", "refs/heads/train")
answer = run.until("merge")
answer = run.done("MERGE: BLOCKED excluded paths: migrations/0001.sql\n")
check("(a merge blocked on excluded paths stops the run)", stopped(answer, "failed", "merge"), answer)
git(run.repo, "rebase", "-q", "--onto", "main", "train")
rc, answer, _, err = run.call("start", {"definitionFile": BUILD_FILE, "replace": True,
                                        "context": dict(CONTEXT, cwd=run.repo, route="develop-pr", oneOff=True, workingBase="main", reviewMoment="pr-boundary")})
check("start with replace on the moved branch opens a new run", rc == 0 and is_run(answer, "claim", 1), err)
run.answer, run.base = answer, "main"
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

# --- a re-issued risk check is handed only its last ACCEPTED screen --------------------------
for verdict, extra in (("RISK CHECK: BLOCKED verifier unavailable", {}), ("RISK CHECK: NEEDS DECISION keep the token check?", {"answer": "keep it"})):
    run = Run()
    run.until("risk-check")
    commit(run.repo, "auth.txt", "auth change\n", "the build touches sign-in")
    run.done(canned("risk-check@1", run.repo, verdict=verdict, **{"proof.triggers": ["auth"], "proof.verifiers": 0}))
    answer = run.resume(**extra)
    check("after %s the re-issued risk check gets no previous proof or result: the full screen" % verdict.split(":")[1].split()[0],
          is_run(answer, "risk-check", 2) and answer["payload"]["previousProof"] is None and answer["payload"]["previousResult"] is None, answer)
run = Run()
run.until("risk-check")
answer = run.done(canned("risk-check@1", run.repo, **{"proof.triggers": ["auth"], "proof.verifiers": 0}))
check("(a proof naming a trigger and no verifier is refused)", stopped(answer, "proof", "risk-check"), answer)
answer = run.resume()
check("... and a resume after that refusal hands no previous proof: the full screen again",
      is_run(answer, "risk-check", 2) and answer["payload"]["previousProof"] is None, answer)
run = Run()
run.until("local-checks")
first = facts(run.repo)["head"]
run.done("LOCAL CHECKS: FAIL unit\n")
commit(run.repo, "fix.txt", "fix\n", "fix the red check")
answer = run.resume()
check("a re-issued risk check after a gate fix is handed the accepted screen it follows",
      is_run(answer, "risk-check", 2) and answer["payload"]["previousProof"]["head"] == first, answer)
run.done(canned("risk-check@1", run.repo, **{"proof.triggers": ["auth"], "proof.verifiers": 0}))
answer = run.resume()
check("... and after that attempt's proof is refused, still that accepted screen, never the refused one",
      is_run(answer, "risk-check", 3) and answer["payload"]["previousProof"]["head"] == first
      and answer["payload"]["previousProof"]["triggers"] == [], answer)

# --- what the first screen recorded reaches capture and completion after a re-screen -------------
for cause in ("gate fix", "review fix"):
    run = Run()
    run.until("risk-check")
    run.done(canned("risk-check@1", run.repo, **{"ledger": "screen one", "untrackedDeferrals": ["first-screen finding"],
                                                    "deviations": ["kept the old export format"], "dismissed": [{"id": "F1", "why": "test only"}],
                                                    "counts": {"raised": 2, "fixed": 0, "deferred": 1, "dismissed": 1}}))
    if cause == "gate fix":
        run.until("local-checks")
        run.done("LOCAL CHECKS: FAIL unit\n")
        commit(run.repo, "fix.txt", "fix\n", "fix the red check")
        answer = run.resume()
    else:
        run.until("review")
        commit(run.repo, "export.txt", "export\nreview fix\n", "a review fix")
        answer = run.done()
    check("(after a %s the risk check is screened again, handed the first screen's result)" % cause,
          is_run(answer, "risk-check", 2) and answer["payload"]["previousResult"]["untrackedDeferrals"] == ["first-screen finding"], answer)
    run.done(canned("risk-check@1", run.repo, **{"ledger": "screen two", "deviations": ["a second deviation"],
                                                    "counts": {"raised": 1, "fixed": 1, "deferred": 0, "dismissed": 0}}))
    handed = {}
    while run.answer and run.answer["action"] == "run":
        handed[run.answer["step"]["id"]] = run.answer["payload"]
        run.done()
    for step_id in ("capture", "complete"):
        risk = handed.get(step_id, {}).get("riskCheck") or {}
        check("after a %s, %s still gets the first screen's untracked deferral and deviation, with the second's" % (cause, step_id),
              risk.get("untrackedDeferrals") == ["first-screen finding"] and risk.get("deviations") == ["kept the old export format", "a second deviation"]
              and risk.get("dismissed") == [{"id": "F1", "why": "test only"}] and risk.get("counts", {}).get("raised") == 3
              and risk.get("ledger", "").startswith("screen one") and "screen two" in risk.get("ledger", ""), risk)

# --- a later screen resolves earlier entries by id: later steps get only what is still open ----
run = Run()
run.until("risk-check")
run.done(**{"ledger": "screen one", "untrackedDeferrals": [{"id": "F1", "finding": "the export ignores the time zone"}],
            "deviations": [{"id": "D1", "deviation": "the export is CSV only"}], "dismissed": [],
            "counts": {"raised": 1, "fixed": 0, "deferred": 1, "dismissed": 0}})
run.until("local-checks")
run.done("LOCAL CHECKS: FAIL unit\n")
commit(run.repo, "export.txt", "export\ntime zone and JSON\n", "fix the red check, which also settles F1 and D1")
answer = run.resume()
check("(the fix is screened again, handed the open F1 and D1)",
      is_run(answer, "risk-check", 2) and [e["id"] for e in answer["payload"]["previousResult"]["untrackedDeferrals"]] == ["F1"], answer)
run.done(verdict="RISK CHECK: FIXED 1", **{"ledger": "screen two: F1 fixed, D1 overtaken", "untrackedDeferrals": [], "dismissed": [],
                                           "resolved": ["F1", "D1"], "counts": {"raised": 0, "fixed": 1, "deferred": 0, "dismissed": 0}})
handed = {}
while run.answer and run.answer["action"] == "run":
    handed[run.answer["step"]["id"]] = run.answer["payload"]
    run.done()
for step_id in ("capture", "complete"):
    risk = handed.get(step_id, {}).get("riskCheck") or {}
    check("a deferral and a deviation a later screen resolved by id never reach %s" % step_id,
          risk.get("untrackedDeferrals") == [] and risk.get("deviations") == [], risk)
    check("... whose counts stay consistent (one raised, one fixed, none deferred) and whose ledger keeps the history (%s)" % step_id,
          risk.get("counts") == {"raised": 1, "fixed": 1, "deferred": 0, "dismissed": 0} and risk.get("resolved") == ["F1", "D1"]
          and "screen one" in risk.get("ledger", "") and "screen two" in risk.get("ledger", ""), risk)

# --- ids and canonical-JSON identities never match; the resolved history keeps each id once -----
run = Run()
plain = {"what": "an entry with no id"}
run.until("risk-check")
run.done(**{"untrackedDeferrals": [{"id": "F1", "finding": "a"}, plain], "dismissed": [],
            "counts": {"raised": 2, "fixed": 0, "deferred": 2, "dismissed": 0}})
run.until("local-checks")
run.done("LOCAL CHECKS: FAIL unit\n")
commit(run.repo, "fix.txt", "fix\n", "fix the red check")
run.resume()
run.done(**{"untrackedDeferrals": [], "dismissed": [], "resolved": ["F1", "F1", json.dumps(plain, sort_keys=True)],
            "counts": {"raised": 0, "fixed": 1, "deferred": 0, "dismissed": 0}})
handed = {}
while run.answer and run.answer["action"] == "run":
    handed[run.answer["step"]["id"]] = run.answer["payload"]
    run.done()
risk = handed.get("capture", {}).get("riskCheck") or {}
check("an id resolves only the entry carrying it; a string shaped like an entry's JSON resolves nothing",
      risk.get("untrackedDeferrals") == [plain] and risk.get("counts", {}).get("deferred") == 1, risk)
check("... and an id named twice in one screen is kept once in the history",
      risk.get("resolved") == ["F1", json.dumps(plain, sort_keys=True)], risk.get("resolved"))

# --- step 0's guard carries on only a merge row done with an accepted MERGE: LANDED ---------------
GUARD = re.search(r"The merge row in `status` `done` with the verdict `([^`]+)` → the run carries on",
                  re.sub(r"\s+", " ", open(os.path.join(ROOT, "skills/build-item/SKILL.md"), encoding="utf-8").read()))
check("(build-item step 0 names the verdict its guard carries on)", GUARD is not None and GUARD.group(1) == "MERGE: LANDED")
def carries_on(run):
    """Step 0's guard as build-item spells it, read from the runner's status rows."""
    row = [r for r in run.call("status", {"item": "I123"})[1]["rows"] if r["stepId"] == "merge"][0]
    return row["status"] == "done" and (row["verdict"] or "").startswith(GUARD.group(1)), row
run = Run()
run.until("merge")
git(run.repo, "checkout", "-q", "main"); commit(run.repo, "readme.txt", "one\ntwo\n", "base moves"); git(run.repo, "checkout", "-q", "feature")
git(run.repo, "rebase", "-q", "main")
answer = run.done("MERGE: REFRESHED\n")
guard, row = carries_on(run)
check("a merge answered REFRESHED is a row done while its renewed checks run, and the guard does not carry it on",
      is_run(answer, "local-checks", 2) and row["status"] == "done" and row["verdict"].startswith("MERGE: REFRESHED") and not guard, row)
git(run.repo, "checkout", "-q", "main"); commit(run.repo, "done.txt", "finished elsewhere\n", "another run finishes the item")
git(run.repo, "checkout", "-q", "feature")
run.session = "s2"
answer = run.resume()
check("... so when another commit finished the item, the new session's resume hands back the renewed checks, not a merge",
      is_run(answer, "local-checks", 2) and answer.get("adoptedFrom", {}).get("sessionId") == "s1", answer)
answer = run.resume(close=True)
check("... and case (iii) closes the run, interrupted, with no second merge, completion or sync",
      finished(answer, "interrupted") and closes(answer, "interrupted")
      and [a for a in run.issued() if a[0] in ("merge", "complete", "sync")] == [("merge", 1)], (run.issued(), answer))

# --- interrupted after the merge and the completion: the new session finishes, nothing closed ---
run = Run()
answer = run.until("merge")
story = answer["payload"]["commit"]
git(run.repo, "checkout", "-q", "main"); git(run.repo, "merge", "-q", "--no-ff", "-m", "merge: I123", story)
run.done(canned("merge@1", run.repo, **{"proof.head": story}))
answer = run.until("capture")  # the completion step moved the item to Done; the session clears while capture runs
check("(the merge and the completion are done, the capture issued)", is_run(answer, "capture", 1)
      and [r for r in run.call("status", {"item": "I123"})[1]["rows"] if r["stepId"] in ("merge", "complete")] ==
      [r for r in run.call("status", {"item": "I123"})[1]["rows"] if r["stepId"] in ("merge", "complete") and r["status"] == "done"], answer)
check("(a merge answered LANDED is the row the guard carries on)", carries_on(run)[0], carries_on(run)[1])
run.session = "s2"
answer = run.resume()
check("a new session's resume of a run whose merge row is done hands back the capture as it was, on the base",
      is_run(answer, "capture", 1) and answer.get("adoptedFrom", {}).get("sessionId") == "s1", answer)
while run.answer and run.answer["action"] == "run":
    run.done()
issued = run.issued()
check("... and finishes the capture and the sync exactly once each, completed, never closed",
      finished(run.answer, "completed") and closes(run.answer, "completed")
      and sorted(set(a for a in issued if a[0] in ("capture", "sync"))) == [("capture", 1), ("sync", 1)]
      and [a for a in issued if a[0] == "complete"] == [("complete", 1)], (issued, run.answer))

# --- a baseline this checkout cannot read is never handed as one: a full screen, history kept ---
run = Run()
git(run.repo, "remote", "add", "origin", "https://example.com/acme/app.git")
run.rc, run.answer, _, _ = run.call("start", {"definitionFile": BUILD_FILE, "replace": True, "context": dict(CONTEXT, cwd=run.repo)})
run.until("risk-check")
run.done(**{"untrackedDeferrals": [{"id": "F1", "finding": "kept"}], "counts": {"raised": 1, "fixed": 0, "deferred": 1, "dismissed": 0}})
run.until("local-checks")
run.done("LOCAL CHECKS: FAIL unit\n")
clone = fresh("clone")  # a separate clone after a force-pushed rebase: the screened commit is not in it
git(clone, "init", "-q"); git(clone, "checkout", "-q", "-b", "main")
commit(clone, "readme.txt", "one\n", "first")
git(clone, "symbolic-ref", "refs/remotes/origin/main", "refs/heads/main")
git(clone, "checkout", "-q", "-b", "feature")
commit(clone, "export.txt", "export, rebased and fixed\n", "the story as force-pushed")
git(clone, "remote", "add", "origin", "https://example.com/acme/app.git")
env = dict(os.environ, XDG_CACHE_HOME=run.cache)
done = subprocess.run([sys.executable, "-B", RUNNER, "resume"], input=json.dumps({"item": "I123", "session": "s2"}),
                      capture_output=True, text=True, env=env, cwd=clone)
answer = json.loads(done.stdout) if done.returncode == 0 else None
check("a screened commit this checkout cannot read is not handed as the baseline: the payload says so, and keeps the history",
      is_run(answer, "risk-check", 2) and answer["payload"]["previousProof"] is None and answer["payload"]["baselineUnreadable"] is True
      and [e["id"] for e in answer["payload"]["previousResult"]["untrackedDeferrals"]] == ["F1"], (done.stderr, answer))
run = Run()
run.until("local-checks")
run.done("LOCAL CHECKS: FAIL unit\n")
commit(run.repo, "fix.txt", "fix\n", "fix the red check")
answer = run.resume()
check("(a readable baseline is handed with baselineUnreadable null)",
      is_run(answer, "risk-check", 2) and answer["payload"]["previousProof"] is not None and answer["payload"]["baselineUnreadable"] is None, answer)

# --- step 0, case (i): a merge pushed but never answered, picked up by a new session -----------
LANDING = re.findall(r"`(git rev-list --first-parent --parents origin/<workingBase>[^`]+)`",
                     re.sub(r"\s+", " ", open(os.path.join(ROOT, "skills/merge-story/references/merge-paths.md"), encoding="utf-8").read()))
check("(the landing test's merge command is spelled once in merge-paths.md)", len(LANDING) == 1, LANDING)
run = Run()
bare = fresh("origin")
git(bare, "init", "-q", "--bare")
git(run.repo, "symbolic-ref", "--delete", "refs/remotes/origin/main")
git(run.repo, "remote", "add", "origin", bare)
git(run.repo, "push", "-q", "origin", "main", "feature")
git(run.repo, "fetch", "-q", "origin")
answer = run.until("merge")
story = answer["payload"]["commit"]
git(run.repo, "checkout", "-q", "main"); git(run.repo, "merge", "-q", "--no-ff", "-m", "merge: I123", story)
git(run.repo, "push", "-q", "origin", "main")  # pushed; the session ends before it answers
run.session = "s2"
answer = run.resume()
check("a new session's resume hands back the merge as it was issued, on the base it left the checkout on",
      is_run(answer, "merge", 1) and answer["payload"]["commit"] == story and answer.get("adoptedFrom", {}).get("sessionId") == "s1", answer)
git(run.repo, "fetch", "-q", "origin")
found = subprocess.run(["bash", "-c", LANDING[0].replace("<workingBase>", "main").replace("<commit>", story)], cwd=run.repo,
                       capture_output=True, text=True).stdout.strip()
landed = git(run.repo, "rev-parse", "origin/main").decode().strip()
check("... the landing test finds exactly that commit's merge", found == landed, (found, landed))
run.done(canned("merge@1", run.repo, **{"sha": found, "proof.head": story}))
while run.answer and run.answer["action"] == "run":
    run.done()
check("... so it is reported with done, and the run finishes with its completion run exactly once",
      finished(run.answer, "completed") and [a for a in run.issued() if a[0] == "complete"] == [("complete", 1)], run.issued())

# --- a base that really moves: the risk check is bound to origin/<workingBase> ---------------------
def origin_run(rebase=False, base_ref="origin/main"):
    bare = fresh("origin")
    git(bare, "init", "-q", "--bare")
    run = Run()
    git(run.repo, "symbolic-ref", "--delete", "refs/remotes/origin/main")  # a real origin/main from here on
    git(run.repo, "remote", "add", "origin", bare)
    git(run.repo, "push", "-q", "origin", "main", "feature")
    git(run.repo, "fetch", "-q", "origin")
    def answer(step):
        """The canned answer with the facts measured from origin/main, and proofs naming it."""
        patch = git(run.repo, "patch-id", "--verbatim", stdin=git(run.repo, *(DIFF + ["origin/main...HEAD", "--"]))).decode().split()
        text = FIX["outputs"][step["contract"]]
        for key, value in dict(facts(run.repo), patchId=patch[0] if patch else "").items():
            text = text.replace("{%s}" % key, value)
        head, _, block = text.partition("```json\n")
        result = json.loads(block.split("```")[0])
        if step["contract"] == "review@1":
            result["proof"]["base"] = "origin/main"
        if step["contract"] == "risk-check@1":
            result["proof"]["base"] = base_ref if base_ref == "origin/main" else git(run.repo, "rev-parse", "origin/main").decode().strip()
        return head + "```json\n" + json.dumps(result) + "\n```\n"
    issued = []
    while run.answer["action"] == "run" and run.answer["step"]["id"] != "merge":
        run.done(answer(run.answer["step"]))
    first_head = facts(run.repo)["head"]
    other = fresh("other")
    git(other, "clone", "-q", bare, ".")
    git(other, "checkout", "-q", "main")
    commit(other, "upstream.txt", "another author's work\n", "another author lands")
    git(other, "push", "-q", "origin", "main")
    git(run.repo, "fetch", "-q", "origin")
    if rebase:
        git(run.repo, "rebase", "-q", "origin/main")
    else:
        git(run.repo, "merge", "-q", "--no-edit", "origin/main")
    run.done("MERGE: REFRESHED\n")
    while run.answer["action"] == "run" and run.answer["step"]["id"] != "merge":
        issued.append(run.answer["step"]["id"])
        run.done(answer(run.answer["step"]))
    return run, issued, first_head, answer
for rebase in (False, True):
    run, issued, first_head, answer = origin_run(rebase=rebase)
    how = "a rebase onto the moved base" if rebase else "the moved base merged into the story"
    check("after %s, with the risk proof on origin/main, the story is not screened again (only the local checks rerun)" % how,
          issued == ["local-checks"] and is_run(run.answer, "merge"), (issued, run.answer))
run, issued, first_head, answer = origin_run()
own = git(run.repo, "diff", "origin/main...HEAD").decode()
check("the story's own change after a base merge (origin/main...HEAD) holds none of the other author's work, which a plain diff from the screened head does",
      "export" in own and "another author's work" not in own and "another author's work" in git(run.repo, "diff", first_head, "HEAD").decode(), own)
commit(run.repo, "export.txt", "export\nlater fix\n", "a later fix on the story")
answer_now = run.done("MERGE: REFRESHED\n")
check("... while a later commit on the story after the base merge is screened again, from the head it last covered",
      is_run(answer_now, "risk-check", 2) and answer_now["payload"]["previousProof"]["head"] == first_head, answer_now)
for label, base, unlink in (("a commit id", "sha", False), ("the local branch", "main", False), ("an unreadable origin/main", "origin/main", True)):
    run = Run()
    run.until("risk-check")
    if base == "sha":
        base = git(run.repo, "rev-parse", "main").decode().strip()
    if unlink:
        git(run.repo, "symbolic-ref", "--delete", "refs/remotes/origin/main")  # a separate clone that never fetched
    answer = run.done(**{"proof.base": base})
    check("a risk proof whose base is %s is refused, never accepted as a screen of the story" % label,
          stopped(answer, "proof", "risk-check") and "origin/main" in answer["reason"] and ("local-checks", 1) not in run.issued(), answer)

# --- adopting a run: only in its own repository, re-bound to the adopting checkout ----------
run = Run()
git(run.repo, "remote", "add", "origin", "https://example.com/acme/app.git")
run.rc, run.answer, _, _ = run.call("start", {"definitionFile": BUILD_FILE, "replace": True, "context": dict(CONTEXT, cwd=run.repo)})
run.until("local-checks")
run.done("LOCAL CHECKS: FAIL unit\n")
elsewhere = fresh("elsewhere")
git(elsewhere, "init", "-q"); commit(elsewhere, "a.txt", "a\n", "a")
git(elsewhere, "remote", "add", "origin", "https://example.com/acme/other.git")
env = dict(os.environ, XDG_CACHE_HOME=run.cache)
done = subprocess.run([sys.executable, "-B", RUNNER, "resume"], input=json.dumps({"item": "I123", "session": "s2"}),
                      capture_output=True, text=True, env=env, cwd=elsewhere)
check("a run is never adopted from another repository's checkout (run-other-repository), and stays the old session's",
      done.returncode == 2 and "run-other-repository" in done.stderr and run.call("status", {"item": "I123"})[0] == 0, done.stderr)
second = fresh("second")
git(run.repo, "worktree", "add", "-q", "--detach", second, "feature")
done = subprocess.run([sys.executable, "-B", RUNNER, "resume"], input=json.dumps({"item": "I123", "session": "s2"}),
                      capture_output=True, text=True, env=env, cwd=second)
check("a run is never adopted into a checkout that is not on its story branch (wrong-branch), and nothing changes",
      done.returncode == 2 and "wrong-branch" in done.stderr and "feature" in done.stderr and run.call("status", {"item": "I123"})[0] == 0, done.stderr)
git(run.repo, "checkout", "-q", "--detach")  # the old checkout lets go of the story branch ...
git(second, "checkout", "-q", "feature")      # ... and the adopting one checks it out
done = subprocess.run([sys.executable, "-B", RUNNER, "resume"], input=json.dumps({"item": "I123", "session": "s2"}),
                      capture_output=True, text=True, env=env, cwd=second)
answer = json.loads(done.stdout) if done.returncode == 0 else None
check("a run is adopted in another checkout of the same repository on its story branch, and says which checkout it came from",
      is_run(answer, "local-checks", 2) and answer["adoptedFrom"] == {"sessionId": "s1", "cwd": os.path.realpath(run.repo)}, (done.stderr, answer))
commit(run.repo, "old.txt", "old checkout\n", "a commit in the old checkout")
run.session = "s2"
done = subprocess.run([sys.executable, "-B", RUNNER, "done"], capture_output=True, text=True, env=env, cwd=second,
                      input=json.dumps({"item": "I123", "session": "s2", "stepId": "local-checks", "attempt": 2, "output": canned("local-checks@1", second)}))
answer = json.loads(done.stdout) if done.returncode == 0 else None
check("... and its proofs are read there: a commit in the old checkout changes nothing",
      is_run(answer, "review", 1), (done.stderr, answer))
commit(second, "new.txt", "adopting checkout\n", "a commit in the adopting checkout")
done = subprocess.run([sys.executable, "-B", RUNNER, "done"], capture_output=True, text=True, env=env, cwd=second,
                      input=json.dumps({"item": "I123", "session": "s2", "stepId": "review", "attempt": 1, "output": canned("review@1", second)}))
answer = json.loads(done.stdout) if done.returncode == 0 else None
check("... while a commit in the adopting checkout is screened again", is_run(answer, "risk-check", 2), (done.stderr, answer))
git(second, "checkout", "-q", "--detach")
done = subprocess.run([sys.executable, "-B", RUNNER, "next"], input=json.dumps({"item": "I123", "session": "s2"}),
                      capture_output=True, text=True, env=env, cwd=second)
check("... and once adopted, it hands out no step while that checkout has left the story branch",
      done.returncode == 2 and "wrong-branch" in done.stderr, done.stderr)
git(second, "checkout", "-q", "feature")
done = subprocess.run([sys.executable, "-B", RUNNER, "next"], input=json.dumps({"item": "I123", "session": "s2"}),
                      capture_output=True, text=True, env=env, cwd=second)
check("... until it is back on it", done.returncode == 0 and is_run(json.loads(done.stdout), "risk-check", 2), done.stderr)

# --- a merge stop in a new session: answered with the stop, never cleared by the resume ------
run = Run()
answer = run.until("merge")
story = answer["payload"]["commit"]
git(run.repo, "checkout", "-q", "main"); git(run.repo, "merge", "-q", "--no-ff", "-m", "merge: I123", story)
answer = run.done(canned("merge@1", run.repo))
check("(a merge that names the base's head, not the story commit, stops the run)", stopped(answer, "proof", "merge"), answer)
run.session = "s2"
answer = run.resume()
check("a new session's resume of that run answers with the merge stop, its commit and attempt, adopting it",
      stopped(answer, "proof", "merge") and answer.get("mayHaveLanded") is True and answer.get("commit") == story
      and answer.get("attempt") == 1 and answer.get("adoptedFrom", {}).get("sessionId") == "s1", answer)
answer = run.call("done", {"item": "I123", "stepId": "merge", "attempt": 1, "output": canned("merge@1", run.repo, **{"proof.head": story})})[1]
check("... and the exact landing, reported with done, carries the run on to its completion", is_run(answer, "complete", 1), answer)

# --- a named one-off held by a release hold: nothing to select, so the loop must not go round ---
run = Run(context={"route": "train", "oneOff": True, "releaseUnit": None})
run.until("merge")
answer = run.done("MERGE: HELD Release hold: not before 2026-12-01\n")
check("(a release hold ends the run held)", finished(answer, "held"), answer)
rc, _, _, err = run.call("resume", {"item": "I123"})
rc2, again, _, _ = run.call("start", {"definitionFile": BUILD_FILE, "context": dict(CONTEXT, cwd=run.repo, route="train", oneOff=True, releaseUnit=None)})
check("after it, resume finds no run and a start builds the story again from the claim: why a named one-off's hold is a terminal exit",
      rc == 2 and "no-run" in err and rc2 == 0 and is_run(again, "claim", 1), (err, again))

# --- a stale run for an item finished elsewhere is closed, never carried on --------------------
run = Run()
run.until("local-checks")
run.done("LOCAL CHECKS: FAIL unit\n")
run.session = "s2"
answer = run.resume(close=True)
check("resume with close ends a run (adopted here) as interrupted, reporting its end",
      finished(answer, "interrupted") and closes(answer, "interrupted") and answer.get("adoptedFrom", {}).get("sessionId") == "s1", answer)
rc, _, _, err = run.call("resume", {"item": "I123"})
check("... and nothing is left to resume", rc == 2 and "no-run" in err, err)

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
elif [ "$N" -lt 90 ]; then bad "only $N cases ran, expected at least 90"
else ok "(all $N cases passed)"; fi
exit $FAIL
