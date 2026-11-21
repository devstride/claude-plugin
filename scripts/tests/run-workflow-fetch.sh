#!/bin/bash
# Tests for the step runner's handling of the workflow the tracker answers for an item
# (skills/run-workflow/scripts/workflow.py start with `fetched`), its `repository` command, and
# repository skill steps (run.source "repo") read from committed HEAD. Every case in
# skills/run-workflow/scripts/fetch-fixtures.json, the error codes, pinning, and real temporary git
# repositories made in this script's own temporary folder. No network, no tracker call.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export PYTHONDONTWRITEBYTECODE=1
unset CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID GIT_DIR GIT_WORK_TREE
export XDG_CACHE_HOME="$WORK/cache"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1
printf '[user]\n\tname = Test\n\temail = test@example.com\n[init]\n\tdefaultBranch = main\n[protocol "file"]\n\tallow = always\n' > "$GIT_CONFIG_GLOBAL"

python3 - "$ROOT" "$WORK" <<'PY'
import copy, hashlib, json, os, subprocess, sys
ROOT, WORK = sys.argv[1], sys.argv[2]
RUNNER = os.path.join(ROOT, "skills/run-workflow/scripts/workflow.py")
FIX = json.load(open(os.path.join(ROOT, "skills/run-workflow/scripts/fetch-fixtures.json"), encoding="utf-8"))
REAL = json.load(open(os.path.join(ROOT, "skills/run-workflow/scripts/workflow-fixtures.json"), encoding="utf-8"))
failed = [0]
count = [0]


def check(label, good, detail=""):
    count[0] += 1
    print(("  ok   " if good else "  FAIL ") + label + ("" if good else " -> %r" % (detail,)))
    if not good:
        failed[0] = 1


def run(command, request=None, cwd=None):
    done = subprocess.run([sys.executable, "-B", RUNNER, command], input=None if request is None else json.dumps(request),
                          capture_output=True, text=True, cwd=cwd or WORK, timeout=60)
    answer = json.loads(done.stdout) if done.returncode == 0 and done.stdout.strip() else None
    return done.returncode, answer, done.stdout, done.stderr


def git(cwd, *args):
    return subprocess.run(["git", "-C", cwd] + list(args), capture_output=True, check=True).stdout


seq = [0]


def session():
    seq[0] += 1
    return "fetch-test-%d" % seq[0]


def start(fetched=None, session_id=None, definition=None, context=None, cwd=None, extra=None):
    request = {"definition": definition or FIX["builtin"], "context": dict(context or FIX["context"]),
               "session": session_id or session()}
    if fetched is not None:
        request["fetched"] = fetched
    request.update(extra or {})
    return run("start", request, cwd=cwd)


def sid_status(session_id, cwd=None):
    return run("status", {"session": session_id, "item": FIX["context"]["item"]}, cwd=cwd)


import importlib.util
_spec = importlib.util.spec_from_file_location("report_under_test", os.path.join(ROOT, "skills/build-item/scripts/workflow_report.py"))
_report = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_report)
definition_hash = _report.definition_hash

# --- the decision, case by case -----------------------------------------------------------------
print("decision")
rc, answer, out, err = start()
check("no fetched: built-in pinned, no notice", rc == 0 and answer["definitionSource"] == "builtin" and answer["notice"] is None, (rc, err))
builtin_id = FIX["builtin"]["id"]
check("... and the reported identity is the built-in one", answer and answer["workflow"] == {
    "id": builtin_id, "name": FIX["builtin"]["name"], "version": FIX["builtin"]["version"], "hash": definition_hash(FIX["builtin"])}, answer and answer["workflow"])
for code in FIX["errors"]:
    sid = session()
    rc, answer, out, err = start({"error": code}, session_id=sid)
    check("error %s: built-in, no notice" % code, rc == 0 and answer["definitionSource"] == "builtin" and answer["notice"] is None
          and "notice\": \"" not in out and err == "", (rc, err, answer and answer.get("notice")))
    rc, status, _, _ = sid_status(sid)
    check("... status shows the unavailable source", rc == 0 and status["source"] == "built-in (DevStride unavailable)"
          and status["workflow"] == "Workflow: built-in %s" % FIX["builtin"]["name"], status)
    state = json.load(open(os.path.join(WORK, "cache/devstride-plugin/workflows", "%s.%s.json" % (sid, FIX["context"]["item"]))))
    check("... and keeps the code as fallbackReason", state["fallbackReason"] == code and state["definitionSource"] == "builtin", state.get("fallbackReason"))
rc, answer, _, _ = start({"error": "SOMETHING ELSE"})
check("an unknown error code is ERROR, silently", rc == 0 and answer["notice"] is None and answer["definitionSource"] == "builtin")
rc, answer, _, _ = start("not an object")
check("an answer that is not an object is a silent built-in run", rc == 0 and answer["notice"] is None and answer["definitionSource"] == "builtin")

NOTICE_START = {
    "incomplete": "DevStride sent an incomplete workflow; running the built-in workflow.",
    "integrity": "The workflow from DevStride failed its integrity check; running the built-in workflow.",
    "plugin-too-old": "This workflow needs plugin 4.10.0 or newer (this is ",
    "unrunnable": "The workflow from DevStride could not be run by this plugin (",
}
for case in FIX["answers"]:
    expect = case["expect"]
    answer_in = case["answer"]
    match = answer_in["match"]
    if match is not None and "definition" in match and expect["fallbackReason"] != "integrity":
        check("fixture %s: the hash is the canonical hash of its definition" % case["name"], match["hash"] == definition_hash(match["definition"]))
    sid = session()
    rc, answer, out, err = start(answer_in, session_id=sid)
    if rc != 0:
        check(case["name"], False, (rc, err))
        continue
    good = answer["definitionSource"] == expect["definitionSource"] and answer["action"] == "run"
    notice = answer["notice"]
    reason = expect["fallbackReason"]
    if reason is None:
        good = good and notice == "Using your organization's workflow %s (version %s)." % (match["name"], match["version"])
        good = good and answer["workflow"] == {"id": match["workflowId"], "name": match["name"], "version": match["version"], "hash": match["hash"]}
        _, status, _, _ = sid_status(sid)
        good = good and status["workflow"] == "Workflow: %s v%s (your organization's)" % (match["name"], match["version"]) and status["definitionSource"] == "organization"
        reported = [r for r in answer["reports"] if "definition" in r]
        good = good and reported and definition_hash(reported[0]["definition"]) == match["hash"]
    elif reason == "no-match":
        good = good and notice is None
    else:
        good = good and isinstance(notice, str) and notice.startswith(NOTICE_START[reason]) and "\n" not in notice
        if reason == "unrunnable":
            good = good and notice.endswith("); running the built-in workflow.") and len(notice) > len(NOTICE_START[reason]) + 40
    state = json.load(open(os.path.join(WORK, "cache/devstride-plugin/workflows", "%s.%s.json" % (sid, FIX["context"]["item"]))))
    good = good and state["fallbackReason"] == reason
    check("answer: %s -> %s%s" % (case["name"], expect["definitionSource"], "" if reason is None else " (%s)" % reason), good, (answer.get("notice"), state.get("fallbackReason")))

# deliberately invalid definitions fail validation with the named code when started directly
for case in FIX["answers"]:
    code = case["expect"]["invalidCode"]
    if code:
        rc, _, _, err = start(definition=case["answer"]["match"]["definition"])
        check("started directly, %s is refused as %s" % (case["name"], code), rc == 2 and err.startswith("workflow: %s:" % code), err)

# --- pinning ------------------------------------------------------------------------------------
print("pinning")
org = [c for c in FIX["answers"] if c["expect"]["fallbackReason"] is None][0]["answer"]
sid = session()
rc, first, _, _ = start(org, session_id=sid)
rc2, again, _, _ = start({"match": None}, session_id=sid)
check("a second start with a different answer keeps the pinned organization definition, with no new notice",
      rc2 == 0 and again["definitionSource"] == "organization" and again["notice"] is None and again["workflow"] == first["workflow"]
      and again["runId"] == first["runId"], (rc2, again and again.get("definitionSource")))
for command in ("next", "status", "resume"):
    rc, answer, _, err = run(command, {"session": sid, "item": FIX["context"]["item"], "fetched": {"match": None}})
    pinned = rc == 0 and answer["runId"] == first["runId"]
    if command == "status":
        pinned = pinned and answer["definitionSource"] == "organization"
    else:
        pinned = pinned and answer["step"]["id"] == first["step"]["id"]
    check("%s ignores a fetched member and reads the pinned copy" % command, pinned, (rc, err))
run("done", {"session": sid, "item": FIX["context"]["item"], "stepId": first["step"]["id"], "attempt": 1,
             "output": "STEP: PASS", "fetched": {"match": None}})
rc, after, _, err = sid_status(sid)
check("done ignores a fetched member: the run keeps its pinned organization definition",
      rc == 0 and after["definitionSource"] == "organization" and after["runId"] == first["runId"], (rc, err))
sid = session()
start(None, session_id=sid)
rc, again, _, err = start(org, session_id=sid)
check("a built-in run under way is not re-pinned by a later organization answer", rc == 0 and again["definitionSource"] == "builtin" and again["notice"] is None, (rc, err))

# --- repository identity ------------------------------------------------------------------------
print("repository")
os.makedirs(os.path.join(WORK, "plain"))
rc, answer, _, _ = run("repository", cwd=os.path.join(WORK, "plain"))
check("outside a git repository: null", rc == 0 and answer == {"repository": None}, answer)
repo = os.path.join(WORK, "ident")
os.makedirs(repo)
git(repo, "init", "-q")
rc, answer, _, _ = run("repository", cwd=repo)
check("a repository with no remote: null", rc == 0 and answer == {"repository": None}, answer)
for case in REAL["repository"]:
    url, name = case["remote"], case["expect"]
    if not isinstance(url, str) or "\n" in url or not url.strip():
        continue
    try:
        subprocess.run(["git", "-C", repo, "remote", "remove", "origin"], capture_output=True)
        git(repo, "remote", "add", "origin", url)
    except subprocess.CalledProcessError:
        continue
    rc, answer, out, _ = run("repository", cwd=repo)
    userinfo = url.split("//", 1)[-1].split("@", 1)[0] if "@" in url else ""
    leaked = ":" in userinfo and userinfo.split(":", 1)[1] in out
    check("remote %s -> %s" % (url if "@" not in url else "(credentialed)", name), rc == 0 and answer == {"repository": name} and not leaked, (answer, out))

# --- repository skill steps ----------------------------------------------------------------------
print("repository skill steps")


def repo_definition(ref):
    return {"schema": 1, "id": "repo-check", "version": 1, "name": "Repository check", "startsWhen": "item-picked-up", "endsBy": None,
            "appliesTo": {"workTypes": [], "tags": [], "repositories": []}, "minPluginVersion": "4.2.0",
            "phases": [{"id": "check", "name": "Check", "steps": [{"id": "check", "name": "Our check", "summary": "", "contract": "custom@1",
                        "kind": "step", "run": {"source": "repo", "ref": ref, "version": None},
                        "when": {"mode": "always", "condition": None}, "onFail": "stop"}]}]}


def fresh(name):
    path = os.path.join(WORK, name)
    os.makedirs(path)
    git(path, "init", "-q")
    return path


def commit(path, files, message="change"):
    for rel, data in files.items():
        full = os.path.join(path, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "wb") as handle:
            handle.write(data)
    git(path, "add", "-A")
    git(path, "commit", "-q", "-m", message)
    return git(path, "rev-parse", "HEAD").decode().strip()


MARKER = os.path.join(WORK, "marker-made")
TEXT = ("# Our check\n\nRun the check and answer STEP: PASS.\n\n```bash\ntouch %s\n```\n" % MARKER).encode()
repo = fresh("skills-repo")
head = commit(repo, {"docs/agents/check.md": TEXT, "README.md": b"x\n"})
sid = session()
rc, answer, out, err = start(definition=repo_definition("./docs/agents/check.md"), session_id=sid, cwd=repo, context=dict(FIX["context"], cwd=repo))
ins = (answer or {}).get("instructions") or {}
check("a committed file runs: its text, the HEAD commit and the sha256 of its bytes", rc == 0 and answer["action"] == "run" and answer["skill"] is None
      and ins.get("text") == TEXT.decode() and ins.get("version") == head and ins.get("hash") == hashlib.sha256(TEXT).hexdigest()
      and ins.get("ref") == "docs/agents/check.md", (rc, err, ins.get("version")))
ran = [r for rep in (answer or {}).get("reports", []) for r in rep.get("reports", []) if r.get("ran")]
check("... the step report names source, path, commit and hash, never the text", ran and ran[0]["ran"] == {
    "source": "repo", "ref": "docs/agents/check.md", "version": head, "hash": hashlib.sha256(TEXT).hexdigest()}
      and out.count("Run the check and answer") == 1, ran)
check("... and the runner never executes the file", not os.path.exists(MARKER))
with open(os.path.join(repo, "docs/agents/check.md"), "wb") as handle:
    handle.write(b"# Uncommitted edit\n")
rc, answer, _, _ = run("next", {"session": sid, "item": FIX["context"]["item"]}, cwd=repo)
check("an uncommitted edit is not what runs (the committed text is)", rc == 0 and answer["instructions"]["text"] == TEXT.decode())
rc, answer, _, err = run("done", {"session": sid, "item": FIX["context"]["item"], "stepId": "check", "attempt": 1, "output": "STEP: PASS\nchecked"}, cwd=repo)
check("its answer is checked against the step's contract like any step", rc == 0 and answer["action"] == "finished", (rc, err))
NEW = b"# Our check, second version\n"
head2 = commit(repo, {"docs/agents/check.md": NEW})
rc, answer, _, _ = start(definition=repo_definition("docs/agents/check.md"), cwd=repo, context=dict(FIX["context"], cwd=repo))
check("a new commit changes version and hash on the next attempt", rc == 0 and answer["instructions"]["version"] == head2
      and answer["instructions"]["hash"] == hashlib.sha256(NEW).hexdigest())

os.symlink(os.path.join(repo, "docs"), os.path.join(repo, "linked"))
os.symlink("check.md", os.path.join(repo, "docs/agents/link.md"))
sub = fresh("sub-source")
commit(sub, {"a.md": b"sub\n"})
subprocess.run(["git", "-C", repo, "-c", "protocol.file.allow=always", "submodule", "add", "-q", sub, "mod.md"], capture_output=True, check=True)
commit(repo, {"big-ok.md": b"a" * 65536, "big.md": b"a" * 65537, "latin.md": b"caf\xe9\n", "nul.md": b"a\x00b\n"}, "fixtures")
CASES = [
    ("missing", "docs/agents/none.md"), ("unsafe-path", "/etc/check.md"), ("unsafe-path", "docs/../check.md"),
    ("unsafe-path", "docs\\agents\\check.md"), ("unsafe-path", "docs/agents/check.txt"), ("unsafe-path", "a" * 198 + ".md"),
    ("symlink", "docs/agents/link.md"), ("missing", "linked/agents/check.md"), ("symlink", "mod.md"),
    ("too-large", "big.md"), ("not-text", "latin.md"), ("not-text", "nul.md"),
]
for code, ref in CASES:
    sid = session()
    rc, answer, out, err = start(definition=repo_definition(ref), session_id=sid, cwd=repo, context=dict(FIX["context"], cwd=repo))
    _, status, _, _ = sid_status(sid, cwd=repo)
    row = (status or {}).get("rows", [{}])[0]
    check("%s: %s, a failed attempt with the fixed verdict and the stopped answer" % (code, ref[:40]),
          rc == 0 and answer["action"] == "stopped" and answer["reason"].startswith("The skill file ") and "\n" not in answer["reason"]
          and row.get("verdict") == "STEP: FAIL repository skill file %s" % code and row.get("status") == "failed", (rc, err, answer, row.get("verdict")))
rc, answer, _, _ = start(definition=repo_definition("big-ok.md"), cwd=repo, context=dict(FIX["context"], cwd=repo))
check("too-large: 65536 bytes is accepted", rc == 0 and answer["action"] == "run" and len(answer["instructions"]["text"]) == 65536)

sid = session()
rc, answer, _, _ = start(definition=repo_definition("docs/agents/later.md"), session_id=sid, cwd=repo, context=dict(FIX["context"], cwd=repo))
commit(repo, {"docs/agents/later.md": b"# Later\n"})
rc, answer, _, err = run("resume", {"session": sid, "item": FIX["context"]["item"], "cwd": repo}, cwd=repo)
check("after fixing and committing the file, resume runs it", rc == 0 and answer["action"] == "run" and answer["instructions"]["text"] == "# Later\n"
      and answer["step"]["attempt"] == 2, (rc, err, answer))

plain = os.path.join(WORK, "plain")
rc, answer, _, err = start(definition=repo_definition("check.md"), cwd=plain, context=dict(FIX["context"], cwd=plain))
check("no-repository: outside git the step fails with the fixed verdict", rc == 0 and answer["action"] == "stopped" and "not a git repository" in answer["reason"], (rc, err, answer))
check("no case ever executed the file", not os.path.exists(MARKER))

print("%d checks" % count[0])
sys.exit(failed[0])
PY
