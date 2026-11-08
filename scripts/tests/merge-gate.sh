#!/bin/bash
# Tests for skills/pr/scripts/merge-gate.py — the one gate before every merge. A `gh` on PATH
# answers from a scenario file (the pull request, its check contexts page by page, its review
# threads, the base's ruleset and classic protection) and logs every call, which proves the gate
# itself never merges. Then the shipped text: no skill merges with its own `--admin`, and every
# merge site runs the gate. No network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/skills/pr/scripts/merge-gate.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'PY'
#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
open(os.environ["GH_LOG"], "a").write(" ".join(a)[:120].replace("\n", " ") + "\n")
s = json.load(open(os.environ["GH_SCENARIO"]))
if a[:2] == ["repo", "view"]:
    print(s.get("repo", "acme/widgets")); sys.exit(0)
if a[:2] == ["api", "graphql"]:
    if s.get("graphqlFail"):
        sys.stderr.write("gh: Something went wrong (HTTP 502)\n"); sys.exit(1)
    q = next(x[6:] for x in a if x.startswith("query="))
    if "branchProtectionRule" in q:
        print(json.dumps({"data": {"repository": {"ref": {"branchProtectionRule": s.get("classic")}}}})); sys.exit(0)
    after = next((x[6:] for x in a if x.startswith("after=")), None)
    if "reviewThreads" in q:
        if s.get("threadsPartial"):
            print(json.dumps({"data": {"repository": {"pullRequest": {"reviewThreads": None}}}, "errors": [{"type": "NOT_FOUND", "path": ["repository", "pullRequest", "reviewThreads"]}]}))
            sys.exit(1)
        nodes = [{"isResolved": r} for r in s.get("threads", [])]
        print(json.dumps({"data": {"repository": {"pullRequest": {"reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": nodes}}}}}))
        sys.exit(0)
    if "potentialMergeCommit { oid statusCheckRollup" in q:
        m = s.get("mergeCommit")
        if s.get("mergeCommitVanishes"):
            m = None
        if s.get("mergeCommitMoves"):
            n = int(open(os.environ["GH_LOG"] + ".mc", "a+").seek(0, 2) or 0)
            open(os.environ["GH_LOG"] + ".mc", "a").write("x")
            if n < s["mergeCommitMoves"]:
                m = dict(m, oid="e" * 40)
        commit = None if m is None else {"oid": m["oid"], "statusCheckRollup": {"contexts": {"pageInfo": {"hasNextPage": False}, "nodes": m["nodes"]}}}
        print(json.dumps({"data": {"repository": {"pullRequest": {"potentialMergeCommit": commit}}}})); sys.exit(0)
    if s.get("pr") is None:
        print(json.dumps({"data": {"repository": {"pullRequest": None}}, "errors": [{"type": "NOT_FOUND", "path": ["repository", "pullRequest"], "message": "Could not resolve to a PullRequest"}]}))
        sys.exit(1)
    pages = s.get("pages", [[]])
    i = int(after[1:]) if after else 0
    more = i + 1 < len(pages)
    pr = dict(s["pr"])
    pr["latestOpinionatedReviews"] = {"pageInfo": {"hasNextPage": False}, "nodes": s.get("opinions", [])}
    pr["potentialMergeCommit"] = {"oid": s["mergeCommit"]["oid"]} if s.get("mergeCommit") else None
    pr["commits"] = {"nodes": [{"commit": {"oid": s.get("oid", pr["headRefOid"]), "statusCheckRollup": {"contexts": {
        "pageInfo": {"hasNextPage": more, "endCursor": "p%d" % (i + 1) if more else None}, "nodes": pages[i]}}}}]}
    print(json.dumps({"data": {"repository": {"pullRequest": pr}}})); sys.exit(0)
if a[0] == "api" and "/rules/branches/" in a[1]:
    objs = [{"context": c} for c in s.get("rules", [])] + s.get("ruleObjects", [])
    extra = [{"type": k} for k in s.get("ruleTypes", [])]
    print(json.dumps([{"type": "required_status_checks", "parameters": {"required_status_checks": objs,
                       "strict_required_status_checks_policy": bool(s.get("strict"))}},
                      {"type": "pull_request", "parameters": s.get("prRule", {"required_approving_review_count": 0, "require_code_owner_review": False})},
                      {"type": "update"}] + extra)); sys.exit(0)
if a[0] == "api" and "/actions/runs?head_sha=" in a[1]:
    if s.get("runsFail"):
        sys.stderr.write("gh: Not Found (HTTP 404)\n"); sys.exit(1)
    sha = a[1].split("head_sha=")[1].split("&")[0]
    nodes = (s.get("mergeCommit") or {}).get("nodes", []) if sha != s["pr"]["headRefOid"] else [n for page in s.get("pages", []) for n in page]
    runs = {}
    for n in nodes:
        w = ((n.get("checkSuite") or {}).get("workflowRun")) if n.get("__typename") == "CheckRun" else None
        if not w:
            continue
        r = runs.setdefault(w["databaseId"], {"id": w["databaseId"], "workflow_id": w["workflow"]["databaseId"], "run_number": w["runNumber"],
                                              "event": w["event"], "status": "completed", "conclusion": "success"})
        if n["status"] != "COMPLETED":
            r["status"], r["conclusion"] = "in_progress", None
        elif r["status"] == "completed" and n["conclusion"] in ("FAILURE", "CANCELLED", "TIMED_OUT"):
            r["conclusion"] = n["conclusion"].lower()
    out = list(runs.values()) + s.get("extraRuns", [])
    for r in out:
        m = 18 * 60 + r["id"] % 100000   # by default a run began in run-number order
        r.setdefault("run_started_at", s.get("runStarted", {}).get(str(r["id"]), "2026-01-15T%02d:%02d:00Z" % (m // 60, m % 60)))
        r.setdefault("run_attempt", 2 if str(r["id"]) in s.get("runStarted", {}) else 1)   # a moved start is a re-run
    print(json.dumps({"total_count": len(out), "workflow_runs": out})); sys.exit(0)
if a[0] == "api" and "/compare/" in a[1]:
    print(json.dumps({"behind_by": s.get("behindBy", 0), "ahead_by": 3})); sys.exit(0)
if a[0] == "api" and a[1].endswith("/protection/required_status_checks"):
    p = s.get("protection", {"code": 404})
    if p.get("code") == "branch":
        print(json.dumps({"name": "release", "commit": {"sha": "x"}})); sys.exit(0)
    if p.get("code") == 404:
        m = p.get("message", "Branch not protected")
        print(json.dumps({"message": m})); sys.stderr.write("gh: %s (HTTP 404)\n" % m); sys.exit(1)
    if p.get("code") == 403:
        print('{"message":"Must have admin rights"}'); sys.stderr.write("gh: Must have admin rights to Repository. (HTTP 403)\n"); sys.exit(1)
    apps = p.get("checksApp", {})
    ctx = p.get("contexts", [])
    print(json.dumps({"contexts": ctx, "checks": [{"context": c, "app_id": apps.get(c)} for c in ctx]})); sys.exit(0)
sys.stderr.write("gh stub: unexpected call %r\n" % a); sys.exit(1)
PY
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH" GH_LOG="$WORK/gh.log"

OUT="$(python3 - "$HELPER" "$WORK" <<'PY'
import copy, json, os, shlex, subprocess, sys
helper, work = sys.argv[1], sys.argv[2]
H = "a" * 40
def run(number, sha, scenario, *extra):
    path = os.path.join(work, "scenario.json"); json.dump(scenario, open(path, "w"))
    p = subprocess.run([sys.executable, helper, str(number), sha] + list(extra), capture_output=True, text=True,
                       env=dict(os.environ, GH_SCENARIO=path))
    return p.returncode, p.stdout.strip().split("\n"), p.stderr
def say(good, label, extra=""):
    print(("ok   " if good else "FAIL ") + label + ("" if good else " -> " + extra))
WF = {"tests": 1, "plan": 1, "lint": 2, "lint-plan": 2, "optional": 3}   # the workflow of each check, unless a case names one
def cr(name, conclusion="SUCCESS", status="COMPLETED", ident=1, required=True, app=15368, workflow="auto", run=None, event="pull_request"):
    workflow = WF.get(name, 9) if workflow == "auto" else workflow
    return {"__typename": "CheckRun", "name": name, "status": status, "conclusion": conclusion if status == "COMPLETED" else None,
            "startedAt": "2026-01-15T18:00:00Z" if status != "QUEUED" else None, "databaseId": ident, "isRequired": required,
            "checkSuite": {"app": {"databaseId": app}, "workflowRun": {"databaseId": workflow * 100000 + (run if run is not None else ident), "runNumber": run if run is not None else ident, "event": event, "workflow": {"databaseId": workflow}} if workflow else None}}
def st(context, state="SUCCESS", required=True):
    return {"__typename": "StatusContext", "context": context, "state": state, "createdAt": "2026-01-15T18:00:00Z", "isRequired": required}
GREEN = {"pr": {"number": 7, "state": "OPEN", "isDraft": False, "headRefOid": H, "baseRefName": "develop",
                "mergeStateStatus": "BLOCKED", "reviewDecision": None},
         "pages": [[cr("tests", ident=10), cr("lint", ident=11), cr("optional", "FAILURE", ident=12, required=False)]],
         "rules": ["tests", "lint"], "threads": [True, True]}
def sc(**changes):
    s = copy.deepcopy(GREEN)
    for k, v in changes.items():
        if k in ("state", "isDraft", "headRefOid", "mergeStateStatus", "reviewDecision", "baseRefName"):
            s["pr"][k] = v
        else:
            s[k] = v
    return s
def merge(label, scenario, line, *extra):
    code, out, err = run(7, H, scenario, *extra)
    say(code == 0 and out[0] == line and len(out) == 2, label, "rc=%d %r %r" % (code, out, err))
def refuse(label, scenario, text, code_wanted=2, sha=H):
    code, out, err = run(7, sha, scenario)
    word = "REFUSE " if code_wanted == 2 else "ERROR "
    say(code == code_wanted and len(out) == 1 and out[0].startswith(word) and text in out[0] and "Traceback" not in err, label, "rc=%d %r %r" % (code, out, err))

merge("(1) every required check green, blocked by the base's rules -> MERGE with --admin, pinned to the head",
      GREEN, "MERGE gh pr merge 7 --repo acme/widgets --merge --match-head-commit %s --admin" % H)
merge("(2) clean (no admin-only rule) -> MERGE without --admin; --delete-branch carried",
      sc(mergeStateStatus="CLEAN"), "MERGE gh pr merge 7 --repo acme/widgets --merge --match-head-commit %s --delete-branch" % H, "--delete-branch")
SUBJECT = "Merge pull request #7 from acme/I1-fix's"
code, out, err = run(7, H, sc(mergeStateStatus="CLEAN"), "--delete-branch", "--subject", SUBJECT)
words = shlex.split(out[0])[1:] if code == 0 else []
say(words[-2:] == ["--subject", SUBJECT] and words[:10] == ["gh", "pr", "merge", "7", "--repo", "acme/widgets", "--merge", "--match-head-commit", H, "--delete-branch"],
    "(2b) a train merge's subject is carried, quoted so the line runs as printed", "rc=%d %r" % (code, out))
merge("(3) unstable (only a check that is not required failed) -> MERGE without --admin",
      sc(mergeStateStatus="UNSTABLE"), "MERGE gh pr merge 7 --repo acme/widgets --merge --match-head-commit %s" % H)
refuse("(4) a required check pending -> REFUSE naming it", sc(pages=[[cr("tests", status="IN_PROGRESS", ident=10), cr("lint", ident=11)]]), "tests is pending")
refuse("(5) a required check failed -> REFUSE", sc(pages=[[cr("tests", "FAILURE", ident=10), cr("lint", ident=11)]]), "tests is failure")
merge("(6) a required check skipped in a run where another job succeeded passes (its run found nothing to test)",
      sc(pages=[[cr("tests", "SKIPPED", ident=10), cr("plan", ident=13, run=10, required=False),
                 cr("lint", "NEUTRAL", ident=11), cr("lint-plan", ident=14, run=11, required=False)]]),
      "MERGE gh pr merge 7 --repo acme/widgets --merge --match-head-commit %s --admin" % H)
refuse("(6f) a run where every job skipped (a draft's held CI, newest just after the ready flip) -> REFUSE",
       sc(pages=[[cr("tests", "SKIPPED", ident=10), cr("plan", "SKIPPED", ident=13, run=10, required=False), cr("lint", ident=11)]]),
       "tests is skipped in a run where nothing ran")
refuse("(6g) a neutral check from outside any workflow proves nothing -> REFUSE",
       sc(pages=[[cr("tests", ident=10), cr("lint", "NEUTRAL", ident=11, workflow=None)]]), "lint is skipped in a run where nothing ran")
merge("(6h) an all-skipped newest run over an older run of the same check that succeeded passes",
      sc(pages=[[cr("tests", ident=10, run=1), cr("tests", "SKIPPED", ident=20, run=2), cr("lint", ident=11)]]),
      "MERGE gh pr merge 7 --repo acme/widgets --merge --match-head-commit %s --admin" % H)
refuse("(6i) a manual (workflow_dispatch) run never hides an older failed run of the same check",
       sc(pages=[[cr("tests", "FAILURE", ident=10, run=1, event="push"), cr("tests", ident=20, run=2, event="workflow_dispatch"), cr("lint", ident=11)]]),
       "tests is failure")
refuse("(6j) a required check only a manual run reported never ran, as GitHub reads it",
       sc(pages=[[cr("tests", ident=20, event="workflow_dispatch"), cr("lint", ident=11)]]), "tests never ran at this head")
refuse("(6l) a later push run's success never hides a failed pull_request run of the same check",
       sc(pages=[[cr("tests", "FAILURE", ident=10, run=1), cr("tests", ident=20, run=2, event="push"), cr("lint", ident=11)]]), "tests is failure")
merge("(6m) a push run where every job skipped beside a pull_request run that succeeded passes (a develop push with its suite off)",
      sc(pages=[[cr("tests", ident=10, run=2), cr("tests", "SKIPPED", ident=20, run=1, event="push"), cr("lint", ident=11)]]),
      "MERGE gh pr merge 7 --repo acme/widgets --merge --match-head-commit %s --admin" % H)
refuse("(6n) an older run re-run after a newer one passed, and failing, counts: re-runs keep their number but start later",
       sc(pages=[[cr("tests", "FAILURE", ident=30, run=1), cr("tests", ident=20, run=2), cr("lint", ident=11)]], runStarted={"100001": "2026-01-15T19:00:00Z"}), "tests is failure")
refuse("(6o) an older run still running beside a newer one that passed -> REFUSE pending",
       sc(pages=[[cr("tests", status="IN_PROGRESS", ident=10, run=1), cr("tests", ident=20, run=2), cr("lint", ident=11)]]), "tests is pending")
merge("(6p) an older run cancelled before the newer one started (a concurrency group) does not count",
      sc(pages=[[cr("tests", "CANCELLED", ident=10, run=1), cr("tests", ident=20, run=2), cr("lint", ident=11)]]),
      "MERGE gh pr merge 7 --repo acme/widgets --merge --match-head-commit %s --admin" % H)
refuse("(6q) a re-run's success never skips the failed run the other order still sees (run 2 failed, run 3 skipped, run 1 re-run green)",
       sc(runStarted={"100001": "2026-01-15T19:00:00Z"}, pages=[[cr("tests", ident=40, run=1), cr("tests", "FAILURE", ident=20, run=2),
                  cr("tests", "SKIPPED", ident=30, run=3), cr("lint", ident=11)]]), "tests is failure")
refuse("(6r) a job still running beside a failed sibling in an older run is pending, never superseded",
       sc(pages=[[cr("tests", "FAILURE", ident=10, run=1), cr("tests", status="IN_PROGRESS", ident=11, run=1),
                  cr("tests", ident=20, run=2), cr("lint", ident=12)]]), "tests is pending")
refuse("(6s) a partial re-run is timed by its run's latest attempt, not its jobs: an older run's kept green job never makes it read old",
       sc(runStarted={"100001": "2026-01-15T19:00:00Z"}, pages=[[cr("plan", ident=5, run=1, required=False), cr("tests", "FAILURE", ident=30, run=1),
                  cr("tests", ident=20, run=2), cr("lint", ident=11)]]), "tests is failure")
refuse("(6t) the workflow runs at the head that cannot be listed are an ERROR, never a guess",
       sc(runsFail=True), "actions/runs", 1)
refuse("(6u) a newer run still going before it has created the required check holds it pending (a matrix still being generated)",
       sc(extraRuns=[{"id": 100050, "workflow_id": 1, "run_number": 50, "event": "pull_request", "status": "in_progress", "conclusion": None}]),
       "tests is pending")
refuse("(6v) a newer run that ended red without reporting the check refuses",
       sc(extraRuns=[{"id": 100050, "workflow_id": 1, "run_number": 50, "event": "pull_request", "status": "completed", "conclusion": "failure"}]),
       "workflow run #50 ended so without reporting it")
merge("(6w) a run of another workflow, or from another event, still going does not hold this check",
      sc(extraRuns=[{"id": 700050, "workflow_id": 7, "run_number": 50, "event": "pull_request", "status": "in_progress", "conclusion": None},
                    {"id": 100051, "workflow_id": 1, "run_number": 51, "event": "workflow_dispatch", "status": "in_progress", "conclusion": None}]),
      "MERGE gh pr merge 7 --repo acme/widgets --merge --match-head-commit %s --admin" % H)
merge("(6x) a first attempt never supersedes a higher-numbered run, even when both began in the same second (a concurrency cancel)",
      sc(runStarted={}, pages=[[cr("tests", "CANCELLED", ident=10, run=1), cr("tests", ident=20, run=2), cr("lint", ident=11)]],
         extraRuns=[]), "MERGE gh pr merge 7 --repo acme/widgets --merge --match-head-commit %s --admin" % H)
refuse("(6k) a scheduled run's success does not count either",
       sc(pages=[[cr("tests", ident=20, event="schedule"), cr("lint", ident=11)]]), "tests never ran at this head")
refuse("(6b) a skipped newest run never hides an older run of the same check that failed",
       sc(pages=[[cr("tests", "FAILURE", ident=10), cr("tests", "SKIPPED", ident=20), cr("lint", ident=11)]]), "tests is failure")
refuse("(6c) a skipped newest run never hides one still running",
       sc(pages=[[cr("tests", status="IN_PROGRESS", ident=10), cr("tests", "SKIPPED", ident=20), cr("lint", ident=11)]]), "tests is pending")
merge("(6d) concurrent runs: the later workflow run counts though its check run has the lower id",
      sc(pages=[[cr("tests", "SKIPPED", ident=50, run=1), cr("tests", ident=40, run=2), cr("lint", ident=11)]]),
      "MERGE gh pr merge 7 --repo acme/widgets --merge --match-head-commit %s --admin" % H)
refuse("(6e) concurrent runs: a later workflow run that failed counts though its id is lower",
       sc(pages=[[cr("tests", ident=50, run=1), cr("tests", "FAILURE", ident=40, run=2), cr("lint", ident=11)]]), "tests is failure")
refuse("(7) a required check cancelled -> REFUSE", sc(pages=[[cr("tests", "CANCELLED", ident=10), cr("lint", ident=11)]]), "tests is cancelled")
refuse("(8) a required check that never ran at this head -> REFUSE", sc(rules=["tests", "lint", "sast"]), "sast never ran at this head")
refuse("(9) the head moved -> REFUSE", GREEN, "the head moved", sha="b" * 40)
refuse("(9b) the newest commit is not the head the pull request names -> REFUSE", sc(oid="c" * 40), "the head moved")
refuse("(10) not a pull request -> REFUSE", sc(pr=None), "is not a pull request")
refuse("(11) a draft -> REFUSE", sc(isDraft=True), "is a draft")
refuse("(12) merged already -> REFUSE", sc(state="MERGED"), "is merged, not open")
refuse("(13) conflicts -> REFUSE, never an admin bypass", sc(mergeStateStatus="DIRTY"), "has conflicts")
refuse("(14) behind a base that must be current -> REFUSE", sc(mergeStateStatus="BEHIND"), "is behind develop")
refuse("(15) GitHub still computing -> REFUSE", sc(mergeStateStatus="UNKNOWN"), "finished computing")
refuse("(16) an unresolved review thread -> REFUSE", sc(threads=[True, False]), "1 unresolved review thread")
refuse("(17) changes requested -> REFUSE", sc(reviewDecision="CHANGES_REQUESTED"), "requesting changes")
refuse("(17b) a reviewer's latest review requests changes though reviews are not required (empty decision) -> REFUSE",
       sc(opinions=[{"state": "APPROVED", "author": {"login": "amy"}}, {"state": "CHANGES_REQUESTED", "author": {"login": "bo"}}]),
       "bo requested changes")
merge("(17c) a reviewer who requested changes and then approved does not block",
      sc(opinions=[{"state": "APPROVED", "author": {"login": "bo"}}]), "MERGE gh pr merge 7 --repo acme/widgets --merge --match-head-commit %s --admin" % H)
refuse("(17d) a required check green on the head but failed on the test merge commit -> REFUSE",
       sc(mergeCommit={"oid": "d" * 40, "nodes": [st("lint", "FAILURE")]}), "failed on the test merge commit")
merge("(17e) the test merge commit carries only green or unrelated checks: merges",
      sc(mergeCommit={"oid": "d" * 40, "nodes": [st("lint"), st("unrelated", "FAILURE", required=False)]}),
      "MERGE gh pr merge 7 --repo acme/widgets --merge --match-head-commit %s --admin" % H)
refuse("(17f) a rule bound to an app is not met by a commit status of that name -> REFUSE naming why",
       sc(rules=["lint"], ruleObjects=[{"context": "tests", "integration_id": 15368}], pages=[[st("tests"), cr("lint", ident=11)]]),
       "cannot show which app sent it")
refuse("(18) blocked with no required check at all -> REFUSE: nothing proves the head green",
       sc(rules=[], pages=[[cr("tests", ident=10, required=False)]]), "requires no check")
merge("(19) no required check and clean -> MERGE plainly (a train with no rules)",
      sc(rules=[], mergeStateStatus="CLEAN", pages=[[]]), "MERGE gh pr merge 7 --repo acme/widgets --merge --match-head-commit %s" % H)
refuse("(20) classic protection unreadable -> REFUSE", sc(protection={"code": 403}), "cannot be read with this login")
refuse("(21) a check only classic protection requires, failing -> REFUSE",
       sc(protection={"code": 200, "contexts": ["build"]}, pages=[[cr("tests", ident=10), cr("lint", ident=11), cr("build", "FAILURE", ident=12, required=False)]]),
       "build is failure")
refuse("(22) a check GitHub marks required but no ruleset names, failing -> REFUSE",
       sc(rules=["tests"], pages=[[cr("tests", ident=10), cr("lint", "TIMED_OUT", ident=11)]]), "lint is timed_out")
refuse("(22b) two same-name jobs in one workflow run are siblings: a failing one is never hidden by a later green one",
       sc(pages=[[cr("tests", "FAILURE", ident=10, run=5), cr("tests", ident=20, run=5), cr("lint", ident=11)]]), "tests is failure")
merge("(23) a later workflow run of the check counts over an earlier failed one",
      sc(pages=[[cr("tests", "FAILURE", ident=10, run=5), cr("tests", ident=20, run=6), cr("lint", ident=11)]]),
      "MERGE gh pr merge 7 --repo acme/widgets --merge --match-head-commit %s --admin" % H)
refuse("(24) a later workflow run still queued counts -> REFUSE",
       sc(pages=[[cr("tests", ident=10, run=5), cr("tests", status="QUEUED", ident=20, run=6), cr("lint", ident=11)]]), "tests is pending")
refuse("(25) a required commit status pending -> REFUSE",
       sc(rules=["tests", "lint", "deploy/preview"], pages=[[cr("tests", ident=10), cr("lint", ident=11), st("deploy/preview", "PENDING")]]),
       "deploy/preview is pending")
refuse("(25b) a green check run does not hide a failing commit status of the same name -> REFUSE",
       sc(pages=[[cr("tests", ident=10), st("tests", "FAILURE"), cr("lint", ident=11)]]), "tests (commit status) is failure")
refuse("(25c) a green job does not hide a failing same-name job in another workflow -> REFUSE",
       sc(pages=[[cr("tests", "FAILURE", ident=10, workflow=1), cr("tests", ident=30, workflow=2), cr("lint", ident=11)]]), "tests (app 15368, workflow 1) is failure")
refuse("(25d) a check the rules require from one app, green only from another app -> REFUSE",
       sc(rules=[], ruleObjects=[{"context": "tests", "integration_id": 15368}, {"context": "lint"}],
          pages=[[cr("tests", ident=10, app=999, required=False), cr("lint", ident=11)]]), "tests from app 15368 never ran at this head")
merge("(25e) the required app's green run satisfies its rule",
      sc(rules=[], ruleObjects=[{"context": "tests", "integration_id": 15368}, {"context": "lint"}]),
      "MERGE gh pr merge 7 --repo acme/widgets --merge --match-head-commit %s --admin" % H)
refuse("(25f) classic protection's app-bound check from another app -> REFUSE",
       sc(protection={"code": 200, "contexts": ["tests"], "checksApp": {"tests": 15368}}, pages=[[cr("tests", ident=10, app=7, required=False), cr("lint", ident=11)]]),
       "tests from app 15368 never ran at this head")
merge("(26) check contexts over two pages are all read",
      sc(pages=[[cr("tests", ident=10)], [cr("lint", ident=11)]]), "MERGE gh pr merge 7 --repo acme/widgets --merge --match-head-commit %s --admin" % H)
refuse("(26b) a failure on the second page is seen",
       sc(pages=[[cr("tests", ident=10)], [cr("lint", "FAILURE", ident=11)]]), "lint is failure")
refuse("(27) GitHub unreadable -> ERROR, exit 1, never a merge", sc(graphqlFail=True), "gh api graphql failed", code_wanted=1)
refuse("(27b) review threads that come back as an error with partial data -> ERROR, never zero threads", sc(threadsPartial=True), "carried errors", code_wanted=1)
refuse("(27c) a protection answer that is not a required-checks answer -> ERROR", sc(protection={"code": "branch"}), "not a required-status-checks answer", code_wanted=1)
merge("(27e) classic 404 'Required status checks not enabled' is no protection",
      sc(protection={"code": 404, "message": "Required status checks not enabled"}), "MERGE gh pr merge 7 --repo acme/widgets --merge --match-head-commit %s --admin" % H)
refuse("(27f) any other classic 404 is ERROR, never 'no protection'", sc(protection={"code": 404, "message": "Not Found"}), "not one of GitHub's no-protection answers", code_wanted=1)
refuse("(27g) a strict base: a head behind it -> REFUSE even though GitHub reads BLOCKED", sc(strict=True, behindBy=2), "2 commit(s) behind develop")
merge("(27h) a strict base: a head up to date with it merges", sc(strict=True, behindBy=0), "MERGE gh pr merge 7 --repo acme/widgets --merge --match-head-commit %s --admin" % H)
refuse("(27m) blocked, one approval required and none given -> REFUSE: --admin would skip it",
       sc(prRule={"required_approving_review_count": 1}, reviewDecision="REVIEW_REQUIRED"), "still needs an approving review")
refuse("(27n) blocked, code-owner review required, decision empty -> REFUSE", sc(prRule={"require_code_owner_review": True}), "require_code_owner_review")
merge("(27o) blocked, approval required and given -> MERGE --admin",
      sc(prRule={"required_approving_review_count": 1}, reviewDecision="APPROVED"), "MERGE gh pr merge 7 --repo acme/widgets --merge --match-head-commit %s --admin" % H)
refuse("(27p) signed commits required: never bypassed with --admin", sc(ruleTypes=["required_signatures"]), "required_signatures")
merge("(27q) the base moves once during the read: one fresh read, then MERGE",
      sc(mergeCommit={"oid": "d" * 40, "nodes": [st("lint")]}, mergeCommitMoves=1), "MERGE gh pr merge 7 --repo acme/widgets --merge --match-head-commit %s --admin" % H)
refuse("(27r) the base keeps moving: REFUSE asking to run again", sc(mergeCommit={"oid": "d" * 40, "nodes": [st("lint")]}, mergeCommitMoves=9), "run the gate again")
refuse("(17g) a required app's check on the head, only another app's of that name on the test merge commit -> REFUSE",
       sc(rules=["lint"], ruleObjects=[{"context": "tests", "integration_id": 15368}],
          mergeCommit={"oid": "d" * 40, "nodes": [cr("tests", ident=90, app=7, required=False)]}), "tests from app 15368 never ran")
refuse("(27s) the test merge commit vanishes mid-read (GitHub regenerating it): never read as 'no checks'",
       sc(mergeCommit={"oid": "d" * 40, "nodes": [st("lint", "FAILURE")]}, mergeCommitVanishes=True), "run the gate again")
refuse("(27t) classic protection requires a deployment: an admin merge would bypass it -> REFUSE",
       sc(classic={"pattern": "develop", "requiresDeployments": True}), "requiresDeployments")
refuse("(27u) classic protection requires approving reviews, decision empty -> REFUSE",
       sc(classic={"pattern": "dev*", "requiresApprovingReviews": True}), "requiresApprovingReviews")
merge("(27v) classic protection requiring nothing the gate cannot prove -> MERGE --admin",
      sc(classic={"pattern": "develop", "requiresDeployments": False, "lockBranch": False}),
      "MERGE gh pr merge 7 --repo acme/widgets --merge --match-head-commit %s --admin" % H)
refuse("(27i) blocked with a rule the gate cannot judge -> REFUSE, never a silent admin bypass", sc(ruleTypes=["workflows"]), "rule(s) this gate cannot judge (workflows)")
merge("(27j) the same unknown rule on a clean pull request: GitHub enforces it, no --admin",
      sc(ruleTypes=["code_scanning"], mergeStateStatus="CLEAN"), "MERGE gh pr merge 7 --repo acme/widgets --merge --match-head-commit %s" % H)
code, out, err = run(7, H, GREEN, "--all-green")
say(code == 2 and out[0].startswith("REFUSE --all-green") and "optional is failure" in out[0], "(27k) --all-green refuses a red check that is not required", "rc=%d %r" % (code, out))
merge("(27l) --all-green with every check green merges",
      sc(pages=[[cr("tests", ident=10), cr("lint", ident=11), cr("optional", "SKIPPED", ident=12, run=10, required=False)]]),
      "MERGE gh pr merge 7 --repo acme/widgets --merge --match-head-commit %s --admin" % H, "--all-green")
code, out, err = run(7, H, sc(pages=[[cr("tests", ident=10), cr("lint", ident=11), cr("optional", "SKIPPED", ident=12, required=False)]]), "--all-green")
say(code == 0 and out[0].startswith("MERGE "), "(27m) --all-green reads a check that is not required as GitHub does: a run that only skips passes", "rc=%d %r" % (code, out))
code, out, err = run(7, H, sc(pages=[[cr("tests", "SKIPPED", ident=10), cr("lint", ident=11)]]), "--all-green")
say(code == 2 and "tests is skipped in a run where nothing ran" in out[0], "(27n) --all-green still refuses a required check whose run ran nothing", "rc=%d %r" % (code, out))
code, out, err = run(7, H, sc(baseRefName="release#v1/x"))
log = open(os.environ["GH_LOG"]).read()
say(code == 0 and "rules/branches/release%23v1%2Fx?" in log and "branches/release%23v1%2Fx/protection" in log,
    "(27d) the base branch is URL-encoded in both REST paths", "rc=%d %r" % (code, [l for l in log.splitlines() if "branches/" in l][-2:]))
for label, args in (("no arguments", []), ("a short SHA", ["7", "abc123"]), ("a number that is not one", ["x", H]), ("a bad --repo", ["7", H, "--repo", "a b"])):
    p = subprocess.run([sys.executable, helper] + args, capture_output=True, text=True, env=dict(os.environ, GH_SCENARIO=os.path.join(work, "scenario.json")))
    say(p.returncode == 2 and p.stdout == "" and p.stderr.startswith("usage:"), "(28) usage: " + label, repr(p.stderr))
log = open(os.environ["GH_LOG"]).read()
say("pr merge" not in log and "pulls/" not in log, "(29) the gate never merges: no merge call in %d gh calls" % len(log.splitlines()))
PY
)"
echo "$OUT" | sed 's/^/  /'
FAIL=0; echo "$OUT" | grep -q '^FAIL' && FAIL=1
[ "$(echo "$OUT" | grep -c '^ok')" -ge 92 ] || { echo "  FAIL too few cases ran"; FAIL=1; }

# The shipped text: a merge is the gate's printed command, never a skill's own --admin.
# The invariants catalogue describes the rule and is never run, so it is the one file excluded.
BARE="$(grep -rn -- '--admin' "$ROOT/skills" "$ROOT/hooks" | grep -v 'skills/pr/scripts/merge-gate.py' \
  | grep -v 'skills/review/references/delivery-loop-invariants.md' | grep -vi 'merge-gate' || true)"
[ -z "$BARE" ] && echo "  ok   (30) no shipped text merges with its own --admin" || { echo "  FAIL (30) a bare --admin: $BARE"; FAIL=1; }
for site in skills/release/SKILL.md skills/release/references/release-branch.md skills/release/references/auto-start.md \
            skills/build-item/SKILL.md skills/build-item/references/epic-release-steps.md; do
  grep -q 'merge-gate.py' "$ROOT/$site" && echo "  ok   (31) $site runs the merge gate" || { echo "  FAIL (31) $site merges without merge-gate.py"; FAIL=1; }
done
exit $FAIL
