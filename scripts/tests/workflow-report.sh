#!/bin/bash
# Tests for skills/build-item/scripts/workflow_report.py — the helper that shapes what the build loop
# reports about its workflow: the canonical form and hash the platform must agree with (shared
# vectors), the cleaning and caps, the repository name, the per-run state, and that nothing it does
# can stop or speak over the loop. No network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/skills/build-item/scripts/workflow_report.py"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
T="$(mktemp -d)"; trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT

# The cases write to a file: a here-document inside $( ) breaks on an apostrophe under bash 3.2.
python3 - "$ROOT" "$T" > "$T/cases.out" <<'PY'
import hashlib, importlib.util, json, os, stat, subprocess, sys
root, tmp = sys.argv[1], sys.argv[2]
helper = os.path.join(root, "skills", "build-item", "scripts", "workflow_report.py")

def check(name, got, want=True):
    print(("ok   " if got == want else "FAIL ") + name + ("" if got == want else " — got %r, want %r" % (got, want)))

def load():
    spec = importlib.util.spec_from_file_location("workflow_report", helper)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

BASE = {k: v for k, v in os.environ.items() if k not in (
    "CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID", "DEVSTRIDE_WORKFLOWS", "DEVSTRIDE_WORKFLOW_STATE_DIR")}
BASE["GIT_CEILING_DIRECTORIES"] = tmp  # a scratch folder inside someone's checkout is still not a repository
ROOT_USER = hasattr(os, "geteuid") and os.geteuid() == 0  # a read-only folder does not stop root

def run(command, body=None, env=None, cwd=None, args=()):
    """One command-line call: (exit code, parsed stdout or raw text, stderr)."""
    full = dict(BASE); full.update(env or {})
    done = subprocess.run([sys.executable, helper, command] + list(args), capture_output=True, text=True, env=full, cwd=cwd or tmp,
                          input=body if isinstance(body, str) or body is None else json.dumps(body))
    try:
        parsed = json.loads(done.stdout)
    except ValueError:
        parsed = done.stdout
    return done.returncode, parsed, done.stderr

# (0) the import surface: a module first; importing runs nothing and writes nothing
empty = os.path.join(tmp, "import-state"); os.makedirs(empty)
os.environ["DEVSTRIDE_WORKFLOW_STATE_DIR"] = empty
w = load()
names = ["canonical_json", "definition_hash", "normalize_repository", "clean_verdict", "clean_evidence", "clean_links", "build_report_arguments"]
check("(0a) the seven functions are importable by file path", [n for n in names if not callable(getattr(w, n, None))], [])
report = {"step": "build", "status": "done", "verdict": "Built", "attempt": 3}
one = w.build_report_arguments("run-00000001", "s-1", [report], item_number="I101", now="2026-01-02T03:04:05.000Z")
two = w.build_report_arguments("run-00000001", "s-1", [report], item_number="I101", now="2026-01-02T03:04:05.000Z")
check("(0b) the same input gives the same output (no hidden counter)", one, two)
check("(0c) the definition is included only when passed", ("definition" in one, "definition" in w.build_report_arguments("run-00000001", "s-1", [report], definition={"a": 1})), (False, True))
check("(0d) a report keeps its own attempt", one["reports"][0]["attempt"], 3)
check("(0e) importing and calling created nothing in the state directory", os.listdir(empty), [])
del os.environ["DEVSTRIDE_WORKFLOW_STATE_DIR"]
readonly = os.path.join(tmp, "readonly-tmp"); os.makedirs(readonly); os.chmod(readonly, 0o500)
saved = os.environ.get("TMPDIR"); os.environ["TMPDIR"] = readonly
again = load()
check("(0f) with the state directory unset and the temp directory read-only, importing still works and writes nothing",
      (again.definition_hash({}), os.listdir(readonly)), ("44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a", []))
check("(0h) the default state folder is named for the user, so a shared temp directory is not shared state",
      os.path.basename(again._state_dir({})), "devstride-workflows-%s" % os.getuid())
if saved is None: del os.environ["TMPDIR"]
else: os.environ["TMPDIR"] = saved
for bad_call, label in ((lambda: w.build_report_arguments("r", "s", [report] * 5), "five reports"),
                        (lambda: w.build_report_arguments("r", "s", [{"step": "build", "status": "paused"}]), "an unknown status")):
    try:
        bad_call(); check("(0g) %s raise ValueError" % label, "no error", "ValueError")
    except ValueError:
        check("(0g) %s raise ValueError" % label, True)

# (1) the shared canonical-JSON vectors: the same file the platform's own test reads
vectors = json.load(open(os.path.join(root, "scripts", "tests", "fixtures", "canonical-json-vectors.json"), encoding="utf-8"))["vectors"]
WANT = ["44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a", "49eaef5002f9752ec6c880c0aa9af03132dd2217ab365978334592600c999d92",
        "adfccf44948a24c6814610ef8e26713e0a4fc10a3fdadcddfd0e5b54684ebfe1", "eb500a4543290220b167a7b8df1fe111bbe28acfb698d9dd2904cb486bf0f7c0",
        "90bb93fb12938503fb8b41196f0359c938923868d51f24015ff2c4f564594048", "b6348bfd7a385552ebb887798bba67c54243e4e939821a72416f1a3b9f25e86e",
        "2a001225d7eed8f79b66837460e43bbe206fa43cb9f7124bb601ac4dd4e4c3b9"]
check("(1a) the file holds the seven vectors with the agreed hashes", [v["sha256"] for v in vectors], WANT)
for index, vector in enumerate(vectors):
    path = os.path.join(tmp, "vector-%d.json" % index)
    json.dump(vector["input"], open(path, "w", encoding="utf-8"), ensure_ascii=False)
    rc, out, _ = run("definition", args=["--file", path, "--canonical"])
    check("(1b) vector %d (%s): definition_hash and `definition --file` agree" % (index + 1, vector["name"]),
          (w.definition_hash(vector["input"]), rc, out.get("hash") if isinstance(out, dict) else out), (vector["sha256"], 0, vector["sha256"]))
    if "canonical" in vector:
        check("(1c) vector %d canonical text" % (index + 1), (w.canonical_json(vector["input"]).decode("utf-8"), out.get("canonical")), (vector["canonical"], vector["canonical"]))
check("(1d) the second vector's canonical text", w.canonical_json({"b": 1, "a": {"d": 2, "c": [3, 2, 1]}}), b'{"a":{"c":[3,2,1],"d":2},"b":1}')
for value, label in ((1.5, "a float"), (float("nan"), "NaN"), (2 ** 53, "2^53")):
    try:
        w.canonical_json({"n": [value]}); check("(1e) %s is refused" % label, "accepted", "ValueError")
    except ValueError:
        check("(1e) %s is refused" % label, True)
check("(1f) the largest safe integer is accepted", w.canonical_json({"n": 2 ** 53 - 1}), b'{"n":9007199254740991}')

# (2) `definition` on the shipped file agrees with an independent hash
build = json.load(open(os.path.join(root, "workflows", "build.json"), encoding="utf-8"))
independent = hashlib.sha256(json.dumps(build, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")).hexdigest()
rc, out, _ = run("definition")
check("(2) definition prints id build, version 2 and the independently computed hash", (rc, out.get("id"), out.get("version"), out.get("hash"), "canonical" in out), (0, "build", 2, independent, False))

# (3) the verdict
check("(3a) a two-line verdict keeps the first line", w.clean_verdict("Merged cleanly\nand more detail"), "Merged cleanly")
check("(3b) control characters become spaces, white space collapses", w.clean_verdict("a\tb\x07  c\x7f"), "a b c")
long = w.clean_verdict("x" * 300)
check("(3c) 300 characters are cut to 200 ending in …", (len(long), long[-1]), (200, "…"))
check("(3d) an empty verdict is an empty string, and a running report then carries none", (w.clean_verdict(""), w.clean_verdict(None),
      "verdict" in w.build_report_arguments("r", "s", [{"step": "build", "status": "running", "verdict": ""}])["reports"][0]), ("", "", False))
check("(3e) a finished report with no verdict still carries one", w.build_report_arguments("r", "s", [{"step": "build", "status": "done"}])["reports"][0]["verdict"], "Done")

# (4) the evidence
fifty = w.clean_evidence(["line %d" % n for n in range(50)])
check("(4a) 50 lines keep 40 and end with the dropped line", (len(fifty), fifty[-1], fifty[0]), (40, "… more evidence not sent", "line 0"))
check("(4b) a 10 KB line is cut within 1000 characters", len(w.clean_evidence(["y" * 10240])[0]), 1000)
wide = w.clean_evidence(["日本語" * 300] * 30)
check("(4c) total bytes never pass 8,192 with multi-byte text", (sum(len(l.encode("utf-8")) for l in wide) <= 8192, wide[-1]), (True, "… more evidence not sent"))
check("(4d) lines are cleaned like the verdict; empty ones go", w.clean_evidence(["a\nb", "", "  ", "c\x01d", 7]), ["a b", "c d"])
check("(4e) a few short lines pass untouched", w.clean_evidence(["12 passed", "0 failed"]), ["12 passed", "0 failed"])

# (5) the links
links = w.clean_links({"pullRequest": "https://example.com/pull/42", "commit": "javascript:alert(1)", "comment": "ftp://example.com/x",
                       "branch": "feature/x\n" + "b" * 400, "other": "https://example.com"})
check("(5a) only web addresses and the branch survive", (sorted(links), links["pullRequest"], len(links["branch"])), (["branch", "pullRequest"], "https://example.com/pull/42", 300))
check("(5b) an address with a password or over 500 characters is dropped", w.clean_links({"commit": "https://user:token@example.com/c/1", "comment": "https://example.com/" + "c" * 500}), {})

# (6) the repository name
TABLE = [("https://example.com/owner/name.git", "example.com/owner/name"), ("https://user:token@example.com/owner/name", "example.com/owner/name"),
         ("git@example.com:owner/name.git", "example.com/owner/name"), ("ssh://git@example.com:22/owner/name", "example.com/owner/name"),
         ("https://example.com/group/sub/name", "example.com/group/sub/name"), ("https://EXAMPLE.com/Owner/Name", "example.com/owner/name"),
         ("https://example.com/a/b/c/d/name", "example.com/a/b/c/d/name"), ("https://example.com/owner/name/", "example.com/owner/name")]
check("(6a) eight remote forms normalize to host/owner/name", [w.normalize_repository(u) for u, _ in TABLE], [want for _, want in TABLE])
check("(6b) a local path, a file address, two segments and a segment with a space give none",
      [w.normalize_repository(u) for u in ("/srv/git/name.git", "file:///srv/git/owner/name", "https://example.com/name", "https://example.com/own er/name", "", None)], [None] * 6)
plain = os.path.join(tmp, "plain"); os.makedirs(plain)
check("(6c) a directory that is not a git repository gives null", run("repository", args=["--dir", plain])[1], {"repository": None})
repo = os.path.join(tmp, "repo"); subprocess.run(["git", "init", "-q", repo], check=True)
subprocess.run(["git", "-C", repo, "remote", "add", "origin", "https://someone:s3cr3t-token@example.com/owner/name.git"], check=True)
rc, out, err = run("repository", args=["--dir", repo])
check("(6d) a remote carrying a user and token prints neither", (out, "someone" in json.dumps(out) + err, "s3cr3t" in json.dumps(out) + err), ({"repository": "example.com/owner/name"}, False, False))

# (7) payload: the gate, the route and the arguments
state = os.path.join(tmp, "state"); os.makedirs(state)
ENV = {"CLAUDE_CODE_SESSION_ID": "session-one", "DEVSTRIDE_WORKFLOW_STATE_DIR": state}
first = {"config": {}, "item": "I101", "now": "2026-01-02T03:04:05.000Z",
         "reports": [{"step": "claim", "status": "done", "verdict": "I101 — claim won", "evidence": ["ready set: 3"]}]}
check("(7a) no session id skips with no-session", run("payload", first, {"DEVSTRIDE_WORKFLOW_STATE_DIR": state})[1], {"skip": "no-session"})
check("(7b) config null skips with off", run("payload", dict(first, config=None), ENV)[1], {"skip": "off"})
check("(7c) DEVSTRIDE_WORKFLOWS of 0, false, OFF and ' no ' skips with off whatever the config says",
      [run("payload", first, dict(ENV, DEVSTRIDE_WORKFLOWS=word))[1] for word in ("0", "false", "OFF", " no ")], [{"skip": "off"}] * 4)
check("(7d) five reports skip with too-many-reports", run("payload", dict(first, reports=first["reports"] * 5), ENV)[1], {"skip": "too-many-reports"})
check("(7e) nothing above wrote any state", os.listdir(state), [])
rc, out, err = run("payload", first, dict(ENV, DEVSTRIDE_WORKFLOWS="1"), cwd=repo)
args = out["call"]["arguments"] if isinstance(out, dict) and "call" in out else {}
rep = (args.get("reports") or [{}])[0]
check("(7f) config {} reports through the provider, on by default, with the variable set to 1", (rc, out.get("via"), out["call"]["tool"], err), (0, "provider", "record_workflow_step", ""))
check("(7g) the arguments carry the run, session, item, repository and the full definition",
      (len(args.get("runId", "")) >= 8, args.get("sessionId"), args.get("itemNumber"), args.get("repository"), args.get("definition") == build),
      (True, "session-one", "I101", "example.com/owner/name", True))
check("(7h) the report carries stepId, attempt 1, start, end and what ran",
      (rep.get("stepId"), rep.get("attempt"), rep.get("startedAt"), rep.get("endedAt"), rep.get("ran", {}).get("source"), rep.get("ran", {}).get("ref"), rep.get("verdict"), rep.get("evidence")),
      ("claim", 1, "2026-01-02T03:04:05.000Z", "2026-01-02T03:04:05.000Z", "builtin", "claim-story", "I101 — claim won", ["ready set: 3"]))
check("(7i) what ran names this plugin's version", rep.get("ran", {}).get("version"), json.load(open(os.path.join(root, ".claude-plugin", "plugin.json")))["version"])
check("(7j) a block naming commands.report reports through commands", run("payload", dict(first, item="I102", config={"commands": {"report": "./report"}}), ENV)[1].get("via"), "commands")
check("(7k) a provider block reports through the provider", run("payload", dict(first, item="I103", config={"provider": "devstride"}), ENV)[1].get("via"), "provider")
codex = run("payload", dict(first, item="I104"), {"CODEX_THREAD_ID": "thread-9", "DEVSTRIDE_WORKFLOW_STATE_DIR": state})[1]
check("(7l) a Codex thread id is used when there is no Claude Code session id", codex["call"]["arguments"]["sessionId"], "thread-9")
check("(7m) a step the definition does not have is skipped with a reason", run("payload", dict(first, reports=[{"step": "deploy", "status": "done"}]), ENV)[1], {"skip": "unknown-step"})

# (8) the definition travels once, returns when asked for, and always when nothing can be remembered
def has_definition(item, env=ENV, step="claim"):
    out = run("payload", {"config": {}, "item": item, "reports": [{"step": step, "status": "done", "verdict": "won"}]}, env)[1]
    return "definition" in out["call"]["arguments"]
check("(8a) before any answer the next payload still carries the definition", has_definition("I101"), True)
check("(8b) a normal answer is acknowledged", run("outcome", {"item": "I101", "answer": {"run": {"runId": "x"}}}, ENV)[1], {"action": "continue"})
check("(8c) after it the definition is left out", has_definition("I101"), False)
run("outcome", {"item": "I101", "answer": {"outcome": "DEFINITION_REQUIRED"}}, ENV)
check("(8d) a DEFINITION_REQUIRED answer brings it back, and the run stays available", has_definition("I101"), True)
locked = os.path.join(tmp, "locked"); os.makedirs(locked); os.chmod(locked, 0o500)
LOCKED = {"CLAUDE_CODE_SESSION_ID": "session-one", "DEVSTRIDE_WORKFLOW_STATE_DIR": os.path.join(locked, "nested")}
rc1, out1, err1 = run("payload", first, LOCKED); run("outcome", {"item": "I101", "answer": {"run": {}}}, LOCKED); rc2, out2, err2 = run("payload", first, LOCKED)
if ROOT_USER:
    print("ok   (8e) skipped as root: a read-only folder does not stop root from writing")
else:
    check("(8e) with the state directory unwritable the definition is sent every time, the run keeps one id, the output says the state was not kept, and nothing fails",
          (rc1, rc2, "definition" in out1["call"]["arguments"], "definition" in out2["call"]["arguments"], err1 + err2, out1["call"]["arguments"]["runId"] == out2["call"]["arguments"]["runId"], out1.get("stateKept"), out2.get("stateKept")),
          (0, 0, True, True, "", True, False, False))
check("(8f) when the state is kept the output does not mention it", "stateKept" in run("payload", dict(first, item="I106"), ENV)[1], False)

# (9) attempts and remembered starts
def send(item, step, status, now, env=ENV, **extra):
    body = {"config": {}, "item": item, "now": now, "reports": [dict({"step": step, "status": status, "verdict": "v"}, **extra)]}
    return run("payload", body, env)[1]["call"]["arguments"]["reports"][0]
a = send("I105", "build", "running", "2026-01-02T03:00:00.000Z")
b = send("I105", "build", "done", "2026-01-02T03:30:00.000Z")
c = send("I105", "build", "running", "2026-01-02T04:00:00.000Z")
check("(9a) running, done, then running again is attempt 2", (a["attempt"], b["attempt"], c["attempt"]), (1, 1, 2))
check("(9b) the finished report's start is the remembered one, its end is now", (b["startedAt"], b["endedAt"], "endedAt" in a), ("2026-01-02T03:00:00.000Z", "2026-01-02T03:30:00.000Z", False))
check("(9c) the new attempt starts afresh", c["startedAt"], "2026-01-02T04:00:00.000Z")
check("(9d) a finished report sent twice keeps its attempt", send("I105", "branch", "done", "2026-01-02T03:00:00.000Z")["attempt"] + send("I105", "branch", "done", "2026-01-02T03:01:00.000Z")["attempt"], 2)

# (10) outcome: silent, and the first answer of a run is the answer the run lives by
for kind, item in (("ABSENT", "I201"), ("FORBIDDEN", "I202"), ("UNREACHABLE", "I203"), ("ERROR", "I204")):
    run("payload", dict(first, item=item), ENV)
    done = subprocess.run([sys.executable, helper, "outcome"], capture_output=True, text=True, env=dict(BASE, **ENV), input=json.dumps({"item": item, "answer": {"error": kind}}))
    check("(10a) %s prints exactly the continue action and nothing else" % kind, (done.returncode, done.stdout, done.stderr), (0, '{"action": "continue"}\n', ""))
    check("(10b) after %s the run's next payload skips with unavailable" % kind, run("payload", dict(first, item=item), ENV)[1], {"skip": "unavailable"})
check("(10c) a different run (another item) tries once again", "call" in run("payload", dict(first, item="I205"), ENV)[1], True)
run("outcome", {"item": "I205", "answer": {"run": {}, "reports": []}}, ENV)
check("(10d) a normal answer marks the run available and later payloads proceed", "call" in run("payload", dict(first, item="I205"), ENV)[1], True)
run("outcome", {"item": "I205", "answer": {"outcome": "DEFINITION_REQUIRED"}}, ENV)
check("(10e) DEFINITION_REQUIRED after a normal answer does not mark the run unavailable", "call" in run("payload", dict(first, item="I205"), ENV)[1], True)

# (11) the run id
def run_id(item, session="session-one"):
    return run("payload", dict(first, item=item), {"CLAUDE_CODE_SESSION_ID": session, "DEVSTRIDE_WORKFLOW_STATE_DIR": state})[1]["call"]["arguments"]["runId"]
check("(11a) the same session and item keep one run id", run_id("I301"), run_id("I301"))
check("(11b) another item, and another session, get another", len({run_id("I301"), run_id("I302"), run_id("I301", "session-two")}), 3)
closing = run("payload", {"config": {}, "item": "I303", "now": "2026-01-02T05:00:00.000Z", "reports": [{"step": "sync", "status": "done", "verdict": "Synced"}], "run": {"outcome": "completed"}}, ENV)[1]["call"]["arguments"]
check("(11c) closing a run sends its outcome and end", closing["run"], {"outcome": "completed", "endedAt": "2026-01-02T05:00:00.000Z"})
check("(11d) the same item picked up again later is a new run", run_id("I303") != closing["runId"], True)
early = run("payload", {"config": {}, "item": "I304", "now": "2026-01-02T05:00:00.000Z", "reports": [{"step": "propose", "status": "done", "verdict": "Dry run"}], "run": {"outcome": "ended-early"}}, ENV)[1]["call"]["arguments"]
check("(11e) a run that ends early by design closes as ended-early", early["run"]["outcome"], "ended-early")
asked = w.build_report_arguments("r", "s", [{"step": "build", "status": "waiting", "verdict": "which format?", "waitingOn": "person"},
                                             {"step": "deploy", "status": "waiting", "verdict": "Waiting for the dev deploy"},
                                             {"step": "land", "status": "done", "verdict": "Landed", "waitingOn": "person"},
                                             {"step": "queue", "status": "waiting", "verdict": "queued", "waitingOn": "machine"}])["reports"]
check("(11f) only a waiting step asked of a person carries waitingOn", [r.get("waitingOn") for r in asked], ["person", None, None, None])

# (12) usage and bad input: exit 2, one line, no traceback
for label, command, body, args in (("invalid JSON on stdin", "payload", "{not json", ()), ("an unknown command", "explode", None, ()),
                                   ("a report with no step", "payload", {"config": {}, "reports": [{"status": "done"}]}, ()),
                                   ("an unknown status", "payload", {"config": {}, "item": "I401", "reports": [{"step": "build", "status": "paused"}]}, ()),
                                   ("a bad flag", "definition", None, ("--nope",))):
    rc, out, err = run(command, body, ENV, args=args)
    check("(12a) %s exits 2 with one workflow-report: line and no traceback" % label, (rc, out, err.startswith("workflow-report: "), err.count("\n"), "Traceback" in err), (2, "", True, 1, False))
check("(12b) a normal run exits 0", run("payload", dict(first, item="I402"), ENV)[0], 0)

# (13) the state file
files = sorted(os.listdir(state))
check("(13a) state files sit under the state directory, named by 16 hex characters", [f for f in files if not (len(f) == 21 and f.endswith(".json") and all(c in "0123456789abcdef" for c in f[:16]))], [])
check("(13b) every state file is mode 0600", {stat.S_IMODE(os.stat(os.path.join(state, f)).st_mode) for f in files}, {0o600})
check("(13c) no file name contains any part of a session id", [f for f in files if "session" in f or "thread" in f], [])
fresh = os.path.join(tmp, "fresh-state")
run("payload", first, {"CLAUDE_CODE_SESSION_ID": "s", "DEVSTRIDE_WORKFLOW_STATE_DIR": fresh})
check("(13d) a state directory the helper creates is mode 0700", stat.S_IMODE(os.stat(fresh).st_mode), 0o700)

# (16) answers a command or a tool may give
def after(item, answer, config=None):
    """Send a first report, hand back `answer`, and say what the next payload does."""
    cfg = {"commands": {"report": "./report"}} if config is None else config
    run("payload", dict(first, item=item, config=cfg), ENV)
    run("outcome", {"item": item, "answer": answer}, ENV)
    nxt = run("payload", {"config": cfg, "item": item, "reports": [{"step": "claim", "status": "done", "verdict": "won"}]}, ENV)[1]
    return "skip:" + nxt["skip"] if "skip" in nxt else ("sent+definition" if "definition" in nxt["call"]["arguments"] else "sent")
check("(16a) a command's OK, OK with the stored run after it, an empty object and a tool's content list all count as success",
      [after("I501", "OK"), after("I502", "OK\n{\"run\": {}}"), after("I503", {}), after("I504", [{"type": "text", "text": "ok"}])], ["sent"] * 4)
check("(16b) a command's other first lines, and no answer at all, switch the run off",
      [after("I505", "UNREACHABLE"), after("I506", "ERROR\nboom"), after("I507", None), after("I508", "")], ["skip:unavailable"] * 4)

# (17) a run that could not report can still be closed, and the next pickup of the item tries again
run("payload", dict(first, item="I510"), ENV); run("outcome", {"item": "I510", "answer": {"error": "UNREACHABLE"}}, ENV)
closing_skip = run("payload", {"config": {}, "item": "I510", "reports": [{"step": "sync", "status": "failed", "verdict": "stopped"}], "run": {"outcome": "interrupted"}}, ENV)[1]
check("(17) closing an unavailable run sends nothing, and the item's next run gets its own first attempt",
      (closing_skip, "call" in run("payload", dict(first, item="I510"), ENV)[1]), ({"skip": "unavailable"}, True))

# (18) a run id is never reused once its state is gone
before_id = run_id("I511")
import hashlib as _h
os.remove(os.path.join(state, _h.sha256(b"session-one|I511").hexdigest()[:16] + ".json"))
check("(18) with its state file gone, the same session and item start a run with a new id", run_id("I511") != before_id, True)

# (19) a state file is data: wrong types are dropped, never a crash
def plant(item, content):
    path = os.path.join(state, _h.sha256(("session-one|%s" % item).encode()).hexdigest()[:16] + ".json")
    with open(path, "w") as handle:
        handle.write(content if isinstance(content, str) else json.dumps(content))
for index, content in enumerate(({"steps": {"build": None}}, {"nonce": 5, "steps": "x"}, {"closed": True, "nonce": None}, {"nonce": "ab", "steps": {"build": {"attempt": "2", "status": "done", "startedAt": 12}}}, "not json", "[]")):
    item = "I52%d" % index
    plant(item, content)
    rc, out, err = run("payload", {"config": {}, "item": item, "now": "2026-01-02T03:04:05.000Z", "reports": [{"step": "build", "status": "running"}]}, ENV)
    rep = out["call"]["arguments"]["reports"][0] if isinstance(out, dict) and "call" in out else {}
    check("(19) a planted state file %d is ignored where it is wrong: exit 0, one call, attempt 1, a real start time" % index,
          (rc, err, rep.get("attempt"), rep.get("startedAt")), (0, "", 1, "2026-01-02T03:04:05.000Z"))
link_target = os.path.join(tmp, "elsewhere"); os.makedirs(link_target); linked = os.path.join(tmp, "linked-state"); os.symlink(link_target, linked)
out = run("payload", first, {"CLAUDE_CODE_SESSION_ID": "s", "DEVSTRIDE_WORKFLOW_STATE_DIR": linked})[1]
check("(19b) a state folder that is a link to somewhere else is not written through", (out.get("stateKept"), os.listdir(link_target)), (False, []))

# (20) nothing to send, and too many attempts, are skips
run("payload", dict(first, item="I530"), ENV); run("outcome", {"item": "I530", "answer": {}}, ENV)
check("(20a) no report, no close and a definition already taken: nothing to send", run("payload", {"config": {}, "item": "I530", "reports": []}, ENV)[1], {"skip": "nothing-to-send"})
plant("I531", {"nonce": "ab", "available": True, "definitionReceived": True, "steps": {"build": {"attempt": 50, "status": "failed", "startedAt": "2026-01-02T03:04:05.000Z"}}})
rc, out, err = run("payload", {"config": {}, "item": "I531", "reports": [{"step": "build", "status": "running"}]}, ENV)
check("(20b) a fifty-first attempt is a quiet skip, not an error", (rc, out, err), (0, {"skip": "too-many-attempts"}, ""))

# (21) limits are counted the way the receiving side counts them, and odd input never crashes
units = lambda text: len(text.encode("utf-16-le")) // 2
check("(21a) a verdict and an evidence line full of emoji stay within 200 and 1000 as the receiver counts",
      (units(w.clean_verdict("a" * 150 + "\U0001F600" * 50)) <= 200, units(w.clean_evidence(["x" * 500 + "\U0001F600" * 600])[0]) <= 1000), (True, True))
check("(21b) three long lines and a short one all fit: nothing is dropped that need not be", len(w.clean_evidence(["x" * 2700] * 3 + ["y" * 80])), 4)
rc, out, err = run("payload", '{"config": {}, "item": "I540", "reports": [{"step": "build", "status": "done", "verdict": "half \\ud83d emoji"}]}', ENV)
check("(21c) half of an emoji in a verdict is cleaned, not a crash", (rc, err, "call" in out), (0, "", True))
odd = w.build_report_arguments("run-00000001", "s" * 250, [{"step": "build", "status": "done", "verdict": "v", "startedAt": "yesterday"}], item_number="i101", now="2026-01-02T03:04:05.000Z")
check("(21d) an item number of the wrong shape is left out, a long session id is cut, a start that is not a time is replaced",
      ("itemNumber" in odd, len(odd["sessionId"]), odd["reports"][0]["startedAt"]), (False, 200, "2026-01-02T03:04:05.000Z"))
check("(21e) links the receiver's parser refuses are dropped: a port above 65535, no host, a backslash",
      w.clean_links({"pullRequest": "https://example.com:65536/x", "commit": "https://:443/x", "comment": "https://example.com\\x/y"}), {})
check("(21f) a port and a query are kept", w.clean_links({"commit": "https://example.com:8443/c/1?x=1#y"}), {"commit": "https://example.com:8443/c/1?x=1#y"})
check("(21g) an SSH address with an absolute path is accepted; dot segments and a drive letter are refused",
      [w.normalize_repository(u) for u in ("git@example.com:/owner/name.git", "https://example.com/../name/x", "C:owner/name/x")], ["example.com/owner/name", None, None])

# (22) the closing call, a step the definition lacks, and answers that only look like success
def closing_call(item):
    return run("payload", {"config": {}, "item": item, "reports": [{"step": "sync", "status": "done", "verdict": "Synced"}], "run": {"outcome": "completed"}}, ENV)[1]["call"]["arguments"]
run("payload", dict(first, item="I550"), ENV); run("outcome", {"item": "I550", "answer": {}}, ENV)
one = closing_call("I550"); run("outcome", {"item": "I550", "answer": {"outcome": "DEFINITION_REQUIRED"}}, ENV); two = closing_call("I550")
check("(22a) a closing call answered DEFINITION_REQUIRED is sent again on the SAME run, with the definition",
      (one["runId"] == two["runId"], "definition" in one, "definition" in two, two["run"]["outcome"]), (True, False, True, "completed"))
run("outcome", {"item": "I550", "answer": {}}, ENV)
check("(22b) once the closing call is taken, the item's next pickup is a new run", run_id("I550") != two["runId"], True)
mixed = run("payload", {"config": {}, "item": "I551", "reports": [{"step": "completion", "status": "done", "verdict": "x"}, {"step": "sync", "status": "done", "verdict": "Synced"}], "run": {"outcome": "completed"}}, ENV)[1]
check("(22c) a step the definition lacks is left out; the other report and the close still go",
      ([r["stepId"] for r in mixed["call"]["arguments"]["reports"]], mixed["call"]["arguments"]["run"]["outcome"]), (["sync"], "completed"))
check("(22d) an object with an error key, even a null one, and a tool result flagged isError are failures",
      [after("I552", {"error": None}, {}), after("I553", {"isError": True, "content": []}, {})], ["skip:unavailable"] * 2)
check("(22e) workflows set to false is off, like null", run("payload", dict(first, config=False), ENV)[1], {"skip": "off"})
check("(22f) a numeric host that is not an address, and a link with half an emoji, are dropped; a real address is kept",
      w.clean_links({"commit": "http://999.999.999.999/x", "comment": "https://example.com/\ud800", "pullRequest": "http://192.0.2.7/x"}), {"pullRequest": "http://192.0.2.7/x"})
impossible = w.build_report_arguments("run-00000001", "s", [{"step": "build", "status": "done", "verdict": "v", "startedAt": "2026-99-99T99:99:99Z"}], now="2026-01-02T03:04:05.000Z")
check("(22g) a date that cannot exist is replaced", impossible["reports"][0]["startedAt"], "2026-01-02T03:04:05.000Z")
foreign = os.path.join(tmp, "foreign"); os.makedirs(foreign); via_link = os.path.join(tmp, "via-link"); os.symlink(foreign, via_link)
with open(os.path.join(foreign, _h.sha256(b"s|I101").hexdigest()[:16] + ".json"), "w") as handle:
    json.dump({"nonce": "ab", "available": False}, handle)
check("(22h) state planted behind a linked folder is not believed", "call" in run("payload", first, {"CLAUDE_CODE_SESSION_ID": "s", "DEVSTRIDE_WORKFLOW_STATE_DIR": via_link})[1], True)

# (14) no network module is imported
import re
source = open(helper, encoding="utf-8").read()
check("(14) the script imports no network module", re.findall(r"^\s*(?:import|from)\s+(socket|urllib|http|requests|ssl|ftplib|smtplib)\b", source, re.M), [])
PY
PRC=$?; OUT="$(cat "$T/cases.out")"
echo "$OUT" | sed 's/^ok   /  ok   /; s/^FAIL /  FAIL /'
echo "$OUT" | grep -q '^FAIL' && FAIL=1
[ "$PRC" -eq 0 ] || bad "(0) the Python cases crashed (exit $PRC)"
N="$(echo "$OUT" | grep -c '^ok')"
[ "$N" -ge 120 ] && ok "(15) $N cases ran" || bad "(15) only $N cases ran"

exit $FAIL
