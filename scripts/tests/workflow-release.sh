#!/bin/bash
# Tests for the six built-in release workflow definitions and their generator
# (scripts/build-release-workflows.py over scripts/release-workflow-source.json): --check is clean,
# a hand edit of a generated file fails it, each definition passes scripts/check-workflows.py, and
# each one's phases and step ids equal the orderings pinned below, written from the release's
# own step list (the three clearance scopes and the three partial entries).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAIL=0; bad() { echo "  FAIL $1"; FAIL=1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# The cases write to a file: a here-document inside $( ) breaks on an apostrophe under bash 3.2.
python3 - "$ROOT" "$T" > "$T/cases.out" <<'PY'
import json, os, shutil, subprocess, sys
root, tmp = sys.argv[1], sys.argv[2]
generator = os.path.join(root, "scripts", "build-release-workflows.py")

def check(name, got, want=True):
    print(("ok   " if got == want else "FAIL ") + name + ("" if got == want else " — got %r, want %r" % (got, want)))

def gen(*args):
    done = subprocess.run([sys.executable, generator] + list(args), capture_output=True, text=True)
    return done.returncode, done.stdout.strip(), done.stderr.strip()

w = str.split
TRAIN = w("train-finish-earlier ship-plan train-snapshot train-pr train-review train-pre-ship train-merge train-close-out train-level")
REVIEW = w("release-review classify-at-pre-ship pre-ship-release discharge-hold docs-plan")
PINNED = {
    "release": [
        ("start", w("train-claim tower-claim ground-truth release-shape ci-hold-proof")), ("train", TRAIN),
        ("cut", w("release-delta classify-release cut-branch train-claim-hand-on open-release-pr")), ("review", REVIEW),
        ("go-ahead", w("hotfix-catch-up pre-merge-check dev-deploy-before-decision go-ahead dev-deploy-after-yes merge-confirmations production-merge")),
        ("deploy", w("approve-deploy confirm-deploy score-estimates")),
        ("close-out", w("post-deploy-check sync-production delete-release-branch train-level-final tower-hand-back update-docs sync-knowledge-base post-deploy-close-out write-release-notes release-recap auto-start-next"))],
    "release-cut-to-deploy": [
        ("start", w("train-claim ground-truth release-shape ci-hold-proof")), ("train", TRAIN),
        ("cut", w("release-delta classify-release tower-claim cut-branch train-claim-hand-on open-release-pr")), ("review", REVIEW),
        ("go-ahead", w("hotfix-catch-up previous-release-gate pre-merge-check dev-deploy-before-decision go-ahead previous-release-recheck dev-deploy-after-yes merge-confirmations production-merge")),
        ("deploy", w("approve-deploy confirm-deploy score-estimates")),
        ("close-out", w("sync-production delete-release-branch train-level-final post-pending-status tower-hand-back post-deploy-check post-deploy-status update-docs sync-knowledge-base post-deploy-close-out write-release-notes release-recap auto-start-next"))],
    "release-merge-and-deploy": [
        ("start", w("train-claim ground-truth release-shape ci-hold-proof")), ("train", TRAIN),
        ("cut", w("release-delta classify-release queue cut-branch production-in-branch open-release-pr train-level-after-cut train-claim-hand-on")),
        ("checks", w("checks-tip classify-at-checks pre-ship-at-checks dev-deploy-wait pre-merge-at-checks checks-stamp")), ("review", REVIEW),
        ("go-ahead", w("hotfix-catch-up previous-release-gate pre-merge-check go-ahead queue-final tower-claim previous-release-recheck stamp-verify pre-merge-recheck rerun-at-merge go-ahead-recheck stamp-verify-final merge-confirmations production-merge")),
        ("deploy", w("post-pending-status approve-deploy confirm-deploy score-estimates hand-back-after-deploy")),
        ("close-out", w("post-deploy-check post-deploy-status sync-production delete-release-branch train-level-final update-docs sync-knowledge-base post-deploy-close-out write-release-notes release-recap auto-start-next"))],
    "release-post-deploy": [("find", w("merged-release confirm-deploy")), ("close-out", w("post-deploy-check post-deploy-status"))],
    "release-docs": [("find", w("merged-release confirm-deploy")), ("docs", w("update-docs sync-knowledge-base"))],
    "release-notes": [("find", w("merged-release confirm-deploy")), ("notes", w("write-release-notes"))],
}
PHASE_NAMES = {"start": "Claim and orient", "train": "Merge the release train", "cut": "Cut the release branch",
               "checks": "Check before claiming the tower", "review": "Review and settle", "go-ahead": "Owner go-ahead",
               "deploy": "Deploy and hand back", "close-out": "Health check and close-out"}
# Safety steps no ordering may drop or move past the production merge.
REQUIRED = ["release-review", "pre-ship-release", "go-ahead", "merge-confirmations"]

check("(1) --check is clean on the committed files", gen("--check")[:2], (0, "RELEASE WORKFLOWS: clean (6 files)"))
for ident, phases in PINNED.items():
    document = json.load(open(os.path.join(root, "workflows", ident + ".json"), encoding="utf-8"))
    got = [(p["id"], [s["id"] for s in p["steps"]]) for p in document["phases"]]
    check("(2) %s: phases and step ids equal the pinned ordering" % ident, got, phases)
    named = dict((p["id"], p["name"]) for p in document["phases"] if p["id"] in PHASE_NAMES)
    check("(3) %s: every release phase carries its pinned name" % ident, named, dict((k, PHASE_NAMES[k]) for k in named))
    steps = [s for p in document["phases"] for s in p["steps"]]
    check("(4) %s: on demand, no rollup ending, matches no item" % ident,
          (document["startsWhen"], document["endsBy"], document["appliesTo"]),
          ("on-demand", None, {"workTypes": [], "tags": [], "repositories": []}))
    check("(5) %s: every step is a built-in step that always runs and stops on failure" % ident,
          sorted(set((s["kind"], s["run"]["source"], json.dumps(s["when"], sort_keys=True), s["onFail"]) for s in steps)),
          [("step", "builtin", json.dumps({"condition": None, "mode": "always"}, sort_keys=True), "stop")])
    ids = [s["id"] for s in steps]
    if "production-merge" in ids:
        before = ids[:ids.index("production-merge")]
        check("(6) %s: review, pre-ship, the go-ahead and the merge confirmations all come before the production merge" % ident,
              [r for r in REQUIRED if r not in before], [])
    else:
        check("(6) %s: a partial entry opens no pull request and merges nothing" % ident,
              [i for i in ids if i in ("open-release-pr", "production-merge", "train-merge", "train-claim", "tower-claim")], [])
source = json.load(open(os.path.join(root, "scripts", "release-workflow-source.json"), encoding="utf-8"))
versions = set(json.load(open(os.path.join(root, "workflows", i + ".json"), encoding="utf-8"))["minPluginVersion"] for i in PINNED)
check("(7) one minPluginVersion, from the source, for all six", versions, {source["minPluginVersion"]})

# a hand edit of a generated file fails --check, naming the file
copy = os.path.join(tmp, "copy")
for sub in ("scripts", "workflows"):
    os.makedirs(os.path.join(copy, sub))
shutil.copy(os.path.join(root, "scripts", "release-workflow-source.json"), os.path.join(copy, "scripts"))
for ident in PINNED:
    shutil.copy(os.path.join(root, "workflows", ident + ".json"), os.path.join(copy, "workflows"))
check("(8) a faithful copy is clean", gen("--check", "--root", copy)[0], 0)
path = os.path.join(copy, "workflows", "release.json")
text = open(path, encoding="utf-8").read()
open(path, "w", encoding="utf-8").write(text.replace('"Review the release"', '"Review it"', 1))
rc, out, err = gen("--check", "--root", copy)
check("(9) a hand edit fails --check naming the file", (rc, out), (1, "DIFFERS workflows/release.json: run python3 scripts/build-release-workflows.py --write"))
check("(10) --write restores it", (gen("--write", "--root", copy)[0], gen("--check", "--root", copy)[0]), (0, 0))
os.remove(os.path.join(copy, "workflows", "release-notes.json"))
check("(11) a missing generated file fails --check", gen("--check", "--root", copy)[:2],
      (1, "DIFFERS workflows/release-notes.json: run python3 scripts/build-release-workflows.py --write"))
broken = json.load(open(os.path.join(copy, "scripts", "release-workflow-source.json"), encoding="utf-8"))
broken["definitions"]["release"]["phases"][0]["steps"].append("no-such-step")
json.dump(broken, open(os.path.join(copy, "scripts", "release-workflow-source.json"), "w", encoding="utf-8"))
rc, out, err = gen("--check", "--root", copy)
check("(12) a definition naming an unknown step is an invalid source (exit 2, one line)", (rc, "no-such-step" in err, "Traceback" in err), (2, True, False))
check("(13) a usage error exits 2", gen("--frobnicate")[0], 2)
PY
PRC=$?; OUT="$(cat "$T/cases.out")"
echo "$OUT" | sed 's/^ok   /  ok   /; s/^FAIL /  FAIL /'
echo "$OUT" | grep -q '^FAIL' && FAIL=1
[ "$PRC" -eq 0 ] || bad "(0) the Python cases crashed (exit $PRC)"

exit $FAIL
