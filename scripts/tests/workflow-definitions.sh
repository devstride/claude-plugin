#!/bin/bash
# scripts/tests/workflow-definitions.sh — every built-in definition in workflows/, whatever its
# workflow: it validates (scripts/check-workflows.py, which also holds it to
# schemas/workflow.schema.json's values), its step ids are unique, every contract is in the catalog,
# every built-in run.ref is a real skill, and a VERSION RATCHET: a shipped definition cannot change
# silently. The record is workflows/registry.json, the append-only registry of every version of
# every built-in workflow (scripts/workflow-registry.py), whose newest row per workflow is the
# current record: its version, the sha256 of its canonical JSON (the runner's own rule) without
# minPluginVersion, which a release stamps, and its steps. The test fails when the hash moved but
# the version did not, when a step id a runnable version shipped disappeared or changed contract
# (ids are permanent: a changed step gets a new id and the definition a new version), and when a
# definition's version is not its newest recorded one.
#
#   bash scripts/tests/workflow-definitions.sh            check
#   bash scripts/tests/workflow-definitions.sh --record   append a row for every definition whose
#                                                         fingerprint has no row yet (marked
#                                                         unreleased until the release's prepare
#                                                         names it); it never edits a released row
#
# The replay cases at the end drive the REAL runner with scripted step answers through
# scripts/tests/fixtures/workflow-replay.py, the driver the workflow tests share.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAIL=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export PYTHONDONTWRITEBYTECODE=1
MODE="${1:-check}"
case "$MODE" in check|--record) ;; *) echo "usage: workflow-definitions.sh [--record]" >&2; exit 2 ;; esac

cat > "$WORK/ratchet.py" <<'PY'
import glob, importlib.util, json, os, subprocess, sys

ROOT, MODE = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("workflow_registry", os.path.join(ROOT, "scripts/workflow-registry.py"))
registry = importlib.util.module_from_spec(spec); spec.loader.exec_module(registry)
CATALOG = json.load(open(os.path.join(ROOT, "schemas/step-contracts.json"), encoding="utf-8"))["contracts"]


def check(label, good, detail=""):
    print(("ok   " if good else "FAIL ") + label + ("" if good else " -> %s" % (detail,)))


if MODE == "--record":
    sys.exit(registry.main(["record", "--root", ROOT]))

plugin = registry.Plugin(ROOT)
defs = {os.path.basename(path): json.load(open(path, encoding="utf-8"))
        for path in sorted(glob.glob(os.path.join(ROOT, "workflows", "*.json"))) if os.path.basename(path) != "registry.json"}
steps = registry.steps_of

done = subprocess.run([sys.executable, os.path.join(ROOT, "scripts/check-workflows.py")], capture_output=True, text=True)
check("check-workflows.py passes every definition in workflows/ (%d files)" % len(defs), done.returncode == 0, done.stdout + done.stderr)
# Definitions whose contracts and step skill land with a later story of the same integration: the
# catalog and skill checks wait for them, and the entry must go the moment they are complete.
PENDING = {"release.json", "release-cut-to-deploy.json", "release-merge-and-deploy.json", "release-docs.json",
           "release-notes.json", "release-post-deploy.json"}
for name, d in defs.items():
    ids = [s["id"] for s in steps(d)]
    check("%s: step ids are unique" % name, len(ids) == len(set(ids)), [i for i in ids if ids.count(i) > 1])
    missing = [s["contract"] for s in steps(d) if s["contract"] not in CATALOG]
    refs = [s["run"]["ref"] for s in steps(d) if s.get("run", {}).get("source") == "builtin"]
    absent = [r for r in refs if not os.path.isfile(os.path.join(ROOT, "skills", r, "SKILL.md"))]
    if name in PENDING:
        check("%s: still pending its contracts or step skill (else drop it from PENDING)" % name, bool(missing or absent), "complete")
    else:
        check("%s: every contract is in the catalog" % name, missing == [], missing)
        check("%s: every built-in run.ref is a skill" % name, absent == [], absent)
# The ratchet: the definitions against the registry's newest rows, the same rule
# `workflow-registry.py check` applies (it adds the base comparison, the notes and the page).
try:
    recorded = plugin.registry()
except (OSError, ValueError) as error:
    check("workflows/registry.json is readable", False, error)
    sys.exit(0)
faults = registry.current_faults(plugin, recorded)
mine = lambda wid: [f for f in faults if f.startswith(wid + ":")]
for name, d in defs.items():
    check("%s: recorded at its version, unchanged since, every shipped step id kept" % name, mine(d["id"]) == [], mine(d["id"]))
others = [f for f in faults if not any(f.startswith(d["id"] + ":") for d in defs.values())]
check("every recorded workflow still ships and every contract is recorded", others == [], others)
PY

if [ "$MODE" = "--record" ]; then
  python3 "$WORK/ratchet.py" "$ROOT" --record; exit $?
fi

python3 "$WORK/ratchet.py" "$ROOT" check > "$WORK/out.txt" 2>&1 || { cat "$WORK/out.txt"; echo "FAIL the ratchet did not run to the end"; exit 1; }

# The ratchet's own cases, on scratch copies of the registry and of one definition.
cat > "$WORK/cases.py" <<'PY'
import json, os, shutil, subprocess, sys
ROOT, WORK, SCRIPT = sys.argv[1], sys.argv[2], sys.argv[3]

def check(label, good, detail=""):
    print(("ok   " if good else "FAIL ") + label + ("" if good else " -> %s" % (detail,)))

def scratch(name):
    root = os.path.join(WORK, name)
    for sub in ("workflows", "schemas", "scripts", "skills"):
        os.makedirs(os.path.join(root, sub), exist_ok=True)
    shutil.copytree(os.path.join(ROOT, "workflows"), os.path.join(root, "workflows"), dirs_exist_ok=True)
    for f in ("step-contracts.json", "workflow.schema.json", "workflow-registry.schema.json"):
        shutil.copy(os.path.join(ROOT, "schemas", f), os.path.join(root, "schemas"))
    for f in ("check-workflows.py", "workflow-registry.py"):
        shutil.copy(os.path.join(ROOT, "scripts", f), os.path.join(root, "scripts"))
    os.makedirs(os.path.join(root, ".claude-plugin"), exist_ok=True)
    shutil.copy(os.path.join(ROOT, ".claude-plugin/plugin.json"), os.path.join(root, ".claude-plugin"))
    for skill in os.listdir(os.path.join(ROOT, "skills")):
        os.symlink(os.path.join(ROOT, "skills", skill), os.path.join(root, "skills", skill))
    return root

def run(root, *args):
    done = subprocess.run([sys.executable, SCRIPT, root] + list(args or ["check"]), capture_output=True, text=True)
    return done.returncode, done.stdout + done.stderr

def edit(root, fn, name="hotfix"):
    p = os.path.join(root, "workflows/%s.json" % name)
    d = json.load(open(p, encoding="utf-8")); fn(d)
    json.dump(d, open(p, "w", encoding="utf-8"), indent=2)

def rows(root, wid):
    return json.load(open(os.path.join(root, "workflows/registry.json"), encoding="utf-8"))["workflows"][wid]

root = scratch("same-version")
edit(root, lambda d: d["phases"][0]["steps"][0].__setitem__("summary", "Changed without a version bump."))
rc, out = run(root)
check("a definition changed without a version bump fails", "FAIL hotfix.json: recorded at its version" in out and "changed since version" in out, out)
rc, out = run(root, "--record")
check("... and --record refuses to record it", rc == 1 and "changed but its version did not" in out, (rc, out))

root = scratch("restamped")
edit(root, lambda d: d.__setitem__("minPluginVersion", "0.0.1"))
rc, out = run(root)
check("a definition whose minPluginVersion alone was restamped passes without a version bump",
      "FAIL hotfix.json" not in out, out)

root = scratch("bumped-unrecorded")
before = len(rows(root, "hotfix"))
edit(root, lambda d: d.__setitem__("version", d["version"] + 1))
rc, out = run(root)
check("a bumped version that was not recorded fails", "FAIL hotfix.json" in out and "is not its newest recorded version" in out, out)
rc, rout = run(root, "--record"); rc2, out = run(root)
new = rows(root, "hotfix")
check("... and passes once recorded", rc == 0 and "FAIL hotfix.json" not in out, (rout, out))
check("... --record appended one row, unreleased, with no date and no note, and kept every earlier row",
      len(new) == before + 1 and new[-1]["pluginVersion"] == "unreleased" and new[-1]["releasedAt"] is None
      and new[-1]["note"] == "" and "dormant" not in new[-1], new[-1])
edit(root, lambda d: d["phases"][0]["steps"][0].__setitem__("summary", "Changed again before any release."))
rc, rout = run(root, "--record"); rc2, out = run(root)
again = rows(root, "hotfix")
check("... an unreleased row follows a later edit at the same version instead of adding a row",
      rc == 0 and "UPDATED unreleased hotfix" in rout and len(again) == before + 1 and again[-1]["sha256"] != new[-1]["sha256"]
      and "FAIL hotfix.json" not in out, (rout, out))

root = scratch("version-skips")
edit(root, lambda d: d.__setitem__("version", d["version"] + 2))
rc, out = run(root, "--record")
check("a version that skips is refused by --record", rc == 1 and "the next version is" in out, (rc, out))

root = scratch("step-gone")
def drop_close(d):
    d["version"] += 1
    d["phases"][1]["steps"] = [s for s in d["phases"][1]["steps"] if s["id"] != "close"]
edit(root, drop_close)
rc, out = run(root)
check("a recorded step id that disappeared fails, even with a new version", "every step id a runnable version shipped" in out
      and "FAIL hotfix.json" in out, out)

root = scratch("contract-moved")
def recontract(d):
    d["version"] += 1
    for s in d["phases"][1]["steps"]:
        if s["id"] == "close":
            s["contract"] = "hotfix-report@1"
edit(root, recontract)
rc, out = run(root, "--record")
check("a step id that changed contract is refused by --record", rc == 1 and "changed contract" in out, (rc, out))

root = scratch("dormant-rerecord")
before = len(rows(root, "release-post-deploy"))
edit(root, lambda d: d["phases"][-1]["steps"][-1].__setitem__("summary", "A changed health-check step."), "release-post-deploy")
rc, out = run(root)
check("a dormant definition changed at its version fails until it is recorded", "FAIL release-post-deploy.json" in out, out)
rc, rout = run(root, "--record"); rc2, out = run(root)
new = rows(root, "release-post-deploy")
check("... --record re-records it at the same version, marked dormant, and the ratchet passes",
      rc == 0 and len(new) == before + 1 and new[-1]["version"] == new[-2]["version"] and new[-1].get("dormant") is True
      and "FAIL release-post-deploy.json" not in out, (rout, out))
PY
python3 "$WORK/cases.py" "$ROOT" "$WORK" "$WORK/ratchet.py" >> "$WORK/out.txt" 2>&1 || echo "FAIL the ratchet cases did not run to the end" >> "$WORK/out.txt"

# Replays through the shared driver.
for scenario in "$ROOT"/scripts/tests/fixtures/workflow-replay/*.json; do
  [ -f "$scenario" ] || continue
  if OUT="$(python3 "$ROOT/scripts/tests/fixtures/workflow-replay.py" "$ROOT" "$scenario" 2>&1)"; then
    echo "ok   replay $(basename "$scenario"): $OUT" >> "$WORK/out.txt"
  else
    echo "FAIL replay $(basename "$scenario"): $OUT" >> "$WORK/out.txt"
  fi
done

sed 's/^/  /' "$WORK/out.txt"
grep -q '^FAIL' "$WORK/out.txt" && FAIL=1
[ "$FAIL" = 0 ] && echo "workflow-definitions: PASS" || echo "workflow-definitions: FAIL"
exit "$FAIL"
