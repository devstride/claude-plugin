#!/bin/bash
# Tests for the built-in workflow definitions and scripts/check-workflows.py: the shipped Build
# workflow passes, its thirteen step ids are the published ones in order, every numbered step of the
# build loop maps to a step id (so the definition and the loop cannot drift), and each rule the
# checker enforces fails a scratch copy with the right reason.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# The cases write to a file: a here-document inside $( ) breaks on an apostrophe under bash 3.2.
python3 - "$ROOT" "$T" > "$T/cases.out" <<'PY'
import copy, json, os, re, shutil, subprocess, sys
root, tmp = sys.argv[1], sys.argv[2]
checker = os.path.join(root, "scripts", "check-workflows.py")

def check(name, got, want=True):
    print(("ok   " if got == want else "FAIL ") + name + ("" if got == want else " — got %r, want %r" % (got, want)))

def run(folder=None):
    done = subprocess.run([sys.executable, checker] + (["--root", folder] if folder else []), capture_output=True, text=True)
    return done.returncode, done.stdout.strip(), done.stderr.strip()

STEPS = ["select", "claim", "start", "branch", "build", "risk-check", "review-local", "local-checks",
         "pull-request-review", "merge", "complete", "file-findings", "sync"]
build = json.load(open(os.path.join(root, "workflows", "build.json"), encoding="utf-8"))
plugin = json.load(open(os.path.join(root, ".claude-plugin", "plugin.json"), encoding="utf-8"))["version"]
ids = [step["id"] for phase in build["phases"] for step in phase["steps"]]

rc, out, err = run()
check("(1) the shipped definitions pass", (rc, out, err), (0, "WORKFLOWS: ok (1 files, 13 steps)", ""))
as_tuple = lambda v: tuple(int(p) for p in v.split("."))
check("(2) minPluginVersion is not newer than this plugin", as_tuple(build["minPluginVersion"]) <= as_tuple(plugin))
check("(3) the step ids are exactly the thirteen published ones, in order", ids, STEPS)
check("(4) every step id is unique and a lower-case slug", (len(set(ids)), [i for i in ids if not re.match(r"^[a-z][a-z0-9-]{0,63}$", i)]), (13, []))
check("(5) the phases are pick-up, build, review and land", [p["id"] for p in build["phases"]], ["pick-up", "build", "review", "land"])
conditions = {s["id"]: s["when"]["condition"] for p in build["phases"] for s in p["steps"] if s["when"]["mode"] == "condition"}
check("(6) only the two review-path steps are conditional", conditions, {"local-checks": "review-path:fast", "pull-request-review": "review-path:pull-request"})

# (7) every numbered step heading of the build loop, up to 7, maps to a step id
LOOP = {"0": ["select", "claim"], "1": ["start"], "2": ["branch"], "3": ["build", "risk-check"], "4": ["review-local"],
        "4a": ["review-local", "local-checks"], "4b": ["pull-request-review"], "5": ["merge"], "5a": ["merge"], "5b": ["merge"],
        "6": ["complete"], "6.5": ["file-findings"], "7": ["sync"]}
body = open(os.path.join(root, "skills", "build-item", "SKILL.md"), encoding="utf-8").read()
headings = re.findall(r"^#{2,3} ([0-9]+(?:\.[0-9]+)?[a-z]?)\.? ", body, re.M)
upto7 = [h for h in headings if float(re.match(r"[0-9.]+", h).group(0).rstrip(".")) <= 7]
check("(7a) the loop still has numbered steps 0 to 7", (len(upto7) >= 12, "0" in upto7, "7" in upto7), (True, True, True))
check("(7b) no numbered step of the loop is missing from the table", [h for h in upto7 if h not in LOOP], [])
check("(7c) every step id the table names is in the definition, and every definition step is named", (sorted({s for v in LOOP.values() for s in v}), [s for v in LOOP.values() for s in v if s not in ids]), (sorted(STEPS), []))
check("(7d) step 8, the epic release, is not a step of this workflow", [s for s in ids if "release" in s], [])

# (8) each rule fails a scratch copy with the right reason
def scratch(name, change=None, rename=None, schema=None):
    folder = os.path.join(tmp, name)
    for sub in (".claude-plugin", "schemas", "workflows", os.path.join("skills", "build-item", "scripts")):
        os.makedirs(os.path.join(folder, sub))
    shutil.copy(os.path.join(root, ".claude-plugin", "plugin.json"), os.path.join(folder, ".claude-plugin"))
    shutil.copy(os.path.join(root, "skills", "build-item", "scripts", "workflow_report.py"), os.path.join(folder, "skills", "build-item", "scripts"))
    published = json.load(open(os.path.join(root, "schemas", "workflow.schema.json"), encoding="utf-8"))
    if schema: schema(published)
    json.dump(published, open(os.path.join(folder, "schemas", "workflow.schema.json"), "w"))
    document = copy.deepcopy(build)
    if change: change(document)
    json.dump(document, open(os.path.join(folder, "workflows", rename or "build.json"), "w"))
    return run(folder)

def first(d): return d["phases"][0]["steps"][0]
def setter(path_fn, key, value):
    def apply(d): path_fn(d)[key] = value
    return apply
def bloat(d): d["notes"] = "x" * 70000
def no_condition(d): d["phases"][2]["steps"][1]["when"] = {"mode": "condition", "condition": None}
def condition_on_always(d): first(d)["when"] = {"mode": "always", "condition": "review-path:fast"}
def duplicate(d): d["phases"][3]["steps"][0]["id"] = "select"
def schema_drift(s): s["properties"]["phases"]["items"]["properties"]["steps"]["items"]["properties"]["kind"]["enum"].append("hook")

CASES = [("a duplicate step id", dict(change=duplicate), "duplicate step id select"),
         ("an upper-case step id", dict(change=setter(first, "id", "Select")), "steps[0].id: must match"),
         ("a contract without @", dict(change=setter(first, "contract", "select-item")), "contract: must be <name>@<major>"),
         ("a bad kind", dict(change=setter(first, "kind", "task")), "kind: must be one of step, gate"),
         ("a source of skill", dict(change=setter(lambda d: first(d)["run"], "source", "skill")), "run.source: must be one of"),
         ("a condition outside the closed list", dict(change=setter(lambda d: d["phases"][2]["steps"][1]["when"], "condition", "tests:green")), "when.condition: must be one of"),
         ("a condition with mode always", dict(change=condition_on_always), "when.condition: must be null unless the mode is condition"),
         ("a missing condition with mode condition", dict(change=no_condition), "when.condition: must be one of"),
         ("a float version", dict(change=setter(lambda d: d, "version", 1.5)), "$.version: a float is not allowed"),
         ("no phases", dict(change=setter(lambda d: d, "phases", [])), "phases: must be a list of at least one phase"),
         ("a file name that differs from its id", dict(rename="other.json"), "the file name must be the id plus .json"),
         ("a definition over 64 KB", dict(change=bloat), "at most 65536"),
         ("a minimum plugin version newer than the plugin", dict(change=setter(lambda d: d, "minPluginVersion", "999.0.0")), "999.0.0 is newer than this plugin"),
         ("a run with no version", dict(change=lambda d: first(d)["run"].pop("version")), "run.version: must be a whole number, text or null"),
         ("a run version that is a list", dict(change=setter(lambda d: first(d)["run"], "version", [1])), "run.version: must be a whole number, text or null"),
         ("a ref that is not text", dict(change=lambda d: first(d)["run"].update(source="off", ref=5)), "run.ref: must be text or null"),
         ("a when with no condition key", dict(change=lambda d: first(d)["when"].pop("condition")), "when.condition: must be present"),
         ("a version past the limit", dict(change=setter(lambda d: d, "version", 2000000)), "version: must be a whole number from 1 to 1000000"),
         ("a schema list that differs from the script", dict(schema=schema_drift), "INVALID schemas/workflow.schema.json: kind: the schema lists")]
for index, (label, kwargs, reason) in enumerate(CASES):
    rc, out, err = scratch("case-%d" % index, **kwargs)
    check("(8) %s fails with its reason" % label, (rc, reason in out, out.startswith("INVALID ")), (1, True, True))
check("(9) an unchanged scratch copy passes", scratch("clean")[:2], (0, "WORKFLOWS: ok (1 files, 13 steps)"))
empty = os.path.join(tmp, "empty"); os.makedirs(empty)
rc, out, err = run(empty)
check("(10) unreadable input exits 2 with one line on stderr", (rc, out, err.startswith("check-workflows: "), "Traceback" in err), (2, "", True, False))
PY
PRC=$?; OUT="$(cat "$T/cases.out")"
echo "$OUT" | sed 's/^ok   /  ok   /; s/^FAIL /  FAIL /'
echo "$OUT" | grep -q '^FAIL' && FAIL=1
[ "$PRC" -eq 0 ] || bad "(0) the Python cases crashed (exit $PRC)"

exit $FAIL
