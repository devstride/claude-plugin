#!/bin/bash
# Tests for skills/build-item/scripts/workflow_report.py — the shared rules for what a workflow run
# tells DevStride: the canonical form and hash the platform must agree with (shared vectors), the
# cleaning and caps, the repository name and the one off switch. It keeps no state and forwards
# nothing: the step runner sends a run's history itself. No network.
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
readonly = os.path.join(tmp, "readonly-tmp"); os.makedirs(readonly); os.chmod(readonly, 0o500)
saved = os.environ.get("TMPDIR"); os.environ["TMPDIR"] = readonly
w = load()
names = ["canonical_json", "definition_hash", "normalize_repository", "clean_verdict", "clean_evidence", "clean_links",
         "clean_text", "clip", "switched_off", "read_repository"]
check("(0a) the ten functions are importable by file path", [n for n in names if not callable(getattr(w, n, None))], [])
check("(0b) with the temp directory read-only, importing and hashing still work and write nothing",
      (w.definition_hash({}), os.listdir(readonly)), ("44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a", []))
if saved is None: del os.environ["TMPDIR"]
else: os.environ["TMPDIR"] = saved
check("(0c) it forwards nothing: no report builder, no state folder, no copy of the run endings",
      [n for n in ("build_report_arguments", "_state_dir", "RUN_OUTCOMES", "MAX_REPORTS") if hasattr(w, n)], [])

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
check("(3d) an empty verdict, a blank one and none at all are an empty string", (w.clean_verdict(""), w.clean_verdict(" \n\t"), w.clean_verdict(None)), ("", "", ""))
check("(3e) the first line that has text is the verdict", w.clean_verdict("\n\n  Built\nmore"), "Built")

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

# (7) the one off switch: null or false in the config, or the machine variable
check("(7a) the key absent, an object and an empty object are on", [w.switched_off(value, {}) for value in ({}, {"x": 1})], [False, False])
check("(7b) null and false are off", [w.switched_off(None, {}), w.switched_off(False, {})], [True, True])
check("(7c) DEVSTRIDE_WORKFLOWS of 0, false, OFF and ' no ' is off whatever the config says",
      [w.switched_off({}, {"DEVSTRIDE_WORKFLOWS": word}) for word in ("0", "false", "OFF", " no ")], [True] * 4)
check("(7d) any other value of the variable leaves the config to decide", [w.switched_off({}, {"DEVSTRIDE_WORKFLOWS": word}) for word in ("1", "yes", "")], [False] * 3)

# (8) usage and bad input: exit 2, one line, no traceback; the forwarding commands are gone
for label, command, body, args in (("an unknown command", "explode", None, ()), ("the retired payload command", "payload", {"config": {}}, ()),
                                   ("the retired outcome command", "outcome", {"answer": {}}, ()), ("a bad flag", "definition", None, ("--nope",)),
                                   ("a definition file that is not JSON", "definition", None, ("--file", helper)),
                                   ("repository with a stray argument", "repository", None, ("--dir",))):
    rc, out, err = run(command, body, args=args)
    check("(8a) %s exits 2 with one workflow-report: line and no traceback" % label, (rc, out, err.startswith("workflow-report: "), err.count("\n"), "Traceback" in err), (2, "", True, 1, False))
check("(8b) a normal call exits 0 and writes nothing to stderr", run("repository", args=["--dir", repo])[0::2], (0, ""))

# (21) limits are counted the way the receiving side counts them, and odd input never crashes
units = lambda text: len(text.encode("utf-16-le")) // 2
check("(21a) a verdict and an evidence line full of emoji stay within 200 and 1000 as the receiver counts",
      (units(w.clean_verdict("a" * 150 + "\U0001F600" * 50)) <= 200, units(w.clean_evidence(["x" * 500 + "\U0001F600" * 600])[0]) <= 1000), (True, True))
check("(21b) three long lines and a short one all fit: nothing is dropped that need not be", len(w.clean_evidence(["x" * 2700] * 3 + ["y" * 80])), 4)
check("(21c) half of an emoji in a verdict is cleaned, not a crash", w.clean_verdict("half \ud83d emoji"), "half ? emoji")
check("(21d) text is cut as the receiver counts it, half-characters gone", (w.clip("ab\U0001F600c", 3), w.clean_text("a\nb\x01" + "c" * 300, 5)), ("ab", "a b c"))
check("(21e) links the receiver's parser refuses are dropped: a port above 65535, no host, a backslash",
      w.clean_links({"pullRequest": "https://example.com:65536/x", "commit": "https://:443/x", "comment": "https://example.com\\x/y"}), {})
check("(21f) a port and a query are kept", w.clean_links({"commit": "https://example.com:8443/c/1?x=1#y"}), {"commit": "https://example.com:8443/c/1?x=1#y"})
check("(21g) an SSH address with an absolute path is accepted; dot segments and a drive letter are refused",
      [w.normalize_repository(u) for u in ("git@example.com:/owner/name.git", "https://example.com/../name/x", "C:owner/name/x")], ["example.com/owner/name", None, None])

# (22) links and repository names the receiver refuses
check("(22a) a numeric host that is not an address, and a link with half an emoji, are dropped; a real address is kept",
      w.clean_links({"commit": "http://999.999.999.999/x", "comment": "https://example.com/\ud800", "pullRequest": "http://192.0.2.7/x"}), {"pullRequest": "http://192.0.2.7/x"})

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
[ "$N" -ge 58 ] && ok "(15) $N cases ran" || bad "(15) only $N cases ran"

exit $FAIL
