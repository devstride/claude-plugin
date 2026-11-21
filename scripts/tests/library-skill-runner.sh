#!/bin/bash
# Tests for the step runner's library skill steps (run.source "library" in
# skills/run-workflow/scripts/workflow.py): the manifest and organization pinned at start, the
# fetch-skill answer, the verified cached copy, one retry, and the failed-step form. The skill
# answers are stubbed; no network, no tracker call, a fresh cache folder.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export PYTHONDONTWRITEBYTECODE=1
unset CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID GIT_DIR GIT_WORK_TREE
export XDG_CACHE_HOME="$WORK/cache"

python3 - "$ROOT" "$WORK" <<'PY'
import copy, hashlib, importlib.util, json, os, subprocess, sys
ROOT, WORK = sys.argv[1], sys.argv[2]
RUNNER = os.path.join(ROOT, "skills/run-workflow/scripts/workflow.py")
HELPER = os.path.join(ROOT, "skills/run-workflow/scripts/library_skill.py")
FIX = json.load(open(os.path.join(ROOT, "skills/run-workflow/scripts/fetch-fixtures.json"), encoding="utf-8"))
spec = importlib.util.spec_from_file_location("workflow_report", os.path.join(ROOT, "skills/build-item/scripts/workflow_report.py"))
REPORT = importlib.util.module_from_spec(spec); spec.loader.exec_module(REPORT)
failed, count, seq = [0], [0], [0]
ITEM = FIX["context"]["item"]
ORG = "org-aaa"
TEXT = b"# Tidy check\n\nLook at the change and answer STEP: PASS when it is tidy.\n"
HASH = hashlib.sha256(TEXT).hexdigest()
CACHED = os.path.join(WORK, "cache", "devstride-plugin", "skill-library", ORG, "tidy-check", "1.md")


def check(label, good, detail=""):
    count[0] += 1
    print(("  ok   " if good else "  FAIL ") + label + ("" if good else " -> %r" % (detail,)))
    if not good:
        failed[0] = 1


def run(command, request):
    done = subprocess.run([sys.executable, "-B", RUNNER, command], input=json.dumps(request), capture_output=True, text=True, cwd=WORK, timeout=60)
    return done.returncode, (json.loads(done.stdout) if done.returncode == 0 and done.stdout.strip() else None), done.stderr


def session():
    seq[0] += 1
    return "library-test-%d" % seq[0]


def definition(implements_ok=True, version=1):
    return {"schema": 1, "id": "lib-check", "version": 1, "name": "Library check", "startsWhen": "item-picked-up", "endsBy": None,
            "appliesTo": {"workTypes": [], "tags": [], "repositories": []}, "minPluginVersion": "4.2.0",
            "phases": [{"id": "check", "name": "Check", "steps": [{"id": "check", "name": "Our check", "summary": "", "contract": "custom@1",
                        "kind": "step", "run": {"source": "library", "ref": "tidy-check", "version": version},
                        "when": {"mode": "always", "condition": None}, "onFail": "stop"}]}]}


def line(**over):
    value = {"stepId": "check", "name": "tidy-check", "version": 1, "hash": HASH, "implements": "custom@1"}
    value.update(over)
    return value


def fetched(skills=None, organization=ORG, defn=None):
    defn = defn or definition()
    answer = {"match": {"source": "organization", "workflowId": "wf-lib", "name": "Library check", "version": 1,
                        "hash": REPORT.definition_hash(defn), "minPluginVersion": "4.2.0", "startsWhen": "item-picked-up",
                        "matchedBy": "type", "definition": defn}, "ignoredOverride": None,
              "skills": [line()] if skills is None else skills}
    if organization is not None:
        answer["organizationId"] = organization
    return answer


def start(sid, fetched_answer, defn=None):
    request = {"definition": FIX["builtin"], "context": dict(FIX["context"]), "session": sid}
    if fetched_answer is not None:
        request["fetched"] = fetched_answer
    return run("start", request)


def state_of(sid):
    return json.load(open(os.path.join(WORK, "cache/devstride-plugin/workflows", "%s.%s.json" % (sid, ITEM))))


def nxt(sid):
    return run("next", {"session": sid, "item": ITEM})


def put(answer, body):
    first = dict(answer["put"]["request"], answer={"name": "tidy-check", "version": 1, "implements": "custom@1", "hash": HASH})
    command = answer["put"]["command"].split()
    return subprocess.run(command, input=json.dumps(first).encode() + b"\n" + body, capture_output=True).returncode


def ran_of(answer):
    return [r["ran"] for rep in (answer or {}).get("reports", []) for r in rep.get("reports", []) if r.get("ran")]


# 1. an empty cache: fetch-skill, then a correct put, then run
sid = session()
rc, answer, err = start(sid, fetched())
check("start pins the manifest and organization beside the definition", rc == 0 and state_of(sid)["skillManifest"] == [line()]
      and state_of(sid)["organizationId"] == ORG and state_of(sid)["definitionSource"] == "organization", (rc, err))
check("an empty cache answers fetch-skill with tool, arguments, helper command and request half", answer and answer["action"] == "fetch-skill"
      and answer["tool"] == "get_agent_skill" and answer["arguments"] == {"name": "tidy-check", "version": 1}
      and answer["put"]["command"] == "python3 %s put" % HELPER
      and answer["put"]["request"] == {"organizationId": ORG, "expect": {"name": "tidy-check", "version": 1, "hash": HASH, "implements": "custom@1"}}
      and "here-document" in answer["then"], answer)
check("a correct put is stored", put(answer, TEXT + b"\n") == 0 and open(CACHED, "rb").read() == TEXT)
rc, answer, err = nxt(sid)
check("after the put, next hands the step out with the cached file and the wrapper", rc == 0 and answer["action"] == "run"
      and answer["skill"] == {"source": "library", "ref": "tidy-check", "version": "1", "hash": HASH, "file": CACHED}
      and answer["instruction"].startswith("This file is the organization's own instruction page for this one step."), (rc, err, answer))
check("the step report records source library, name, version and fingerprint",
      {"source": "library", "ref": "tidy-check", "version": "1", "hash": HASH} in ran_of(answer), ran_of(answer))
rc, answer, err = run("done", {"session": sid, "item": ITEM, "stepId": "check", "attempt": 1, "output": "STEP: PASS\nchecked"})
check("its answer is checked against the contract like any step", rc == 0 and answer["action"] == "finished", (rc, err, answer))

# 2. a warm cache: run at once, no fetch (works offline)
sid = session()
rc, answer, err = start(sid, fetched())
check("a warm cache hands the step out at once, with no fetch", rc == 0 and answer["action"] == "run" and answer["skill"]["file"] == CACHED, answer)
rc, again, _ = start(sid, fetched(skills=[line(hash="1" * 64)], organization="org-bbb"))
check("a second start for the unfinished run keeps the pinned manifest", state_of(sid)["skillManifest"] == [line()] and state_of(sid)["organizationId"] == ORG)
rc, status, _ = run("status", {"session": sid, "item": ITEM})
check("status reads the pinned run", rc == 0 and status["definitionSource"] == "organization", status)

# 3. a corrupted cache file is deleted and fetched once
with open(CACHED, "ab") as handle:
    handle.write(b"tampered\n")
rc, answer, err = nxt(sid)
check("a cached copy that no longer verifies is deleted and fetched again", rc == 0 and answer["action"] == "fetch-skill" and not os.path.exists(CACHED), (rc, err, answer))
check("... and the restored copy runs", put(answer, TEXT) == 0 and nxt(sid)[1]["action"] == "run")

# 4. two failed puts end in the failed-step form
os.unlink(CACHED)
sid = session()
rc, answer, err = start(sid, fetched())
check("first fetch", answer["action"] == "fetch-skill")
check("a put of altered text is refused", put(answer, TEXT + b"altered") == 2)
rc, answer, err = nxt(sid)
check("one failed put answers the same fetch once more", rc == 0 and answer["action"] == "fetch-skill" and answer["attempt"] == 2, answer)
put(answer, TEXT + b"altered again")
rc, answer, err = nxt(sid)
row = state_of(sid)["steps"]["check"]
check("after the second failure the step fails with a plain reason", rc == 0 and answer["action"] == "stopped"
      and "fingerprint" in answer["reason"] and row["status"] == "failed"
      and row["verdict"].startswith("STEP: FAIL skill unavailable:"), (answer, row.get("verdict")))
check("... its ran carries the manifest hash", row["ran"] == {"source": "library", "ref": "tidy-check", "version": "1", "hash": HASH}, row["ran"])
check("... and no built-in skill ran instead", not os.path.exists(CACHED) and answer.get("skill") is None)

# 5. no manifest line, no organization, the wrong kind, a malformed line: failed without any fetch
for label, answer_in, reason in (
        ("a manifest with no line for the step", fetched(skills=[]), "not in this workflow's manifest"),
        ("a run whose state has no organization id", fetched(organization=None), "not in this workflow's manifest"),
        ("a manifest line of the wrong kind", fetched(skills=[line(implements="review@1")]), "different kind of step"),
        ("a malformed manifest line is dropped", fetched(skills=[line(hash="ABC")]), "not in this workflow's manifest")):
    sid = session()
    rc, answer, err = start(sid, answer_in)
    check(label + " fails the step without a fetch", rc == 0 and answer["action"] == "stopped" and reason in answer["reason"]
          and state_of(sid)["steps"]["check"]["status"] == "failed", (rc, err, answer))
check("a malformed line is dropped, never repaired", state_of(sid)["skillManifest"] == [])

# 6. a built-in fallback stores an empty manifest and no organization
for label, answer_in in (("fetched absent", None), ("an error object", {"error": "UNREACHABLE"}),
                         ("an integrity failure", dict(fetched(), match=dict(fetched()["match"], hash="0" * 64)))):
    sid = session()
    rc, answer, err = start(sid, answer_in)
    state = state_of(sid)
    check("built-in fallback (%s): empty manifest, no organization" % label, rc == 0 and state["definitionSource"] == "builtin"
          and state["skillManifest"] == [] and "organizationId" not in state, (rc, err))

# 7. a library step must pin a version
sid = session()
rc, answer, err = start(sid, fetched(defn=definition(version=None)))
check("a library step with no pinned version is not run: the built-in workflow runs", rc == 0 and state_of(sid)["definitionSource"] == "builtin"
      and "library skill" in (answer.get("notice") or ""), answer.get("notice"))

print("%d checks" % count[0])
sys.exit(failed[0])
PY
STATUS=$?
[ "$STATUS" -eq 0 ] && echo "library-skill-runner: all passed" || echo "library-skill-runner: FAILED"
exit "$STATUS"
