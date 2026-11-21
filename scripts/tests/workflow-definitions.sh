#!/bin/bash
# scripts/tests/workflow-definitions.sh — every built-in definition in workflows/, whatever its
# workflow: it validates (scripts/check-workflows.py, which also holds it to
# schemas/workflow.schema.json's values), its step ids are unique, every contract is in the catalog,
# every built-in run.ref is a real skill, and a VERSION RATCHET: a shipped definition cannot change
# silently. scripts/tests/fixtures/workflow-versions.json records, per workflow id, its version, the
# sha256 of its canonical JSON (the runner's own rule) and every step id it has ever shipped with
# that step's contract. The test fails when the hash moved but the version did not, when a recorded
# step id disappeared or changed contract (ids are permanent: a changed step gets a new id and the
# definition a new version), and when a definition's version is not the recorded one.
#
#   bash scripts/tests/workflow-definitions.sh            check
#   bash scripts/tests/workflow-definitions.sh --record   rewrite the fixture from workflows/ (run it
#                                                         AFTER the release's prepare has stamped
#                                                         minPluginVersion, never by hand)
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
FIXTURE = os.path.join(ROOT, "scripts/tests/fixtures/workflow-versions.json")
spec = importlib.util.spec_from_file_location("workflow_report", os.path.join(ROOT, "skills/build-item/scripts/workflow_report.py"))
report = importlib.util.module_from_spec(spec); spec.loader.exec_module(report)
CATALOG = json.load(open(os.path.join(ROOT, "schemas/step-contracts.json"), encoding="utf-8"))["contracts"]


def check(label, good, detail=""):
    print(("ok   " if good else "FAIL ") + label + ("" if good else " -> %s" % (detail,)))


defs = {}
for path in sorted(glob.glob(os.path.join(ROOT, "workflows", "*.json"))):
    d = json.load(open(path, encoding="utf-8"))
    defs[os.path.basename(path)] = d


def steps(d):
    return [s for p in d.get("phases", []) for s in p.get("steps", [])]


def entry(d):
    return {"version": d["version"], "sha256": report.definition_hash(d), "steps": {s["id"]: s["contract"] for s in steps(d)}}


try:
    recorded = json.load(open(FIXTURE, encoding="utf-8"))["workflows"]
except (OSError, ValueError, KeyError):
    recorded = {}

if MODE == "--record":
    out = {}
    for name, d in defs.items():
        now, was = entry(d), recorded.get(d["id"], {})
        if was and was.get("sha256") != now["sha256"] and was.get("version") == now["version"]:
            print("workflow-definitions: %s changed but its version did not; bump it first" % name, file=sys.stderr)
            sys.exit(2)
        merged = dict(was.get("steps", {}))
        for sid, contract in now["steps"].items():
            if sid in merged and merged[sid] != contract:
                print("workflow-definitions: %s step %s changed contract; give it a new id" % (name, sid), file=sys.stderr)
                sys.exit(2)
            merged[sid] = contract
        out[d["id"]] = {"version": now["version"], "sha256": now["sha256"], "steps": dict(sorted(merged.items()))}
    with open(FIXTURE, "w", encoding="utf-8") as f:
        json.dump({"_readme": "Written by bash scripts/tests/workflow-definitions.sh --record after the release's prepare; never by hand.",
                   "workflows": dict(sorted(out.items()))}, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print("recorded %d workflows" % len(out))
    sys.exit(0)

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
        continue
    check("%s: every contract is in the catalog" % name, missing == [], missing)
    check("%s: every built-in run.ref is a skill" % name, absent == [], absent)
    now, was = entry(d), recorded.get(d["id"])
    if was is None:
        check("%s: recorded in workflow-versions.json (run --record)" % name, False, d["id"])
        continue
    check("%s: version %s is the recorded one" % (name, now["version"]), now["version"] == was["version"], (now["version"], was["version"]))
    check("%s: unchanged since it was recorded, or its version moved" % name,
          now["sha256"] == was["sha256"] or now["version"] != was["version"], now["sha256"])
    lost = sorted(i for i in was["steps"] if i not in now["steps"])
    moved = sorted(i for i in was["steps"] if i in now["steps"] and now["steps"][i] != was["steps"][i])
    check("%s: every step id it ever shipped is still there with its contract" % name, lost == [] and moved == [], (lost, moved))
for wid in sorted(set(recorded) - {d["id"] for d in defs.values()}):
    check("recorded workflow %s still ships" % wid, False, wid)
PY

if [ "$MODE" = "--record" ]; then
  python3 "$WORK/ratchet.py" "$ROOT" --record; exit $?
fi

python3 "$WORK/ratchet.py" "$ROOT" check > "$WORK/out.txt" 2>&1 || { cat "$WORK/out.txt"; echo "FAIL the ratchet did not run to the end"; exit 1; }

# The ratchet's own cases, on scratch copies of the fixture and of one definition.
cat > "$WORK/cases.py" <<'PY'
import json, os, shutil, subprocess, sys
ROOT, WORK, SCRIPT = sys.argv[1], sys.argv[2], sys.argv[3]

def check(label, good, detail=""):
    print(("ok   " if good else "FAIL ") + label + ("" if good else " -> %s" % (detail,)))

def scratch(name):
    root = os.path.join(WORK, name)
    for sub in ("workflows", "schemas", "scripts/tests/fixtures", "skills"):
        os.makedirs(os.path.join(root, sub), exist_ok=True)
    shutil.copytree(os.path.join(ROOT, "workflows"), os.path.join(root, "workflows"), dirs_exist_ok=True)
    shutil.copy(os.path.join(ROOT, "schemas/step-contracts.json"), os.path.join(root, "schemas"))
    shutil.copy(os.path.join(ROOT, "schemas/workflow.schema.json"), os.path.join(root, "schemas"))
    shutil.copy(os.path.join(ROOT, "scripts/check-workflows.py"), os.path.join(root, "scripts"))
    shutil.copy(os.path.join(ROOT, "scripts/tests/fixtures/workflow-versions.json"), os.path.join(root, "scripts/tests/fixtures"))
    os.makedirs(os.path.join(root, ".claude-plugin"), exist_ok=True)
    shutil.copy(os.path.join(ROOT, ".claude-plugin/plugin.json"), os.path.join(root, ".claude-plugin"))
    for skill in os.listdir(os.path.join(ROOT, "skills")):
        os.symlink(os.path.join(ROOT, "skills", skill), os.path.join(root, "skills", skill))
    return root

def run(root, *args):
    done = subprocess.run([sys.executable, SCRIPT, root] + list(args or ["check"]), capture_output=True, text=True)
    return done.returncode, done.stdout + done.stderr

def edit(root, fn):
    p = os.path.join(root, "workflows/hotfix.json")
    d = json.load(open(p, encoding="utf-8")); fn(d)
    json.dump(d, open(p, "w", encoding="utf-8"), indent=2)

root = scratch("same-version")
edit(root, lambda d: d["phases"][0]["steps"][0].__setitem__("summary", "Changed without a version bump."))
rc, out = run(root)
check("a definition changed without a version bump fails", "FAIL hotfix.json: unchanged since it was recorded" in out, out)
rc, out = run(root, "--record")
check("... and --record refuses to record it", rc == 2 and "changed but its version did not" in out, (rc, out))

root = scratch("bumped-unrecorded")
edit(root, lambda d: d.__setitem__("version", d["version"] + 1))
rc, out = run(root)
check("a bumped version that was not recorded fails", "FAIL hotfix.json: version" in out, out)
rc, _ = run(root, "--record"); rc2, out = run(root)
check("... and passes once recorded", rc == 0 and "FAIL hotfix.json" not in out, out)

root = scratch("step-gone")
def drop_close(d):
    d["version"] += 1
    d["phases"][1]["steps"] = [s for s in d["phases"][1]["steps"] if s["id"] != "close"]
edit(root, drop_close)
rc, out = run(root)
check("a recorded step id that disappeared fails, even with a new version", "FAIL hotfix.json: every step id it ever shipped" in out, out)

root = scratch("contract-moved")
def recontract(d):
    d["version"] += 1
    for s in d["phases"][1]["steps"]:
        if s["id"] == "close":
            s["contract"] = "hotfix-report@1"
edit(root, recontract)
rc, out = run(root, "--record")
check("a step id that changed contract is refused by --record", rc == 2 and "changed contract" in out, (rc, out))
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
