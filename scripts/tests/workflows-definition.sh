#!/bin/bash
# Tests for the built-in workflow definitions and scripts/check-workflows.py: the shipped Build
# workflow passes, its eleven step ids are the published ones in order, each runs its step skill
# always and stops on failure (the whole run with canned answers: build-workflow-run.sh), and each
# rule the checker enforces fails a scratch copy with the right reason.
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

STEPS = ["claim", "start", "branch", "build", "risk-check", "local-checks", "review", "merge", "complete",
         "capture", "sync"]
SKILLS = ["claim-story", "story-lifecycle", "branch-feature", "ultracode-build", "risk-check", "local-checks",
          "review-story", "merge-story", "story-lifecycle", "capture-findings", "sync-base"]
build = json.load(open(os.path.join(root, "workflows", "build.json"), encoding="utf-8"))
plugin = json.load(open(os.path.join(root, ".claude-plugin", "plugin.json"), encoding="utf-8"))["version"]
steps = [step for phase in build["phases"] for step in phase["steps"]]
ids = [step["id"] for step in steps]

rc, out, err = run()
check("(1) the shipped definitions pass", (rc, out, err), (0, "WORKFLOWS: ok (1 files, 11 steps)", ""))
as_tuple = lambda v: tuple(int(p) for p in v.split("."))
check("(2) minPluginVersion is not newer than this plugin", as_tuple(build["minPluginVersion"]) <= as_tuple(plugin))
check("(3) the step ids are exactly the eleven published ones, in order", ids, STEPS)
check("(4) every step id is unique and a lower-case slug", (len(set(ids)), [i for i in ids if not re.match(r"^[a-z][a-z0-9-]{0,63}$", i)]), (11, []))
check("(5) the phases are start, build, review and land", [p["id"] for p in build["phases"]], ["start", "build", "review", "land"])
check("(6) every step always runs, stops on failure and is a built-in step skill",
      [(s["kind"], s["when"], s["onFail"], s["run"]["source"], s["run"]["version"]) for s in steps],
      [("step", {"mode": "always", "condition": None}, "stop", "builtin", None)] * 11)
check("(7a) each step runs its step skill", [s["run"]["ref"] for s in steps], SKILLS)
check("(7b) each step's skill exists", [r for r in SKILLS if not os.path.isfile(os.path.join(root, "skills", r, "SKILL.md"))], [])
check("(7c) version 2, minPluginVersion this plugin's version", (build["version"], build["minPluginVersion"]), (2, plugin))
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
def no_condition(d): first(d)["when"] = {"mode": "condition", "condition": None}
def condition_on_always(d): first(d)["when"] = {"mode": "always", "condition": "review-path:fast"}
def duplicate(d): d["phases"][3]["steps"][0]["id"] = "claim"
def schema_drift(s): s["properties"]["phases"]["items"]["properties"]["steps"]["items"]["properties"]["kind"]["enum"].append("hook")

CASES = [("a duplicate step id", dict(change=duplicate), "duplicate step id claim"),
         ("an upper-case step id", dict(change=setter(first, "id", "Claim")), "steps[0].id: must match"),
         ("a contract without @", dict(change=setter(first, "contract", "claim")), "contract: must be <name>@<major>"),
         ("a bad kind", dict(change=setter(first, "kind", "task")), "kind: must be one of step, gate"),
         ("a source of skill", dict(change=setter(lambda d: first(d)["run"], "source", "skill")), "run.source: must be one of"),
         ("a condition outside the closed list", dict(change=lambda d: first(d).update(when={"mode": "condition", "condition": "tests:green"})), "when.condition: must be one of"),
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
check("(9) an unchanged scratch copy passes", scratch("clean")[:2], (0, "WORKFLOWS: ok (1 files, 11 steps)"))
empty = os.path.join(tmp, "empty"); os.makedirs(empty)
rc, out, err = run(empty)
check("(10) unreadable input exits 2 with one line on stderr", (rc, out, err.startswith("check-workflows: "), "Traceback" in err), (2, "", True, False))
PY
PRC=$?; OUT="$(cat "$T/cases.out")"
echo "$OUT" | sed 's/^ok   /  ok   /; s/^FAIL /  FAIL /'
echo "$OUT" | grep -q '^FAIL' && FAIL=1
[ "$PRC" -eq 0 ] || bad "(0) the Python cases crashed (exit $PRC)"

exit $FAIL
