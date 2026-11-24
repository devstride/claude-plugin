#!/bin/bash
# Tests for the six built-in release workflow definitions and their generator
# (scripts/build-release-workflows.py over scripts/release-workflow-source.json): --check is clean,
# a hand edit of a generated file fails it, each definition passes scripts/check-workflows.py, and
# each one's phases and step ids equal the orderings pinned below, written from the release's
# own step list (the three clearance scopes and the three partial entries). It also proves the
# entry rewrite lost and duplicated nothing: every sentence of the old release page (read at a
# pinned base, kept as a fixture) is held once, moved into one step reference, or retired with
# what replaced it; the entry keeps its floors, arguments and loop duties and no numbered step.
# And each full definition, walked through the real runner with scripted answers, hands its
# class, pre-ship, pre-merge and post-deploy checks the commit ids earlier steps answered.
# The replays in scripts/tests/fixtures/workflow-release/ drive the real runner through the start,
# the train, the cut, the queue and the adopted shapes (the shared driver,
# scripts/tests/fixtures/workflow-replay.py), and copies of the full definitions with a required
# step authored away are refused. A second set of replays covers the go-ahead to the end: a hotfix
# landing mid-review, a head that moves, the checks stamp, the standing yes, the previous release
# gate, the merge confirmations, the deploy, every health outcome, documentation and notes, and the
# partial entries; two runs in one session (auto start), the backstop, the records a mixed fleet
# shares, a failed report forward and the no-runner order are driven inline.
# No network.
#
# THE RELEASE WORKFLOW IS NOT SWITCHED ON. /devstride:release follows skills/release/SKILL.md, the
# page of the last release before the split, and the runner refuses the release definitions outside
# a rehearsal. The rewritten entry page waits at scripts/staged/skills/release/SKILL.md, and every
# case here that reads "the entry" reads that file. Cases (140) to (142) hold the switch off. To
# switch it on, once a rehearsal of the Release workflow has passed, in one change:
#   1. move scripts/staged/skills/release/SKILL.md over skills/release/SKILL.md;
#   2. delete the "release-steps" line from "dormantSkills" in schemas/step-contracts.json, and
#      the "Not switched on yet" paragraph from skills/release-steps/SKILL.md;
#   3. here: ENTRY becomes "skills/release/SKILL.md", LIVE and the live-page callers in case (34)
#      go, the walks stop passing "rehearsal", and cases (140) to (142) are deleted;
#   4. drop what still holds the old page, each marked "until the release entry is switched":
#      the ten release sites in step-skills.sh, the page order in auto-start.sh (17), the first
#      site in merge-gate.sh (31), the page's lines in plain-language-output.sh (5) and
#      profile-default.sh (9); in skills/review/references/delivery-loop-invariants.md the pairs
#      pinned to skills/release/SKILL.md whose words the new page does not hold (the needle check
#      names them) and the step numbers in K8 and Q2; in schemas/seam-registry.json the numbered
#      "release <n>" callers (then scripts/build-config-schema.py --write); the README's
#      `release` row and its "not switched on yet" sentence; scripts/tests/workflow-dormant.sh's
#      release walk; the budget of skills/release/SKILL.md;
#   5. write the CHANGELOG entry and prepare the version as for any change to a skill.
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
# After the hand-back the health check never stops the run, so the status step always posts its
# outcome; under scope release it comes before the sync, and FAIL stops there.
catalog = json.load(open(os.path.join(root, "schemas", "step-contracts.json"), encoding="utf-8"))["contracts"]
for ident in ("release", "release-cut-to-deploy", "release-merge-and-deploy", "release-post-deploy"):
    steps = [s for p in json.load(open(os.path.join(root, "workflows", ident + ".json"), encoding="utf-8"))["phases"] for s in p["steps"]]
    at = [s["id"] for s in steps].index("post-deploy-check")
    classes = dict((v["value"], v["class"]) for v in catalog[steps[at]["contract"]]["verdict"]["values"])
    if ident == "release":
        check("(23) release: the health check's FAIL stops before the sync", (classes["FAIL"], steps[at + 1]["id"]), ("stop", "sync-production"))
    else:
        check("(23) %s: the health check never stops, and the status step comes next" % ident,
              (sorted(set(classes.values()) - {"continue", "skipped"}), steps[at + 1]["id"]), ([], "post-deploy-status"))
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
# selection: the definition a full release runs is chosen by release.clearance.scope
def select(config):
    path = os.path.join(tmp, "config.json")
    with open(path, "w", encoding="utf-8") as out:
        out.write(config if isinstance(config, str) else json.dumps(config))
    return gen("--select", path)[:2]
check("(14) no release block gives release", select({}), (0, "DEFINITION: workflows/release.json"))
check("(15) no clearance block gives release", select({"release": {"releaseSource": "develop"}}), (0, "DEFINITION: workflows/release.json"))
check("(16) a null clearance gives release", select({"release": {"clearance": None}}), (0, "DEFINITION: workflows/release.json"))
check("(17) a clearance block with no scope gives release", select({"release": {"clearance": {"provider": "github"}}}), (0, "DEFINITION: workflows/release.json"))
for scope, ident in (("release", "release"), ("cut-to-deploy", "release-cut-to-deploy"), ("merge-and-deploy", "release-merge-and-deploy")):
    check("(18) scope %s gives %s (provider shape)" % (scope, ident),
          select({"release": {"clearance": {"provider": "github", "scope": scope}}}), (0, "DEFINITION: workflows/%s.json" % ident))
    check("(19) scope %s gives %s (commands shape)" % (scope, ident),
          select({"release": {"clearance": {"commands": {"claim": "x claim"}, "scope": scope}}}), (0, "DEFINITION: workflows/%s.json" % ident))
rc, out = select({"release": {"clearance": {"provider": "github", "scope": "everything"}}})
check("(20) an unknown scope is a config error naming the key", (rc, out.startswith("CONFIG ERROR: release.clearance.scope"), "everything" in out), (2, True, True))
check("(21) unreadable configuration is a config error", select("{not json")[0], 2)
for scope, ident in (("release", "release"), ("cut-to-deploy", "release-cut-to-deploy"), ("merge-and-deploy", "release-merge-and-deploy")):
    check("(22) the selected file for %s exists and is generated" % scope, ident in PINNED and os.path.isfile(os.path.join(root, "workflows", ident + ".json")))
# --- text parity: every sentence of the old release page lives in exactly one place --------------
# The old page is read at a PINNED base, the last release before the split: the page as that
# release (BASE) published it is kept as a file under scripts/tests/fixtures/release-split-base/,
# so the case reads no git history and needs no network. Nothing is sampled: every sentence
# of the old body of 25 characters or more is accounted for. A floor the entry kept word for word
# must be in exactly one file of the corpus below. A sentence whose step became a workflow step was
# rewritten into that step's reference, in the step's own words: it is listed in MOVED by how it
# began, with the new words that carry its rule and the one file that holds them. A heading, or a
# sentence that only said where a numbered step ran, is listed in RETIRED with what replaced it.
# Nothing else is excused: a sentence in none of the three fails, and so does a key that names no
# sentence of the old page.
import re
BASE = "devstride--v4.7.0"
BASE_DIR = os.path.join(root, "scripts/tests/fixtures/release-split-base")
# The rewritten entry page waits here until the Release workflow is switched on (the header of this
# file says how): the live page, skills/release/SKILL.md, is still the page of BASE.
ENTRY = "scripts/staged/skills/release/SKILL.md"
LIVE = "skills/release/SKILL.md"
flat = lambda t: " ".join(t.split())
R = "skills/release-steps/references/"


def corpus(at):
    """The entry, release-steps and every reference it reads by mode, the seam step skills the
    definitions run, and the two shared deploy steps: flattened, by repository path."""
    paths = [ENTRY, "skills/release-steps/SKILL.md"] + sorted(R + f for f in os.listdir(os.path.join(at, R)) if f.endswith(".md"))
    paths += ["skills/%s/SKILL.md" % s for s in ("classify-release", "pre-ship", "pre-merge-check", "post-deploy")]
    paths += ["skills/hotfix-steps/references/deploy-approval.md", "skills/hotfix-steps/references/deploy-confirm.md"]
    return dict((p, flat(open(os.path.join(at, p), encoding="utf-8").read())) for p in paths)


def sentences(page):
    """The old body as sentences: split at blank lines, list items and headings, then at sentence
    ends; whitespace flattened; anything under 25 characters is too generic to pin."""
    body = page.split("---", 2)[2] if page.startswith("---") else page
    found = []
    for block in re.split(r"\n\s*\n|\n\s*(?:[-*]|\d+\.)\s+|\n#+ ", body):
        for s in re.split(r"(?<=[.!?:;])\s+(?=[A-Z*`\[(])", flat(block)):
            s = re.sub(r"^(?:[-*]|\d+\.)\s+", "", s.strip())
            if len(s) >= 25 and s not in found:
                found.append(s)
    return found


# The opening line every step skill carries too: in the entry, and allowed elsewhere.
SHARED = ["**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it.",
          "Apply it to every message."]
E, PS, CL, PM, PD = ENTRY, "skills/pre-ship/SKILL.md", "skills/classify-release/SKILL.md", "skills/pre-merge-check/SKILL.md", "skills/post-deploy/SKILL.md"
HA, HC = "skills/hotfix-steps/references/deploy-approval.md", "skills/hotfix-steps/references/deploy-confirm.md"
MOVED = {  # how the old sentence began: [(the new words carrying its rule, their one home)]
    "Step 5e runs only after": [("The notes step writes one only after a confirmed merge and live deploy.", E)],
    "**`no docs` / `skip docs`** — suppress step 5c": [("suppress the documentation update and the knowledge-base sync this run.", E)],
    "**`docs only`** / **`release-notes only`** (`post-deploy only`:": [("**`docs only`** / **`release-notes only`** / **`post-deploy only`** — start the partial definition", E)],
    "`clearance.md`) — run 5c / 5e alone": [("against the newest release merge on the production branch: no PR, no merge, no claim, the deploy confirmation included, then stop.", E)],
    "**`backstop`** — the backstop check; release only on START": [("the backstop check, never a workflow step", E), ("Only `START`, after the release-train claim is won, starts a run", E)],
    "**Steps 0–3 run autonomously**": [("**Every step before the owner go-ahead runs autonomously** — the train, the cut, the checks and the review — surfacing only genuine forks", E)],
    "**Docs are on by default and still outward-facing**": [("run only after the deploy is confirmed, suppressed with the knowledge-base sync by \"no docs\".", E)],
    "**A release branch is PROTECTED**": [("never by substring): new commits only — never rebased, amended, force-pushed or `--delete-branch`ed; the `delete-release-branch` step is the one place it is deleted.", E)],
    "**Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-branch.md` when": [("is set** (the train, the cut, the delete, the fix-commit check, hotfixes).", E)],
    "**Clearance first, handed back at 5b**": [("**Clearance first, handed back as the scope says** when `release.clearance` is set.", E)],
    "**Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/clearance.md`": [("before the first step**: the claim (before all but the train claim), `heartbeat <phase>` before each phase's first mutation — exit 4 is a STOP, another session owns this release now — and the hand-back before docs.", E)],
    "`merge-and-deploy` claims only to merge and deploy": [("Scope `merge-and-deploy` claims only to merge and deploy (step 4 to 5a in `clearance.md`'s numbering; a release that must wait then may step aside)", E)],
    "**`claims` set → the train claim first**": [("**Train, then tower: one lock order for every run.**", R + "train-claim.md")],
    "**`needsYou.label` set** → read": [("needs-you.md` now and read the stale notices it describes", R + "ground-truth.md"), ("queues one notice", R + "owner-go-ahead.md")],
    "`releaseSource` (**develop**) → `productionBranch` (**master**)": [("(`master`), whatever branch the checkout is on.", R + "release-shape.md")],
    "An open PR into `productionBranch` headed by a release branch": [("Clean → `ADOPTED`: it is never duplicated.", R + "release-shape.md"), ("**This run's open release → the fix-exclusion check, then adopt.**", R + "release-shape.md")],
    "**Prove CI can stay last before opening anything**": [("This step proves that can hold before any pull request is opened.", R + "ci-hold-proof.md"), ("leaving out the convention-only shape defined", R + "ci-hold-proof.md")],
    "None → a valid no-CI release, said.": [("`NO PULL-REQUEST CI`: a valid release with no CI.", R + "ci-hold-proof.md")],
    "An expensive PR workflow without all draft-hold flags true": [("prove no hold: never open a release on them.", R + "ci-hold-proof.md")],
    "**Ground truth.** Read what OTHER authors": [("Read what OTHER authors landed on both branches since this session last looked", R + "ground-truth.md"), ("→ `ANOTHER SESSION ACTIVE`, saying what was seen.", R + "ground-truth.md")],
    "Clearance** (`release.clearance` set; else skipped, unsaid)": [("No `release.clearance` block → `NOT APPLICABLE`, with nothing more said.", R + "tower-claim.md")],
    "`claim --wait --purpose release`, in the BACKGROUND": [("**Claim in the BACKGROUND with a long timeout**: a call a tool kills yields no verdict, and no verdict is exit `1`.", R + "tower-claim.md"), ("`1`, or no verdict → `ERROR`, a release blocker.", R + "tower-claim.md")],
    "Merge the release train** when `release.mergeTrainBeforeCut`": [("when `release.mergeTrainBeforeCut` is not `true`, when `releaseTrain.branch` is absent", R + "train-finish.md")],
    "`git fetch origin master develop`;": [("A fetch that fails → `FAILED`, naming the command: nothing later may trust a stale ref.", R + "ground-truth.md")],
    "`origin/develop` not ahead of `origin/master`": [("`0` → `NOTHING TO RELEASE`. The run ends; nothing is cut.", R + "release-delta.md")],
    "**No freeze.**": [("**No freeze.** Open pull requests into the source are never settled, parked or waited for", R + "release-delta.md")],
    "**Record `<sourceHead>`**": [("**Record `<sourceHead>`** by the payload's `shape`", R + "release-delta.md")],
    "Every later integrity check compares against it": [("Its `<sourceHead>` is the SHA every later check compares against", R + "release-delta.md")],
    "**Compute the delta**": [("the **user-facing** subset (UI, API, behaviour, permissions, migrations) against the internal rest", R + "release-delta.md")],
    "It drives the PR body and the docs payload": [("it drives the release pull request's body and the documentation plan.", R + "release-delta.md")],
    "`release.classifySkill` unset or unreadable": [("Null or absent → `RELEASE CLASS: FULL`", CL)],
    "A release hold on any item in it": [("Held → `HELD`, naming the item and its reason", R + "release-delta.md"), ("The review checks them again at every recompute.", R + "release-delta.md")],
    "Cut the release branch** when `release.releaseBranchPattern`": [("**Cut** at `<sourceHead>`, read as below, never at a re-read `origin/<releaseSource>`", R + "release-branch.md")],
    "**Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-pr.md` in full before step 1**": [("**Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-pr.md` in full first**", R + "release-pr.md")],
    "`gh pr create --draft --base master": [("`gh pr create [--draft] --base <productionBranch> --head <release branch>`", R + "release-pr.md")],
    "`--head develop`) whenever PR workflows exist": [("(the draft holds CI via `ci.draftGateCondition` until the review's ready flip); none → no `--draft`, said \"no pull-request CI\".", R + "release-pr.md")],
    "Leave cloud requests to `review`": [("Leave cloud review requests to the review", R + "release-pr.md")],
    "`preShipChecks` run in 2b": [("The pre-ship checks and the ready flip are later steps: CI last, once.", R + "release-review.md")],
    "**Never `--delete-branch`** a PR headed by `develop`": [("never `--delete-branch` a pull request headed by the source or a protected branch.", R + "release-pr.md")],
    "Report the PR number and URL.": [("Answer `OPENED #<n>`, with its link and whether it is a draft.", R + "release-pr.md")],
    "**Resolve the delivery profile first**": [("**Resolve the delivery profile first** and pass it by name to `review`", R + "release-review.md")],
    "No plan root; per": [("a bare profile word the run was started with, else config `profile` (unknown:", R + "release-review.md")],
    "`standard`), else `extended`, announced with source.": [("`standard`), else `extended`, announced with its source.", R + "release-review.md")],
    "It never loosens this step (`release-pr.md`)": [("It never loosens this step — unless `release.productionReview` is set", R + "release-review.md")],
    "Invoke **`review`** on the release PR": [("**Invoke `review`, declaring it DRIVEN**, with `review-moment: production-release`", R + "release-review.md")],
    "**Enforce the release-surface scope with that manifest.**": [("Enforce the release-surface scope with that manifest", R + "release-review.md")],
    "**Declare a PRE-SHIP HOLD in that same invocation": [("**Declare a PRE-SHIP HOLD in that same invocation** whenever `pre-ship release select`", R + "release-review.md")],
    "`review` settles, STOPS at its **7.1b**": [("`review` settles, stops at its 7.1b and hands back.", R + "release-review.md")],
    "No such entry → no hold, skip 2c.": [("Neither → `NO HOLD`: the review marked the pull request ready itself.", R + "pre-ship-resume.md")],
    "**Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-gates.md`": [("(why: `release-gates.md`, which `release-pr.md` points to)", R + "release-review.md"), ("it advances only by this run's fix commits and a hotfix merge, each re-reviewed.", R + "release-review.md")],
    "**Re-validate the head IMMEDIATELY before the flip**": [("**Re-validate the head immediately before the flip or the hand-back.**", R + "release-review.md"), ("recomputes the delta and restarts the review on the new head", R + "release-review.md")],
    "Record the SHA that finally settles": [("the SHA that finally settled is `<reviewedHead>`", R + "release-review.md")],
    "Any return to step 2 voids any owner yes given.": [("Any return to this step voids any owner yes already given.", R + "release-review.md")],
    "Only genuinely ambiguous/risky findings stall": [("Only a genuinely ambiguous or risky finding stalls", R + "release-review.md"), ("item when a plan root exists, else it is noted for the owner; never spliced.", R + "release-review.md")],
    "**Do NOT merge here**": [("never spliced. Do NOT merge here.", R + "release-review.md")],
    "Step 4 reports the class.": [("the release class, the pre-ship result, the pre-merge verdict", R + "owner-go-ahead.md")],
    "FAIL` is a STOP**": [("`FAIL` naming EVERY failed entry**", PS)],
    "Never present a release green over a red or unrun check": [("**Never discharge over a red or unrun check.**", R + "pre-ship-resume.md"), ("naming the entry; never \"covered by CI\".", R + "pre-ship-resume.md")],
    "An owner waiver (\"skip <name>\")": [("`--skip <name>` (repeatable, `release` only): the owner's explicit waiver of that entry.", PS)],
    "Discharge the pre-ship hold": [("# Discharge the pre-ship hold — the ready flip, once, after the checks", R + "pre-ship-resume.md")],
    "**Only when step 2 declared a hold.**": [("**Was a hold declared?**", R + "pre-ship-resume.md"), ("**Re-invoke `review` in PRE-SHIP RESUME mode, naming that mode** — a plain re-invocation wrongly restarts cycle 1 — with the same ledger, target and safety triggers.", R + "pre-ship-resume.md")],
    "**Never leave a declared hold undischarged**": [("A declared hold is never left undischarged without saying so", R + "pre-ship-resume.md"), ("that is the owner's decision (a waiver at the pre-ship step)", R + "pre-ship-resume.md")],
    "Documentation — prepare, never publish yet": [("# Plan the documentation — prepare, never publish yet", R + "release-docs-plan.md")],
    "Build the `production-release` payload": [("**Build the `production-release` payload** over `origin/<productionBranch>..<reviewedHead>`", R + "release-docs-plan.md")],
    "**Resolve the documentation plan now**": [("**Resolve each hook** by checking that `.claude/skills/<name>/SKILL.md` exists", R + "release-docs-plan.md")],
    "Never invoke docs before step 5a confirms the deploy.": [("Nothing is invoked or published here: documentation and notes run only after the deploy is confirmed.", R + "release-docs-plan.md")],
    "**Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/merge-and-deploy.md` in full before step 4**": [("\"Step 4 — the human recap\"; the standing yes and the unattended stop are", R + "owner-go-ahead.md")],
    "**Pre-merge production check first**": [("Read `release.preMergeSkill`.", PM)],
    "`HOLD` → STOP before asking": [("`HOLD` stops the release before the go-ahead", PM)],
    "`NOT RUN` → ask whether to proceed;": [("`NOT RUN` asks the owner", PM)],
    "`NOT CONFIGURED` → print **pre-merge production check: not configured**.": [("printed by the release as **pre-merge production check: not configured**", PM)],
    "**Human recap.** Lead with `READY` or `BLOCKED`": [("**Show the recap.** Lead with `READY` or `BLOCKED`, then everything `merge-and-deploy.md` lists", R + "owner-go-ahead.md")],
    "**Then ASK** (standing yes:": [("**The standing yes.**", R + "owner-go-ahead.md"), ("**The owner's yes** is read only from the payload's `answer`", R + "owner-go-ahead.md")],
    "**never proceed without a yes.**": [("**No yes yet** → `NOT YET`, saying what is waited for.", R + "owner-go-ahead.md")],
    "**On a release branch, before merging**": [("`hotfix-catch-up@1` step, run before the recap and the yes.", R + "hotfix-catch-up.md"), ("`REFUSED hotfix landed`", R + "production-merge.md")],
    "**Scope `cut-to-deploy`**: run the previous-release gate": [("`previous-release@1` step: the same step before the recap and again on the yes.", R + "previous-release.md")],
    "`merge-and-deploy`: wait outside the tower, claim on the yes).": [("this session not holding the tower (it waits outside it)", R + "previous-release.md")],
    "**Dev deploy wait**": [("only when a standing yes is configured", R + "dev-deploy-wait.md"), ("only after the owner's own yes", R + "dev-deploy-wait.md")],
    "**On the yes**, after the two above": [("**Confirm, in this order**, stopping at the first that fails", R + "merge-confirmations.md"), ("`review` 7.3's empty re-trigger commit, and a history-only merge of production", R + "merge-confirmations.md")],
    "Then run the `MERGE` line": [("and act only on its `MERGE` line (`MERGE <cmd>`, `REFUSE <reason>` or `ERROR <reason>`): run exactly that command and nothing else.", R + "production-merge.md")],
    "The deploy then runs on its own": [("say it is in flight; never trigger or gate it here.", R + "production-merge.md"), ("Only when the payload's `answer` carries the person's yes for THIS deploy", HA)],
    "Nothing runs before the merge is confirmed": [("nothing public is written about a release whose deploy or health is in question", R + "release-docs.md")],
    "**One session runs 5a–6 in order, one step at a time**": [("**One session runs the release in order, one step at a time**: never resume, re-invoke or message a release session that may still be running so that a second copy starts", E)],
    "**Merge, approve, deploy**": [("`deploy-approval@1` step, shared by every workflow that merges to production.", HA), ("`release.deployVerification` set → run it with `RELEASE_COMMIT=<mergeSha>`", HC)],
    "Unconfirmed → report it and STOP": [("retry every 60 seconds for up to 45 minutes, then `UNCONFIRMED`.", HC)],
    "`merge-and-deploy`: before it; per `clearance.md`): call **`post-deploy check`**": [("Read `release.postDeployCheckSkill`.", PD)],
    "`FAIL` → STOP: surface the evidence": [("never proceed to `sync-production` (default scope), `update-docs` or `release-recap` on your own.", E), ("surface the evidence and ask for a rollback decision;", E)],
    "`NOT RUN` → this-run degradation": [("`NOT RUN` asks whether to proceed", PD)],
    "`NOT CONFIGURED` → the close-out says": [("the recap says **post-deploy health: not configured**", PD)],
    "`git checkout <productionBranch> && git pull --ff-only`": [("**Fresh refs**: `git checkout <productionBranch> && git pull --ff-only`, the release source likewise", R + "release-sync.md")],
    "`heartbeat close-out` first, then `release --owed <item>`": [("send the tower `heartbeat close-out` first", R + "release-sync.md"), ("ONE `release` call, `--owed <item>` repeated for each item", R + "tower-hand-back.md"), ("A repository provider without `commands.owed` gets plain `release`, never `--owed`", R + "tower-hand-back.md")],
    "A FAIL, an unanswered NOT RUN or a stop before here KEEPS clearance.": [("a stop before the hand-back keeps clearance for the retry", R + "tower-hand-back.md")],
    "`merge-and-deploy` handed back at 5a": [("Under `merge-and-deploy` nothing is held: no heartbeat.", R + "release-sync.md"), ("the provider's `owed --done sync`", R + "release-sync.md")],
    "`no docs` → skip this and the sync": [("Print the catch-up whole, because a bare `/devstride:update-docs update` refuses without a payload", R + "release-docs.md")],
    "Otherwise **`update-docs update`** with the completed payload": [("Translate the evidence with pages, branch, pull request and live address exact.", R + "release-docs.md")],
    "Only after `PUBLISHED`, and only with `docs.knowledgeBaseSyncSkill` in the plan": [("The documentation step answered anything but `PUBLISHED`", R + "release-kb-sync.md")],
    "**`sync-knowledge-base sync`** (`docsOutcome": [("never undo or revert the documentation push.", R + "release-kb-sync.md")],
    "Settle or keep `docs` and `knowledge-base` per verdict": [("**Settle by the table**, through the provider's `owed --done <item>`", R + "release-docs.md"), ("`FAILED` → both stay owed", R + "release-docs.md")],
    "After a `CLOSE-OUT OWED` line only": [("only when the health check's evidence ends with a `CLOSE-OUT OWED: <list>` line.", R + "release-close-out.md"), ("An earlier attempt of this step in this run answered `DONE` → `DONE` again, invoking nothing: the close-out runs once.", R + "release-close-out.md")],
    "`DONE` → `owed --done close-out`;": [("`DONE` → the provider's `owed --done close-out` → `DONE`.", R + "release-close-out.md")],
    "`PARTIAL` → report what is left.": [("the evidence names what is left for the recap and the owner.", R + "release-close-out.md")],
    "Release notes — only when asked": [("# Write release notes — only when they were asked for", R + "release-notes.md")],
    "`--release-notes` absent or `false`": [("Absent or `false` → `NOT REQUESTED`, with the evidence line \"release notes: not requested\".", R + "release-notes.md"), ("this step never decides a release deserves one.", R + "release-notes.md")],
    "Otherwise call **`write-release-notes`**": [("It calls the existing step skill **`write-release-notes`** once, in mode `publish` or `draft`.", R + "release-notes.md")],
    "`NOT CONFIGURED` → report it cannot be met and stop": [("say the request cannot be met", R + "release-notes.md"), ("the location and whether it is live or awaiting the owner exact", R + "release-notes.md")],
    "`PUBLISHED`/`DRAFTED` → `owed --done release-notes`;": [("then the provider's `owed --done release-notes`.", R + "release-notes.md")],
    "**Human recap.** Lead with `Merged / Released`": [("**Human recap.** In the plain-language rule's words, leading with `Merged / Released`", R + "release-recap.md"), ("whether the tower was handed back (kept, with the reason, when a check failed or the close-out stopped early)", R + "release-recap.md")],
    "Update any project memory tracking release state": [("Update any project memory that tracks release state", R + "release-recap.md")],
    "Then `release.autoStart.enabled` → its trigger 3": [("`release.autoStart.enabled` and the `claims` block.", R + "auto-start.md"), ("→ `SKIP started at the levelling`", R + "auto-start.md")],
}
# What replaced each: a heading of the old numbered page, or a sentence that only said where a
# numbered step ran, whose order the definitions now carry (pinned by the orderings above).
RETIRED = {
    "Scope `cut-to-deploy` moves 0a, 4 and 5a–5b;": "the order of workflows/release-cut-to-deploy.json",
    "Preconditions and the release delta": "a heading: the start and cut phases",
    "Scope `merge-and-deploy`**: no 0a; the queue": "the order of workflows/release-merge-and-deploy.json",
    "Full gated review-and-settle (`review`)": "a heading: the review phase",
    "**Order**: concurrent review → 2b → the ready-flip": "the review phase's order: release-review, classify-at-pre-ship, pre-ship-release, discharge-hold",
    "Pre-ship checks — the release's mandatory local gates": "a heading: the pre-ship-release step",
    "Run **`classify-release`** again at the head 2b tests": "the steps classify-at-pre-ship and pre-ship-release (step-skills.sh checks each runs its seam skill)",
    "Owner go-ahead → merge to production": "a heading: the go-ahead phase",
    "**`pre-merge-check`** at `<reviewedHead>`.": "the step pre-merge-check, before the go-ahead (step-skills.sh)",
    "After the merge — deploy, health, hand-back, docs, notes": "a heading: the deploy and close-out phases",
    "Confirm the merge, the deploy and its health": "a heading: the steps approve-deploy, confirm-deploy and post-deploy-check",
    "**Post-deploy health** (scope `cut-to-deploy`: after 5b;": "the place of post-deploy-check in each definition's order",
    "Close out inside the clearance, then hand it back": "a heading: the tower-hand-back step",
    "Documentation update — default on when registered": "a heading: the update-docs step",
    "The post-deploy check's close-out": "a heading: the post-deploy-close-out step",
}


def parity(at, old):
    """Every fault in how the old page's sentences are held under `at`; [] when each is held once."""
    texts = corpus(at)
    homes = lambda needle: sorted(p for p, t in texts.items() for _ in range(t.count(needle)))
    faults, used, needles = [], set(), sentences(old)
    for s in needles:
        if s in SHARED:
            if ENTRY not in homes(s):
                faults.append("the entry lost its opening line: " + s)
            continue
        key = [k for k in list(MOVED) + list(RETIRED) if s.startswith(k)]
        if key:
            used.add(key[0])
            continue
        if len(homes(s)) != 1:
            faults.append("in %d places %s: %s" % (len(homes(s)), homes(s), s))
    for key in list(MOVED) + list(RETIRED):
        if key not in used:
            faults.append("names no sentence of the old page: " + key)
    for key, now in sorted(MOVED.items()):
        for needle, home in now:
            if homes(needle) != [home]:
                faults.append("the moved rule is in %s, not once in %s: %s" % (homes(needle), home, needle))
            if home != ENTRY and needle in texts[ENTRY]:
                faults.append("a moved rule is still in the entry: " + needle)
    return sorted(set(faults)), len(needles)


def scratch_copy(change):
    """A copy of the corpus in the work directory, with one change made."""
    scratch_copy.n += 1
    at = os.path.join(tmp, "parity%d" % scratch_copy.n)
    for part in corpus(root):
        os.makedirs(os.path.dirname(os.path.join(at, part)), exist_ok=True)
        shutil.copy(os.path.join(root, part), os.path.join(at, part))
    change(at)
    return at
scratch_copy.n = 0


def rewrite(at, path, change):
    full = os.path.join(at, path)
    text = open(full, encoding="utf-8").read()
    open(full, "w", encoding="utf-8").write(change(text))


OLD = open(os.path.join(BASE_DIR, "release.md"), encoding="utf-8").read() if os.path.isfile(os.path.join(BASE_DIR, "release.md")) else ""
if not OLD:
    check("(24) text parity: the copy of the release page at %s is in %s: never skipped, or this test proves nothing" % (BASE, BASE_DIR), False)
else:
    faults, count = parity(root, OLD)
    check("(24) text parity: each of the %d sentences of the old release page at %s is held once, moved into one step, or retired with what replaced it" % (count, BASE),
          (faults[:12], count >= 140), ([], True))
    scratch = lambda change: parity(scratch_copy(change), OLD)[0]
    check("(25) ... and an untouched scratch copy passes it", scratch(lambda at: None), [])
    KEPT = "Invoking `/devstride:release` is never standing consent for anything else."
    MOVE = "Any return to this step voids any owner yes already given."
    got = scratch(lambda at: rewrite(at, R + "owner-go-ahead.md", lambda t: t + "\n" + KEPT + "\n"))
    check("(26) an entry floor copied into a reference fails it", (len(got), got[0].startswith("in 2 places") if got else False), (1, True))
    got = scratch(lambda at: rewrite(at, ENTRY, lambda t: t.replace("is never standing consent", "is not consent")))
    check("(27) an entry floor reworded fails it", (len(got), got[0].startswith("in 0 places") if got else False), (1, True))
    got = scratch(lambda at: rewrite(at, R + "release-recap.md", lambda t: t + "\n" + MOVE + "\n"))
    check("(28) a moved rule duplicated into a second reference fails it", (len(got), MOVE in got[0] if got else False), (1, True))
    got = scratch(lambda at: rewrite(at, R + "release-review.md", lambda t: t.replace("voids any owner yes already given", "voids the yes")))
    check("(29) a moved rule lost from its reference fails it", (len(got), MOVE in got[0] if got else False), (1, True))
    got = scratch(lambda at: rewrite(at, ENTRY, lambda t: t + "\n" + MOVE + "\n"))
    check("(30) a moved rule copied back into the entry fails it", (len(got) >= 1, any("still in the entry" in g for g in got)), (True, True))

    # The entry keeps the floors spec item 6 names, the loop's four duties, and no numbered step.
    entry = open(os.path.join(root, ENTRY), encoding="utf-8").read()
    FLOORS = ["**Config wins.**", "**Hooks run through step skills**", "**Every step before the owner go-ahead runs autonomously**",
              "**The production merge is a human gate**, except on the owner's standing yes, light or written",
              "**Docs are on by default and still outward-facing**", "**Release notes are NEVER written without `--release-notes`**",
              "**CI last, once.**", "The DevStride MCP targets PRODUCTION", "never force-push either, never `--delete-branch` a PR headed by one",
              "**A release branch is PROTECTED**", "**Every commit added to one first passes the fix-exclusion check**",
              "**Clearance first, handed back as the scope says**", "Never proceed uncleared", "a hotfix never claims",
              "**Untrusted content**", "**One session runs the release in order, one step at a time**", "a stopped one is adopted",
              "**A. Run and forward.**", "**B. Stops.**", "**C. Mixed sessions.**", "**D. The next release, and the owed ones.**",
              "--release-notes <false|true|draft>", "`no docs` / `skip docs`", "**`docs only`** / **`release-notes only`** / **`post-deploy only`**",
              "backstop.py due", "**A bare profile word**", "**`started-by: auto`**", "release.clearance.scope", "## No runner"]
    check("(31) the entry carries every floor, argument and loop duty", [f for f in FLOORS if f not in flat(entry)], [])
    check("(32) the entry has no numbered step left", re.findall(r"^#+ (?:\d+[a-z]?\.|5[a-e]\.)", entry, re.M), [])
    check("(33) the entry body is at most 4,000 tokens (bytes / 3)", (len(entry.encode("utf-8")) + 2) // 3 <= 4000)

# The seam registry's callers name the release's steps, never its old numbered sections: a
# `release <x>` caller is a step id of a release definition, a `release-steps <mode>` caller is a
# mode with its reference, and a `hotfix-steps <mode>` caller a shared step with its reference.
registry = json.load(open(os.path.join(root, "schemas", "seam-registry.json"), encoding="utf-8"))
ids = set(s["id"] for ident in PINNED for _, steps in PINNED[ident] for s in [{"id": x} for x in steps])
callers = [(h["key"], c) for h in registry["hooks"] for c in h.get("calledBy") or []]
wrong = []
# Until the release entry is switched, the live page still calls each seam from its own numbered
# sections, so those callers stay beside the step names; they go with the old page.
live_sections = set(re.findall(r"^#+ (\d+[a-z]?)\.", open(os.path.join(root, LIVE), encoding="utf-8").read(), re.M))
for key, caller in callers:
    parts = caller.split()
    if parts[0] == "release" and ((len(parts) == 2 and parts[1] in live_sections) or caller == "release train step 4b"):
        continue
    if parts[0] == "release" and (len(parts) != 2 or parts[1] not in ids):
        wrong.append("%s: %s" % (key, caller))
    for skill in ("release-steps", "hotfix-steps"):
        if parts[0] == skill and (len(parts) != 2 or not os.path.isfile(os.path.join(root, "skills", skill, "references", parts[1] + ".md"))):
            wrong.append("%s: %s" % (key, caller))
check("(34) every registry caller of the release names a live step or mode (%d callers)" % len([c for c in callers if c[1].split()[0] in ("release", "release-steps")]), wrong, [])
# --- the seam checks are handed real commit ids: each full definition walked through the runner ----
# The class, pre-ship, pre-merge and post-deploy checks read the release's heads, its pull request
# and its class from the results of earlier steps, never from a context nobody fills. Each full
# definition is started through the REAL runner in a throwaway repository and walked to the end
# with scripted answers; every argument and payload those checks are handed is then compared with
# the ids the earlier steps answered.
runner_path = os.path.join(root, "skills", "run-workflow", "scripts", "workflow.py")
catalog = json.load(open(os.path.join(root, "schemas", "step-contracts.json"), encoding="utf-8"))["contracts"]
SRC, PROD, SNAP, TIP, PTIP, REV, MERGE = ("%040x" % n for n in (0xa1, 0xb2, 0xc3, 0xd4, 0xe5, 0xf6, 0x17))
RAN = "--ran-at-train e2e@" + SNAP
SCRIPTED = {
    "release-shape@1": ("RELEASE SHAPE: NEW", {"shape": "NEW", "pullRequest": None, "branch": None}),
    "release-delta@1": ("RELEASE DELTA: ITEMS 3", {"state": "items", "sourceHead": SRC, "productionHead": PROD}),
    "train-snapshot@1": ("TRAIN SNAPSHOT: CUT test/release-train", {"state": "cut", "head": SNAP, "sourceBefore": SRC}),
    "train-pre-ship@1": ("PRE-SHIP: PASS", {"state": "pass", "ranAtTrain": RAN}),
    "release-pr@1": ("RELEASE PR: OPENED 42", {"state": "opened", "pullRequest": 42}),
    "release-tip@1": ("PRODUCTION TIP: AT " + PTIP, {"state": "at", "head": TIP, "productionTip": PTIP}),
    "release-review@1": ("RELEASE REVIEW: SETTLED " + REV, {"state": "settled", "reviewedHead": REV}),
    "production-merge@1": ("PRODUCTION MERGE: MERGED " + MERGE, {"sha": MERGE, "pullRequest": 42}),
    "deploy-approval@1": ("DEPLOY APPROVAL: APPROVED", {"mergeSha": MERGE, "approved": True}),
    "deploy-confirm@1": ("DEPLOY: CONFIRMED " + MERGE, {"mergeCommit": MERGE, "confirmedAt": "2026-11-21T19:00:00Z"}),
}
FILL = {"string": "x", "number": 1, "boolean": True, "number|null": None, "string|null": None}

def scripted(contract):
    entry = catalog[contract]
    if contract in SCRIPTED:
        verdict, result = SCRIPTED[contract]
    else:
        value = next(v for v in entry["verdict"]["values"] if v["class"] == "continue")
        verdict = "%s: %s%s" % (entry["verdict"]["label"], value["value"], " 1" if value["detail"] == "required" else "")
        result = dict((k, "light" if entry["builtinSkill"] == "classify-release" else FILL[entry["result"]["types"][k]])
                      for k in entry["result"]["required"])
    return "%s\nevidence line\n```json\n%s\n```\n" % (verdict, json.dumps(result))

def walk(ident):
    repo, cache = os.path.join(tmp, "walk-" + ident), os.path.join(tmp, "cache-" + ident)
    os.makedirs(repo); os.makedirs(cache)
    for args in (["init", "-q", "-b", "main"], ["-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false",
                                                "commit", "-q", "--allow-empty", "-m", "first"]):
        subprocess.run(["git", "-C", repo] + args, check=True, capture_output=True)
    env = dict(os.environ, XDG_CACHE_HOME=cache)
    for name in ("CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID", "GIT_DIR", "GIT_WORK_TREE"):
        env.pop(name, None)
    def call(command, request):
        if command == "start":
            request = dict(request, rehearsal=True)  # the release's step skill is not switched on yet: these walks are rehearsals
        done = subprocess.run([sys.executable, "-B", runner_path, command], input=json.dumps(dict(request, session="walk")),
                              capture_output=True, text=True, env=env, cwd=repo)
        return json.loads(done.stdout) if done.returncode == 0 else {"action": "error", "why": done.stdout + done.stderr}
    context = {"item": None, "productionBranch": "main", "releaseSource": "develop", "scope": "release", "startedBy": "person",
               "releaseNotes": "draft", "noDocs": False, "profile": {"name": "extended", "source": "config"},
               "rerunAtMerge": "e2e", "cwd": repo}
    answer = call("start", {"definitionFile": os.path.join(root, "workflows", ident + ".json"), "context": context})
    handed = {}
    while answer.get("action") == "run" and len(handed) < 200:
        step = answer["step"]
        handed[step["id"]] = (step["contract"], answer["payload"], answer["argument"])
        answer = call("done", {"stepId": step["id"], "attempt": step["attempt"], "output": scripted(step["contract"])})
    return answer, handed

def seam_faults(handed):
    faults = []
    def want(step_id, got, expected):
        if got != expected:
            faults.append("%s: %r, want %r" % (step_id, got, expected))
    for step_id, (contract, payload, argument) in handed.items():
        skill = catalog[contract]["builtinSkill"]
        if skill in ("classify-release", "pre-merge-check"):
            want(step_id + " shape", payload.get("shape"), "NEW")
        if contract == "classify-release@1":
            want(step_id, payload.get("head"), SRC)
        elif contract == "classify-at-checks@1":
            want(step_id, payload.get("head"), TIP)
        elif contract == "classify-at-pre-ship@1":
            want(step_id, payload.get("head"), REV)
        elif contract == "train-pre-ship@1":
            want(step_id, argument, "train run %s %s --shape NEW" % (SRC, SNAP))
        elif contract == "pre-ship-at-checks@1":
            want(step_id, argument, "release run %s %s light --shape NEW" % (PTIP, TIP))
        elif contract == "pre-ship-release@1":
            want(step_id, argument, "release run %s %s light %s --shape NEW" % (PROD, REV, RAN))
        elif contract == "rerun-at-merge@1":
            want(step_id, argument, "release run %s %s light --only e2e --shape NEW" % (PROD, REV))
        elif contract == "pre-merge-at-checks@1":
            want(step_id, (payload.get("head"), payload.get("pullRequest")), (TIP, 42))
        elif skill == "pre-merge-check":
            want(step_id, (payload.get("head"), payload.get("pullRequest")), (REV, 42))
        elif skill == "post-deploy":
            first, _, rest = argument.partition("\n")
            block = json.loads(rest.strip().strip("`").replace("json\n", "", 1)) if rest else None
            want(step_id, (first, block), ("check", {"productionBranch": "main", "mergeCommit": MERGE, "deployConfirmedAt": "2026-11-21T19:00:00Z"}))
        elif contract == "release-review@1":
            want(step_id, payload.get("profile"), context_profile)
        elif contract in ("release-docs-plan@1", "release-notes@1"):
            want(step_id, (payload.get("releaseNotes"), payload.get("noDocs", False)), ("draft", False))
    return faults

context_profile = {"name": "extended", "source": "config"}
SEAMS = ("classify-release", "pre-ship", "pre-merge-check", "post-deploy")
for ident in ("release", "release-cut-to-deploy", "release-merge-and-deploy"):
    end, handed = walk(ident)
    check("(35) %s: a scripted walk reaches the end through the runner" % ident, (end.get("action"), end.get("outcome")), ("finished", "completed"))
    read = lambda c: catalog[c]["builtinSkill"] in SEAMS or c in ("release-review@1", "release-docs-plan@1", "release-notes@1")
    steps = [s for p in json.load(open(os.path.join(root, "workflows", ident + ".json")))["phases"] for s in p["steps"] if read(s["contract"])]
    unreached = [s["id"] for s in steps if s["id"] not in handed]
    check("(36) %s: every check is handed real commit ids, the pull request and the class (%d steps)" % (ident, len(steps)),
          seam_faults(handed) + ["%s: never handed out" % s for s in unreached], [])
PY
PRC=$?; OUT="$(cat "$T/cases.out")"
echo "$OUT" | sed 's/^ok   /  ok   /; s/^FAIL /  FAIL /'
echo "$OUT" | grep -q '^FAIL' && FAIL=1
[ "$PRC" -eq 0 ] || bad "(0) the Python cases crashed (exit $PRC)"

# --- replays: the release's start, train, cut, queue and adoption through the REAL runner -----------
# Each scenario in scripts/tests/fixtures/workflow-release/ is a transcript written from today's
# step references: the steps in the order they run, each with the verdict line and result it
# answers, the owner's answers to its stops, and what the run must come to. The shared driver
# (scripts/tests/fixtures/workflow-replay.py) starts the runner in a throwaway repository, feeds it
# the transcript and fails unless the runner issues exactly that order, stops exactly there and
# ends with that outcome. The properties below are then read off the transcripts the runner just
# matched: where each scope puts the tower claim and the pending status, the tower heartbeat
# phases, the shapes' answers. Last, copies of the full definitions with a required step removed,
# switched off, carrying on after a failure or moved past the production merge are refused.
python3 - "$ROOT" "$T" > "$T/replays.out" <<'PY'
import copy, json, os, re, shutil, subprocess, sys
root, tmp = sys.argv[1], sys.argv[2]
fixtures = os.path.join(root, "scripts", "tests", "fixtures", "workflow-release")
driver = os.path.join(root, "scripts", "tests", "fixtures", "workflow-replay.py")
runner = os.path.join(root, "skills", "run-workflow", "scripts", "workflow.py")

def check(name, got, want=True):
    print(("ok   " if got == want else "FAIL ") + name + ("" if got == want else " — got %r, want %r" % (got, want)))

def replay(path):
    done = subprocess.run([sys.executable, driver, root, path], capture_output=True, text=True)
    return done.returncode, (done.stdout + done.stderr).strip()

def load(name):
    return json.load(open(os.path.join(fixtures, name + ".json"), encoding="utf-8"))

def steps_of(ident):
    d = json.load(open(os.path.join(root, "workflows", ident + ".json"), encoding="utf-8"))
    return [s["id"] for p in d["phases"] for s in p["steps"]]

SCENARIOS = ["nothing-to-release", "nothing-to-release-m", "standard-release", "standard-cut-to-deploy",
             "standard-merge-and-deploy", "adopted-release-branch", "adopted-merged-release", "queue-wait-then-clear",
             "queue-ask-then-clear", "queue-ask-session-stopped", "queue-timed-out", "production-behind-at-cut",
             "production-behind-conflict", "late-arrival-restarts"]
present = sorted(f[:-5] for f in os.listdir(fixtures) if f.endswith(".json"))
check("(40) the replay scenarios are all there", [s for s in SCENARIOS if s not in present], [])
for name in present:
    rc, out = replay(os.path.join(fixtures, name + ".json"))
    check("(41) replay %s: %s" % (name, out if rc == 0 else "through the real runner"), (rc, out if rc else ""), (0, ""))

first = lambda s: [sid for sid, n in s["expect"]["order"] if n == 1]
issued = lambda s: [sid for sid, _ in s["expect"]["order"]]
said = lambda s, sid: [e["output"].split("\n", 1)[0] for e in s["script"] if e["step"] == sid]
SCOPES = {"release": "release", "cut-to-deploy": "release-cut-to-deploy", "merge-and-deploy": "release-merge-and-deploy"}

# Nothing to release: the run ends at release-delta, under the default scope after the tower claim,
# under merge-and-deploy before any tower claim; the train claim goes with the run's end.
for name, ident in (("nothing-to-release", "release"), ("nothing-to-release-m", "release-merge-and-deploy")):
    s = load(name)
    order = steps_of(ident)
    check("(42) %s: every step up to release-delta once, then nothing" % name,
          (issued(s), s["expect"]["outcome"]), (order[:order.index("release-delta") + 1], "nothing-to-release"))
check("(43) under merge-and-deploy nothing to release never claims the tower", "tower-claim" in issued(load("nothing-to-release-m")), False)
auto_start = " ".join(open(os.path.join(root, "skills/release/references/auto-start.md"), encoding="utf-8").read().split())
check("(44) the page releases the train claim when the whole run ends with nothing to ship",
      "Released early only when the whole run ends: nothing to ship at all, or stopped." in auto_start)

# The standard hand start, the same shape under every scope: every step once in the pinned order
# (the definition file, which (2) holds to the pinned list), the owner's yes a stop at go-ahead,
# and nothing that merges issued before the answer.
for scope, ident in SCOPES.items():
    s = load("standard-" + scope)
    order = issued(s)
    check("(45) %s: the steps run in the pinned order, each once (go-ahead twice, for the yes)" % scope, first(s), steps_of(ident))
    check("(46) %s: the owner's yes is the one stop, at go-ahead" % scope, (s["expect"]["stops"], s["answers"]), (["go-ahead"], ["yes, merge it"]))
    yes = order.index("go-ahead") + 1
    check("(47) %s: go-ahead is issued again only on the answer, and the merge after it" % scope,
          (order[yes], order.index("production-merge") > yes, "production-merge" not in order[:yes]), ("go-ahead", True, True))
# Where the tower claim sits: right after the train claim (S), just before the cut (C), at the
# final gate after the yes and the final queue read (M).
S, C, M = (issued(load("standard-" + k)) for k in SCOPES)
check("(48) S: the tower is claimed right after the train claim", S[S.index("train-claim") + 1], "tower-claim")
check("(49) C: the tower is claimed just before the cut, after the class", (C[C.index("tower-claim") - 1], C[C.index("tower-claim") + 1]),
      ("classify-release", "cut-branch"))
check("(50) M: the tower is claimed once, at the final gate, after the yes and the final queue read",
      (M.count("tower-claim"), M[M.index("tower-claim") - 1], M.index("tower-claim") > len(M) - 1 - M[::-1].index("go-ahead"),
       M.index("tower-claim") > M.index("open-release-pr")), (1, "queue-final", True, True))
# The pending status: none under S, just before the hand-back under C, right after the merge under M.
check("(51) S posts no pending status", "post-pending-status" in S, False)
check("(52) C posts the pending status just before the hand-back", C[C.index("post-pending-status") + 1], "tower-hand-back")
check("(53) M posts the pending status right after the merge", M[M.index("production-merge") + 1], "post-pending-status")

# Tower heartbeats: phases only from RELEASE_PHASES (the tower provider's one list of release
# phases, which a phase budget is looked up by), each sent by the step the map in resume-rules.md
# names, in the release's order; under merge-and-deploy none before the final claim.
RELEASE_PHASES = ["claimed", "train", "cut", "pr", "review", "pre-ship", "final", "merging", "deploy", "close-out"]
ALL = set(SCOPES)
PHASE_MAP = [("train", "train-finish-earlier", {"release"}), ("cut", "cut-branch", {"release", "cut-to-deploy"}),
             ("pr", "open-release-pr", {"release", "cut-to-deploy"}), ("review", "release-review", ALL),
             ("pre-ship", "pre-ship-release", ALL), ("final", "go-ahead", ALL), ("final", "tower-claim", {"merge-and-deploy"}),
             ("merging", "merge-confirmations", ALL), ("deploy", "production-merge", ALL), ("close-out", "sync-production", {"release", "cut-to-deploy"})]
flat = lambda p: " ".join(open(os.path.join(root, p), encoding="utf-8").read().split())
rules = flat("skills/release-steps/references/resume-rules.md")
segment = rules[rules.index("Phases come only from this map:"):rules.index("**The train claim**")]
named = re.findall(r"`([a-z-]+)(?: --[a-z]+ <[a-z]+>)?` (?:in|after)\b", segment)
check("(54) resume-rules.md's phase map names exactly the pinned phases, all among RELEASE_PHASES",
      (named, [p for p in named if p not in RELEASE_PHASES]), (list(dict.fromkeys(p for p, _, _ in PHASE_MAP)), []))
REFS = os.path.join(root, "skills", "release-steps", "references")
# Each step's own text, by its mode (the contract name less the major): release-steps' references,
# and the release's pre-ship step, whose heartbeat the step-skill rule carries.
TEXT = dict((f[:-3], "skills/release-steps/references/" + f) for f in sorted(os.listdir(REFS)))
TEXT.update({"pre-ship-release": "skills/release/references/step-skills.md"})
sent = {}
for m, f in TEXT.items():
    for a, b in re.findall(r"`heartbeat ([a-z-]+)|[Hh]eartbeat `([a-z-]+)", open(os.path.join(root, f), encoding="utf-8").read()):
        sent.setdefault(a or b, set()).add(m)
check("(55) every tower heartbeat a step's text sends is among RELEASE_PHASES", sorted(p for p in sent if p not in RELEASE_PHASES), [])
mode = dict((s["id"], s["contract"].split("@")[0]) for i in SCOPES.values()
            for p in json.load(open(os.path.join(root, "workflows", i + ".json"), encoding="utf-8"))["phases"] for s in p["steps"])
wrong = sorted("%s sent by %s" % (p, sorted(m)) for p, m in sent.items() for x in m
               if not any(p == q and mode[sid] == x for q, sid, _ in PHASE_MAP))
check("(56) each one is sent only by a step the phase map names for it", wrong, [])
check("(79) every phase in the map is sent by the step the map names for it",
      sorted("%s by %s" % (p, sid) for p, sid, _ in PHASE_MAP if mode[sid] not in sent.get(p, set())), [])
for scope, order in (("release", S), ("cut-to-deploy", C), ("merge-and-deploy", M)):
    beats = [(order.index(sid), p) for p, sid, scopes in PHASE_MAP if scope in scopes]
    check("(57) %s: the replayed order reaches the heartbeat phases in the release's order" % scope,
          [p for _, p in sorted(beats)], [p for _, p in sorted(beats, key=lambda b: (RELEASE_PHASES.index(b[1]), b[0]))])
before = [sid for p, sid, scopes in PHASE_MAP if "merge-and-deploy" in scopes and M.index(sid) < M.index("tower-claim")]
held = "only when this session holds the tower"
check("(58) M: every step before the final claim that could heartbeat sends it only while the tower is held",
      [sid for sid in before if mode[sid] in sent.get(dict((s, p) for p, s, _ in PHASE_MAP)[sid], set())
       and held not in flat(TEXT[mode[sid]])], [])
check("(59) ... the shared rule: no record before the final claim, nothing sent; the first tower heartbeat is final",
      ("No record means nothing is held (scope `merge-and-deploy` before the final claim) and nothing is sent" in rules,
       "`review` and `pre-ship` are never heartbeated here; the first is `final`" in flat("skills/release/references/clearance.md"),
       "followed at once by `heartbeat final`" in flat("skills/release-steps/references/tower-claim.md")), (True, True, True))

# Shapes. ADOPTED: nothing of the train or the cut runs again, and the review gets the open pull
# request. MERGED: nothing is cut, reviewed or merged again, and the run goes on to the deploy.
TRAIN = ["train-finish-earlier", "ship-plan", "train-snapshot", "train-pr", "train-review", "train-pre-ship", "train-merge",
         "train-close-out", "train-level"]
s = load("adopted-release-branch")
check("(60) adopted branch: every train step answers NOT APPLICABLE (the train pre-ship NOTHING TO RUN)",
      [sid for sid in TRAIN if not re.search(r": (NOT APPLICABLE|NOTHING TO RUN)$", said(s, sid)[0])], [])
check("(61) adopted branch: cut-branch and open-release-pr answer ADOPTED", [said(s, x)[0].split(": ")[1].split()[0] for x in ("cut-branch", "open-release-pr")],
      ["ADOPTED", "ADOPTED"])
check("(62) adopted branch: the review is handed the open pull request",
      s["expect"]["handed"]["release-review"]["payload"]["shape"]["pullRequest"], 41)
s = load("adopted-merged-release")
MERGED_AT = "%040x" % 0x17  # the merge commit the scenario's merged release names
order = issued(s)
span = order[order.index("release-delta"):order.index("production-merge") + 1]
ALREADY = r": (NOT APPLICABLE|NOTHING TO RUN|ADOPTED \S+|NO HOLD|NOT GATED|NONE|UNCHANGED|STAMPED none|YES \(already merged\) 41|SETTLED [0-9a-f]{40}|HEAD [0-9a-f]{40}|MERGED 41|ITEMS \d+|CLEARED|AT [0-9a-f]{40}|HOOKS \d+)$"
check("(63) adopted merged: from release-delta through production-merge nothing is cut, opened, reviewed anew or merged",
      [x for x in span if not re.search(ALREADY, said(s, x)[0]) or re.search(r": (CUT|OPENED)\b", said(s, x)[0])], [])
check("(63b) adopted merged: the pre-ship, pre-merge and class steps are handed the shape and run nothing",
      [x for x in order if x.startswith(("pre-ship", "rerun-at-merge", "pre-merge", "classify", "train-pre-ship"))
       and not said(s, x)[0].endswith(": NOT APPLICABLE")], [])
check("(64) adopted merged: the review, the go-ahead, the merge confirmations and the merge name the release already merged",
      [said(s, x)[0] for x in ("release-review", "go-ahead", "merge-confirmations", "production-merge")],
      ["RELEASE REVIEW: SETTLED " + MERGED_AT, "GO-AHEAD: YES (already merged) 41", "MERGE CONFIRMED: HEAD " + MERGED_AT,
       "PRODUCTION MERGE: MERGED 41"])
check("(65) adopted merged: the run goes on at the pending status, the deploy and the close-out",
      order[order.index("production-merge") + 1:order.index("production-merge") + 4] + [order[-1]],
      ["post-pending-status", "approve-deploy", "confirm-deploy", "auto-start-next"])
check("(66) adopted merged: the train steps are NOT APPLICABLE too", [sid for sid in TRAIN if not re.search(r": (NOT APPLICABLE|NOTHING TO RUN)$", said(s, sid)[0])], [])

# The queue, production behind, late arrivals.
q = dict((n, load(n)) for n in ("queue-wait-then-clear", "queue-ask-then-clear", "queue-ask-session-stopped", "queue-timed-out"))
check("(67) queue WAIT: waits inside the step, never a stop, then cuts", (q["queue-wait-then-clear"]["expect"]["waits"], q["queue-wait-then-clear"]["expect"]["stops"],
      issued(q["queue-wait-then-clear"])[issued(q["queue-wait-then-clear"]).index("queue") + 1]), (3, [], "cut-branch"))
check("(68) queue ASK: one stop, then it keeps waiting without asking again, then cuts",
      (q["queue-ask-then-clear"]["expect"]["stops"], said(q["queue-ask-then-clear"], "queue")[1], "cut-branch" in issued(q["queue-ask-then-clear"])),
      (["queue"], "QUEUE: CLEAR", True))
check("(69) queue: a WAIT after the owner's answer, or TIMED OUT, stops naming the pull request ahead and cuts nothing",
      [("cut-branch" in issued(q[n]), q[n]["expect"]["stopReasons"][-1]) for n in ("queue-ask-session-stopped", "queue-timed-out")],
      [(False, "QUEUE: WAIT 41"), (False, "QUEUE: TIMED OUT 41")])
s = load("production-behind-at-cut")
check("(70) production behind: merged into the release branch before the pull request opens",
      (said(s, "production-in-branch")[0].split(": ")[1].split()[0], issued(s).index("production-in-branch") < issued(s).index("open-release-pr")), ("MERGED", True))
check("(71) production behind with a conflict: stops before any pull request", "open-release-pr" in issued(load("production-behind-conflict")), False)
s = load("late-arrival-restarts")
check("(72) late arrivals restart: three absorbs re-issue the train review, the fourth issue settles",
      ([n for sid, n in s["expect"]["order"] if sid == "train-review"], said(s, "train-review")[-1].split(": ")[1].split()[0]), ([1, 2, 3, 4], "SETTLED"))
review = flat("skills/release-steps/references/train-review.md")
check("(73) ... the step's text caps the restarts at three and leaves later landings to the next release",
      ("fewer than three absorbs are on the snapshot" in review, "The third absorb's run, and the first ready flip, end the window: later landings ship next time" in review), (True, True))
check("(74) ... and offer absorbs only on the owner's instruction, inside the step",
      "absorb only on the owner's instruction in this session, and only before the ready flip" in review)

# The driver itself fails a transcript the runner does not follow.
base = os.path.join(fixtures, "queue-ask-then-clear.json")
def broken(change):
    s = json.load(open(base, encoding="utf-8")); change(s)
    path = os.path.join(tmp, "broken.json"); json.dump(s, open(path, "w", encoding="utf-8"))
    return replay(path)[0]
check("(75) the driver fails a transcript whose order the runner does not follow",
      broken(lambda s: s["expect"]["order"].__setitem__(0, ["classify-release", 1])), 1)
check("(76) ... a wrong wait count, stop reason or handed payload",
      [broken(lambda s: s["expect"].__setitem__("waits", 1)), broken(lambda s: s["expect"].__setitem__("stopReasons", ["42"])),
       broken(lambda s: s["expect"]["handed"]["queue#2"]["payload"].__setitem__("answer", "go"))], [1, 1, 1])

# Required steps cannot be authored away: the review, the release pre-ship, the go-ahead (every
# step of it) and the merge confirmations, removed, switched off, carrying on after a failure or
# moved past the production merge, in a copy of each full definition, are refused (exit 2).
repo = os.path.join(tmp, "required-repo")
os.makedirs(repo)
for args in (["init", "-q", "-b", "main"], ["-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false",
                                            "commit", "-q", "--allow-empty", "-m", "first"]):
    subprocess.run(["git", "-C", repo] + args, check=True, capture_output=True)
env = dict(os.environ, XDG_CACHE_HOME=os.path.join(tmp, "required-cache"))
for name in ("CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID", "GIT_DIR", "GIT_WORK_TREE"):
    env.pop(name, None)
def start(definition, n):
    context = {"item": None, "productionBranch": "main", "releaseSource": "develop", "scope": "release", "startedBy": "person",
               "releaseNotes": "false", "noDocs": False, "profile": {"name": "extended", "source": "config"}, "cwd": repo}
    done = subprocess.run([sys.executable, "-B", runner, "start"], capture_output=True, text=True, env=env, cwd=repo,
                          input=json.dumps({"definition": definition, "context": context, "session": "required-%d" % n, "rehearsal": True}))
    return done.returncode, done.stderr.strip()
# Each step carrying a required contract is edited on its own, so a definition that carries the
# contract twice cannot lose one of the two unnoticed: under merge-and-deploy the go-ahead is the yes
# before the tower (owner-go-ahead@1) and the recheck at the final gate (owner-go-ahead-recheck@1),
# which requires the first; the merge confirmations need a go-ahead given after the tower claim.
REQUIRED = ("release-review@1", "pre-ship-release@1", "owner-go-ahead@1", "owner-go-ahead-recheck@1", "merge-confirmations@1")
EDITS = {"removed": ("requires-missing", "requires-not-after"), "off": ("required-off",), "continue": ("required-not-stop", "unsupported-on-fail"),
         "after the merge": ("requires-not-earlier", "requires-not-after")}
n, faults, edited = 0, [], {}
for ident in SCOPES.values():
    original = json.load(open(os.path.join(root, "workflows", ident + ".json"), encoding="utf-8"))
    n += 1
    if start(original, n)[0] != 0:
        faults.append("%s: the unedited copy is refused" % ident)
    for contract in REQUIRED:
        ids = [s["id"] for p in original["phases"] for s in p["steps"] if s["contract"] == contract]
        edited[(ident, contract)] = ids
        for sid in ids:
            for how in EDITS:
                d = copy.deepcopy(original)
                phase, step = next((p, s) for p in d["phases"] for s in p["steps"] if s["id"] == sid)
                if how == "removed":
                    phase["steps"].remove(step)
                elif how == "off":
                    step["run"] = {"source": "off", "ref": None, "version": None}
                elif how == "continue":
                    step["onFail"] = "continue"
                else:
                    phase["steps"].remove(step)
                    holder = next(p for p in d["phases"] if any(x["id"] == "production-merge" for x in p["steps"]))
                    holder["steps"].insert([x["id"] for x in holder["steps"]].index("production-merge") + 1, step)
                n += 1
                rc, err = start(d, n)
                refusal = re.match(r"workflow: ([a-z-]+):", err)
                if rc != 2 or not refusal or refusal.group(1) not in EDITS[how]:
                    faults.append("%s with step %s (%s) %s: exit %d, %s" % (ident, sid, contract, how, rc, err or "accepted"))
check("(78) every required contract is carried where it should be: once in each scope, the recheck only under merge-and-deploy",
      dict((k, len(v)) for k, v in edited.items()),
      dict((k, 0 if k[1] == "owner-go-ahead-recheck@1" and k[0] != "release-merge-and-deploy" else 1) for k in edited))
check("(77) a copy with any one required step removed, switched off, carrying on or moved past the merge is refused (exit 2), %d copies" % (n - 3), faults, [])
PY
PRC=$?; OUT="$(cat "$T/replays.out")"
echo "$OUT" | sed 's/^ok   /  ok   /; s/^FAIL /  FAIL /'
echo "$OUT" | grep -q '^FAIL' && FAIL=1
[ "$PRC" -eq 0 ] || bad "(39) the replay cases crashed (exit $PRC)"

# --- replays, part two: the go-ahead, the merge, the deploy, health, documents, notes, partials ---
# The scenarios below were replayed with the rest at (41); here the properties each one exists for
# are read off the transcripts the runner just matched, beside the words of the step that answers
# that way (each phrase pinned is in exactly one place: the text-parity test above holds it).
# Then, driven inline through the real runner: two release runs in one session (auto start), the
# backstop creating no run, the durable records a mixed fleet shares, and a forwarding failure.
python3 - "$ROOT" "$T" > "$T/replays2.out" <<'PY'
import json, os, re, subprocess, sys
root, tmp = sys.argv[1], sys.argv[2]
fixtures = os.path.join(root, "scripts", "tests", "fixtures", "workflow-release")
runner = os.path.join(root, "skills", "run-workflow", "scripts", "workflow.py")

def check(name, got, want=True):
    print(("ok   " if got == want else "FAIL ") + name + ("" if got == want else " — got %r, want %r" % (got, want)))

load = lambda n: json.load(open(os.path.join(fixtures, n + ".json"), encoding="utf-8"))
issued = lambda s: [sid for sid, _ in s["expect"]["order"]]
said = lambda s, sid: [e["output"].split("\n", 1)[0] for e in s["script"] if e["step"] == sid]
attempts = lambda s, sid: [n for x, n in s["expect"]["order"] if x == sid]
flat = lambda p: " ".join(open(os.path.join(root, p), encoding="utf-8").read().split())
ref = lambda mode: flat("skills/release-steps/references/%s.md" % mode)
steps_of = lambda i: [s["id"] for p in json.load(open(os.path.join(root, "workflows", i + ".json"), encoding="utf-8"))["phases"] for s in p["steps"]]
none_of = lambda s, ids: [x for x in ids if x in issued(s)]
MERGING = ["pre-merge-check", "go-ahead", "merge-confirmations", "production-merge"]
AFTER_DEPLOY = ["post-deploy-check", "update-docs", "sync-knowledge-base", "write-release-notes"]

SECOND = ["hotfix-merged-mid-review", "hotfix-same-tree", "head-moved-restarts", "head-moved-exhausted",
          "stamp-changed-at-final-gate", "stamp-behind-at-final-gate", "stamp-error-at-final-gate", "checks-stamp-rebuilds",
          "standing-yes-merge", "standing-yes-ask", "previous-release-pending-c", "previous-release-pending-m",
          "previous-release-failed-override", "previous-release-recheck-steps-aside", "merge-not-confirmed",
          "production-merge-refused", "merge-same-tree-advance", "deploy-approval-not-configured",
          "deploy-approval-retry-then-stops", "deploy-approval-waits-for-yes", "deploy-unconfirmed", "deploy-hand-back-m",
          "health-fail-s", "health-not-run-accepted-s", "health-not-run-declined-s", "health-fail-c", "health-fail-m",
          "health-not-run-yes-c", "health-not-run-yes-m", "health-not-run-no-c", "health-not-run-no-m", "health-not-configured-c",
          "docs-published", "docs-current", "docs-staged", "docs-failed", "docs-not-configured", "docs-suppressed",
          "notes-drafted", "notes-published", "notes-failed", "partial-post-deploy", "partial-docs", "partial-notes", "partial-none"]
present = set(f[:-5] for f in os.listdir(fixtures) if f.endswith(".json"))
check("(80) the second set of replay scenarios is all there (%d)" % len(SECOND), [s for s in SECOND if s not in present], [])

# A hotfix landing mid-review. The tree changed: the run goes back to the review, and the review,
# the pre-ship checks and the discharge run again before the recap, the yes and the merge; the
# catch-up then finds production already in. The same tree needs no review.
s = load("hotfix-merged-mid-review")
order, back = s["expect"]["order"], s["expect"]["order"].index(["hotfix-catch-up", 1]) + 1
check("(81) hotfix MERGED: the run goes back to the review, then the pre-ship checks, the discharge and the catch-up again",
      (order[back:back + 6], said(s, "hotfix-catch-up")),
      ([[x, 2] for x in ("release-review", "classify-at-pre-ship", "pre-ship-release", "discharge-hold", "docs-plan", "hotfix-catch-up")],
       ["HOTFIX CATCH-UP: MERGED 77", "HOTFIX CATCH-UP: NONE"]))
check("(81a) ... nothing that asks or merges comes before the second review, and the merge confirms the newly reviewed head",
      (none_of(dict(s, expect=dict(s["expect"], order=order[:back])), MERGING), s["expect"]["outcome"],
       s["expect"]["handed"]["merge-confirmations"]["payload"]["releaseReview"]["reviewedHead"]),
      ([], "completed", "%040x" % 0xf7))
hf = ref("hotfix-catch-up")
check("(82) ... its step says the runner sends the run back to the review and any yes already given is void, and its contract rewinds there",
      ("The runner sends the run back to the review because the review must run again" in hf, "Any owner yes already given is void" in hf,
       [v["class"] for v in json.load(open(os.path.join(root, "schemas", "step-contracts.json"), encoding="utf-8"))["contracts"]["hotfix-catch-up@1"]["verdict"]["values"] if v["value"] == "MERGED"]),
      (True, True, ["rewind:release-review@1"]))
s = load("hotfix-same-tree")
check("(83) hotfix SAME TREE: no review again, the yes and the merge follow on the new head",
      (attempts(s, "release-review"), said(s, "merge-confirmations"), "production-merge" in issued(s), "No review is needed" in hf),
      ([1], ["MERGE CONFIRMED: HEAD " + "%040x" % 0x4e], True, True))

# Head moved before the flip: the review restarts on its own, never a stop, and nothing after it
# runs until it settles; a head that never stops moving meets the review contract's limit of eight
# requests to run again (maxAutoRedo), the eighth of which stops the run.
s = load("head-moved-restarts")
check("(84) head moved: seven automatic re-issues of the review, no stop, then the pre-ship checks",
      (attempts(s, "release-review"), s["expect"]["stops"], issued(s)[8]), (list(range(1, 9)), [], "classify-at-pre-ship"))
rr = ref("release-review")
check("(85) ... its step recomputes the delta and restarts the review, voiding any yes",
      ("the next attempt recomputes the delta and restarts the review" in rr, "Any return to this step voids any owner yes already given." in rr),
      (True, True))
s = load("head-moved-exhausted")
check("(86) a head that keeps moving: the eighth HEAD MOVED stops the run, and nothing after the review runs",
      (len(attempts(s, "release-review")), s["expect"]["stops"], s["expect"]["stopReasons"], issued(s)[-1],
       json.load(open(os.path.join(root, "schemas", "step-contracts.json"), encoding="utf-8"))["contracts"]["release-review@1"]["maxAutoRedo"]),
      (8, ["release-review"], ["asked to run again 8 times in a row"], "release-review", 8))

# The stamp at the final gate (M): CHANGED, BEHIND and ERROR each stand the tower aside and stop
# before the merge; in the checks phase a moved production is a round the step runs again itself.
sv = ref("release-stamp-verify")
for name in ("stamp-changed-at-final-gate", "stamp-behind-at-final-gate", "stamp-error-at-final-gate"):
    s = load(name)
    check("(87) %s: stops at the stamp, before the recheck, the confirmations and the merge" % name,
          (issued(s)[-1], none_of(s, ["pre-merge-recheck", "rerun-at-merge", "merge-confirmations", "production-merge"])), ("stamp-verify", []))
check("(88) ... its step stands the tower aside (which owes nothing) and voids any yes",
      ("run the provider's `release --step-aside` when this session holds the tower" in sv,
       "A stepped-aside release holds nothing and owes nothing" in sv, "Any owner yes is void" in sv), (True, True, True))
s = load("checks-stamp-rebuilds")
check("(89) checks stamp CHANGED: three rounds run again inside the step, the fourth attempt stamps, at most three said",
      (attempts(s, "checks-stamp"), said(s, "checks-stamp")[-1].startswith("CHECKS STAMP: STAMPED"), "At most three rounds" in ref("release-stamp")),
      ([1, 2, 3, 4], True, True))

# The standing yes. MERGE: the go-ahead answers YES (standing) and nothing stops. ASK on an
# unattended run: one stop, with no owner words in the payload, and nothing merges.
ga = ref("owner-go-ahead")
s = load("standing-yes-merge")
check("(90) standing yes MERGE: no stop, the merge follows", (s["expect"]["stops"], said(s, "go-ahead"), "production-merge" in issued(s)),
      ([], ["GO-AHEAD: YES (standing)"], True))
s = load("standing-yes-ask")
check("(91) standing yes ASK, unattended: one stop at the go-ahead, no owner words handed, nothing merges",
      (s["expect"]["stops"], s["expect"]["handed"]["go-ahead"]["payload"], none_of(s, ["merge-confirmations", "production-merge"])),
      (["go-ahead"], {"answer": None, "startedBy": "auto"}, []))
check("(92) ... its step sends ONE notification and queues one notice, posts the standing yes once, and never writes a yes",
      ("sends ONE push notification" in ga, "queues one notice" in ga,
       "post the comment's text as ONE comment on the pull request (never twice)" in ga, "It is never written for them" in ga,
       "`ASK` or `ERROR` → the owner decides." in ga), (True, True, True, True, True))

# The previous release gate.
pr = ref("previous-release")
for name, waits in (("previous-release-pending-c", 2), ("previous-release-pending-m", 3)):
    s = load(name)
    check("(93) %s: waits inside the step, then PENDING stops before the go-ahead" % name,
          (s["expect"]["waits"], issued(s)[-1], none_of(s, MERGING)), (waits, "previous-release-gate", []))
check("(94) ... at most 45 minutes, no notice outside the tower, naming /devstride:release post-deploy only",
      ("for at most 45 minutes while it reads `2`" in pr, "the wait sends no notice" in pr, "/devstride:release post-deploy only" in pr),
      (True, True, True))
s = load("previous-release-failed-override")
check("(95) previous release FAILED: asks; only the owner's words, handed to the next attempt, override it, and the run goes on",
      (said(s, "previous-release-gate"), s["expect"]["handed"]["previous-release-gate#1"]["payload"]["answer"],
       "production-merge" in issued(s), "record them as ONE comment on this pull request" in pr),
      (["PREVIOUS RELEASE: FAILED release/26-11-20", "PREVIOUS RELEASE: NOT GATED"], None, True, True))
s = load("previous-release-recheck-steps-aside")
check("(96) the recheck under the tower reads pending: it steps aside owing nothing and the run stops before the stamp",
      (issued(s)[-1], none_of(s, ["stamp-verify", "merge-confirmations", "production-merge"]), "which owes nothing" in pr),
      ("previous-release-recheck", [], True))

# The merge floor.
mc = ref("merge-confirmations")
s = load("merge-not-confirmed")
check("(97) merge confirmations NOT CONFIRMED: stops; resumed, the confirmations are asked again and the merge is never issued",
      (attempts(s, "merge-confirmations"), "production-merge" in issued(s), s["expect"]["outcome"]), ([1, 2], False, "stopped"))
check("(98) ... the five confirmations, in order, and the only tolerated advances keep the tree",
      ([w for w in ("**The head.**", "**Ready and green.**", "**Pre-ship.**", "**Threads.**", "**The tower.**") if w in mc],
       mc.index("**The head.**") < mc.index("**Ready and green.**") < mc.index("**Pre-ship.**") < mc.index("**Threads.**") < mc.index("**The tower.**"),
       "The only tolerated advances leave the tree the same" in mc),
      (["**The head.**", "**Ready and green.**", "**Pre-ship.**", "**Threads.**", "**The tower.**"], True, True))
catalog = json.load(open(os.path.join(root, "schemas", "step-contracts.json"), encoding="utf-8"))["contracts"]
check("(99) the production merge requires the review, the pre-ship, the go-ahead and the confirmations, the go-ahead after the tower claim",
      (sorted(catalog["production-merge@1"]["requires"]), catalog["production-merge@1"]["requiresAfter"]),
      (["merge-confirmations@1", "owner-go-ahead@1", "pre-ship-release@1", "release-review@1"], {"owner-go-ahead@1": ["tower-claim@1"]}))
s = load("merge-same-tree-advance")
check("(100) a same-tree advance keeps the proofs: the merge follows on the review already held",
      (attempts(s, "release-review"), "production-merge" in issued(s)), ([1], True))
s = load("production-merge-refused")
check("(101) a refused merge stops, and no deploy step is issued", (issued(s)[-1], none_of(s, ["approve-deploy", "confirm-deploy"])),
      ("production-merge", []))

# The deploy.
ha = flat("skills/hotfix-steps/references/deploy-approval.md")
s = load("deploy-approval-not-configured")
check("(102) approval unset: NOT CONFIGURED, then the confirmation", issued(s)[issued(s).index("approve-deploy") + 1], "confirm-deploy")
s = load("deploy-approval-retry-then-stops")
check("(103) approval exit 2: RETRY re-issues it on its own; STOPPED stops before the confirmation",
      (attempts(s, "approve-deploy"), issued(s)[-1], "confirm-deploy" in issued(s)), ([1, 2, 3], "approve-deploy", False))
s = load("deploy-approval-waits-for-yes")
check("(104) no yes for this deploy: it asks, and the next attempt is handed the person's words and the merge commit",
      s["expect"]["handed"]["approve-deploy#2"]["payload"]["answer"].endswith(s["expect"]["handed"]["approve-deploy#2"]["payload"]["mergeSha"]))
check("(105) ... and a yes is never carried to a newer merge", "A yes is never carried over to a newer merge." in ha)
s = load("deploy-unconfirmed")
check("(106) deploy unconfirmed: the run stops; no health check, documentation or notes", (issued(s)[-1], none_of(s, AFTER_DEPLOY)),
      ("confirm-deploy", []))
s, M = load("deploy-hand-back-m"), steps_of("release-merge-and-deploy")
check("(107) M: the tower is handed back right after the confirmation and the estimates, naming what is owed",
      (M[M.index("confirm-deploy") + 1:M.index("confirm-deploy") + 3], M.index("hand-back-after-deploy") < M.index("post-deploy-check"),
       said(s, "hand-back-after-deploy")[0].startswith("TOWER: HANDED BACK owed ")), (["score-estimates", "hand-back-after-deploy"], True, True))

# Health.
rs = ref("post-deploy-result")
s = load("health-fail-s")
check("(108) S: FAIL stops at the check; no sync, documentation or notes", (issued(s), s["expect"]["outcome"]), (["post-deploy-check"], "stopped"))
s = load("health-not-run-accepted-s")
check("(109) S: NOT RUN asks; a yes accepts the verdict without running it again, and the close-out goes on",
      (attempts(s, "post-deploy-check"), issued(s)[1]), ([1], "sync-production"))
s = load("health-not-run-declined-s")
check("(110) S: a no ends the run as declined, nothing after it", (issued(s), s["expect"]["outcome"]), (["post-deploy-check"], "declined"))
for k in ("c", "m"):
    s = load("health-fail-" + k)
    check("(111) %s: FAIL never stops the check; the status posts failure, then stops; no documentation or notes" % k.upper(),
          (said(s, "post-deploy-check"), issued(s)[-1], said(s, "post-deploy-status"), none_of(s, AFTER_DEPLOY[1:])),
          (["POST-DEPLOY HEALTH: FAIL"], "post-deploy-status", ["POST-DEPLOY STATUS: FAILURE POSTED"], []))
    s = load("health-not-run-yes-" + k)
    check("(112) %s: NOT RUN asks at the status step; the yes is handed on, success is posted and the close-out goes on" % k.upper(),
          (attempts(s, "post-deploy-status"), said(s, "post-deploy-status")[-1], "update-docs" in issued(s)),
          ([1, 2], "POST-DEPLOY STATUS: SUCCESS POSTED", True))
    s = load("health-not-run-no-" + k)
    check("(113) %s: a no posts error and stops; no documentation or notes" % k.upper(),
          (said(s, "post-deploy-status")[-1], none_of(s, AFTER_DEPLOY[1:])), ("POST-DEPLOY STATUS: ERROR POSTED", []))
check("(114) M: a failed check stops before production is synced back", "sync-production" in issued(load("health-fail-m")), False)
s = load("health-not-configured-c")
check("(115) NOT CONFIGURED: the check is skipped and success is still posted, saying no check is configured",
      (said(s, "post-deploy-status"), "no post-deploy check configured" in rs, "not run - owner accepted: <reason>" in rs),
      (["POST-DEPLOY STATUS: SUCCESS POSTED"], True, True))

# Documentation and notes: the knowledge base syncs only after PUBLISHED; the owed table.
rd = ref("release-docs")
for key in ("published", "current", "staged", "failed", "not-configured"):
    s = load("docs-" + key)
    check("(116) docs %s: the sync %s" % (key, "runs" if key == "published" else "does not run"),
          said(s, "sync-knowledge-base")[0] == "KNOWLEDGE BASE SYNC: DONE", key == "published")
TABLE = ["`PUBLISHED` → settle `docs`; `knowledge-base` stays owed for the sync that follows.",
         "`CURRENT` → settle `docs` and `knowledge-base`: nothing new to mirror.",
         "`STAGED` → settle `docs`, and name the owner action",
         "`FAILED` → both stay owed; say so, with the re-run line. The run continues.",
         "`NOT CONFIGURED` → never owed; nothing to settle."]
check("(117) the documentation step settles or keeps the owed items by the table, one line per verdict", [t for t in TABLE if t not in rd], [])
s = load("docs-suppressed")
check("(118) no docs: the plan is handed it, documentation and the sync answer NOT APPLICABLE, the catch-up printed whole",
      (said(s, "docs-plan"), said(s, "update-docs"), said(s, "sync-knowledge-base"), "Print the catch-up whole" in rd),
      (["DOCS PLAN: SUPPRESSED"], ["UPDATE DOCS: NOT APPLICABLE"], ["KNOWLEDGE BASE SYNC: NOT APPLICABLE"], True))
rn = ref("release-notes")
check("(119) notes not requested is skipped and said", (said(load("standard-release"), "write-release-notes"),
      "Absent or `false` → `NOT REQUESTED`, with the evidence line \"release notes: not requested\"." in rn),
      (["RELEASE NOTES: NOT REQUESTED"], True))
check("(120) notes draft and publish settle release-notes; FAILED keeps it owed, and the run goes on to the recap",
      ([issued(load("notes-" + k))[-2] for k in ("drafted", "published", "failed")],
       "then the provider's `owed --done release-notes`." in rn, "`release-notes` stays owed, with the re-run line. The run continues." in rn),
      (["release-recap"] * 3, True, True))

# The partial entries.
entry = flat("scripts/staged/skills/release/SKILL.md")  # the rewritten entry page: the header says where it waits
for ident in ("post-deploy", "docs", "notes"):
    s = load("partial-" + ident)
    check("(121) %s only: exactly its definition's steps, nothing claimed, opened or merged" % ident,
          issued(s), steps_of("release-" + ident))
check("(122) release-notes only is never not requested; two partial words are a question",
      (said(load("partial-notes"), "write-release-notes"), 'never "not requested" there' in rn,
       "Two partial words in one command are a question." in entry), (["RELEASE NOTES: PUBLISHED"], True, True))
check("(123) a partial entry with no merged release stops at the start", issued(load("partial-none")), ["merged-release"])

# --- driven inline -------------------------------------------------------------------------------
def repo_at(name):
    path = os.path.join(tmp, name)
    os.makedirs(path)
    for args in (["init", "-q", "-b", "main"], ["-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false",
                                                "commit", "-q", "--allow-empty", "-m", "first"]):
        subprocess.run(["git", "-C", path] + args, check=True, capture_output=True)
    return path

def caller(repo, cache, session):
    env = dict(os.environ, XDG_CACHE_HOME=cache)
    for name in ("CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID", "GIT_DIR", "GIT_WORK_TREE"):
        env.pop(name, None)
    def call(command, request):
        if command == "start":
            request = dict(request, rehearsal=True)  # as above: a rehearsal
        done = subprocess.run([sys.executable, "-B", runner, command], input=json.dumps(dict(request, session=session)),
                              capture_output=True, text=True, env=env, cwd=repo)
        return (json.loads(done.stdout) if done.returncode == 0 else {"action": "refused", "exit": done.returncode, "why": done.stderr.strip()})
    return call

NORMAL = {}
for f in ("standard-merge-and-deploy",):
    for e in load(f)["script"]:
        NORMAL.setdefault(e["step"], e["output"])
def answer_of(step_id, override):
    return override.get(step_id) or NORMAL[step_id]
def verdict(label, value, result):
    return "%s: %s\nevidence line\n```json\n%s\n```\n" % (label, value, json.dumps(result))
def context(repo, **more):
    c = {"item": None, "productionBranch": "main", "releaseSource": "develop", "scope": "merge-and-deploy", "startedBy": "person",
         "releaseNotes": "false", "noDocs": False, "profile": {"name": "extended", "source": "config"}, "cwd": repo}
    c.update(more)
    return c
def drive(call, answer, run_id, override, until=None):
    """Answer each issued step from `override`, else the standard transcript, until a stop, the end or `until` is issued."""
    seen = []
    while answer.get("action") == "run" and len(seen) < 120:
        step = answer["step"]
        if step["id"] == until:
            return answer, seen
        seen.append(step["id"])
        answer = call("done", {"runId": run_id, "stepId": step["id"], "attempt": step["attempt"], "output": answer_of(step["id"], override)})
    return answer, seen

# Auto start (trigger 5): the levelling records START; the loop keeps the train claim and starts a
# NEW run in the same session while the first one's owed steps wait (`beside`: without it a second
# start of the same workflow with no item is refused, as a session's one open run always was); both
# have their own state file, `status` with `all` lists both, and the first resumes by its run id
# once the second stops.
repo, cache = repo_at("auto-repo"), os.path.join(tmp, "auto-cache")
call = caller(repo, cache, "auto-session")
first_def = json.load(open(os.path.join(root, "workflows", "release-merge-and-deploy.json"), encoding="utf-8"))
first_def = dict(first_def, phases=[p for p in first_def["phases"] if p["id"] == "close-out"])
a = call("start", {"definition": first_def, "context": context(repo)})
first = a.get("runId")
START = {"train-level-final": verdict("TRAIN LEVEL", "FAST-FORWARDED", {"state": "fast-forwarded", "autoStart": "START"}),
         "auto-start-next": verdict("AUTO START", "SKIP started at the levelling", {"state": "skip"})}
a, seen = drive(call, a, first, START, until="update-docs")
check("(124) auto start: the first run levels the train with START and waits at its owed documentation",
      (seen[-1], a.get("action"), a.get("step", {}).get("id")), ("train-level-final", "run", "update-docs"))
plain = call("start", {"definitionFile": os.path.join(root, "workflows", "release-merge-and-deploy.json"), "context": context(repo, startedBy="auto")})
check("(124b) ... a plain second start of the same definition is refused while the first run is open, and the page says to start the next one beside it",
      (plain.get("why", "").startswith("workflow: run-open"), "start a NEW run (`beside` `true`, `started-by: auto`" in entry), (True, True))
b = call("start", {"definitionFile": os.path.join(root, "workflows", "release-merge-and-deploy.json"), "context": context(repo, startedBy="auto"),
                   "beside": True})
second = b.get("runId")
b, seen_b = drive(call, b, second, {"go-ahead": verdict("GO-AHEAD", "NOT YET", {"state": "not-yet"})})
listed = call("status", {"all": True}).get("runs", [])
check("(125) ... a second run starts in the same session (started-by auto) and stops at the owner's yes; status all lists both",
      (bool(second) and second != first, b.get("action"), b.get("stepId"), sorted(r["runId"] for r in listed) == sorted([first, second]),
       dict((r["runId"], r["state"]) for r in listed).get(second)), (True, "stopped", "go-ahead", True, "stopped"))
check("(126) ... each run has its own state file, and a command naming neither is refused as ambiguous",
      (len([f for f in os.listdir(os.path.join(cache, "devstride-plugin", "workflows")) if f.startswith("auto-session.")]),
       call("next", {}).get("why", "").startswith("workflow: ambiguous-run")), (2, True))
a = call("resume", {"runId": first})
a, seen = drive(call, a, first, START)
check("(127) ... the first run resumes by its id at the documentation, skips the auto start (already started) and finishes",
      (seen[0], seen[-1], a.get("action"), a.get("outcome")), ("update-docs", "auto-start-next", "finished", "completed"))
listed = call("status", {"all": True}).get("runs", [])
check("(128) ... leaving only the second run, still waiting at the owner's yes", [(r["runId"] == second, r["state"]) for r in listed], [(True, "stopped")])
LOST = verdict("AUTO START", "SKIP train claim held by devstride-07", {"state": "skip"})
repo2, cache2 = repo_at("lost-repo"), os.path.join(tmp, "lost-cache")
call2 = caller(repo2, cache2, "lost-session")
c = call2("start", {"definition": first_def, "context": context(repo2)})
c, _ = drive(call2, c, c.get("runId"), {"auto-start-next": LOST})
check("(129) a lost train claim at the auto start carries on silently: the run finishes, no stop", (c.get("action"), c.get("outcome")),
      ("finished", "completed"))

# The backstop never creates a run: it is the entry's own check, not a step, and only START after
# the train claim starts one. Run with no release.backstop block, it answers OFF and the runner's
# state folder is never created.
bs_cache = os.path.join(tmp, "backstop-cache")
bs_repo = repo_at("backstop-repo")
done = subprocess.run([sys.executable, os.path.join(root, "skills", "release", "scripts", "backstop.py"), "due"], capture_output=True,
                      text=True, cwd=bs_repo, env=dict(os.environ, XDG_CACHE_HOME=bs_cache))
bs_source = open(os.path.join(root, "skills", "release", "scripts", "backstop.py"), encoding="utf-8").read()
check("(130) backstop: OFF (exit 12) creates no run; the check never calls the runner; the entry starts one only on START",
      (done.returncode, done.stdout.startswith("OFF"), os.path.exists(os.path.join(bs_cache, "devstride-plugin", "workflows")),
       "workflow.py" in bs_source or "run-workflow" in bs_source,
       "Only `START`, after the release-train claim is won, starts a run (`started-by: auto`); `SKIP`, `SHADOW`, `OFF`, `HOLDS` and `ERROR` create no run and no report." in entry),
      (12, True, False, False, True))

# A mixed fleet. The runner writes nothing a release on the old text would read: after a full
# scripted run the repository is untouched and the only file is the run's own state. And every
# line the steps are told to write into a durable record (pull request markers, the claim, the
# clearance record, the owed file) is byte-identical to the base release, so either side adopts.
repo3, cache3 = repo_at("fleet-repo"), os.path.join(tmp, "fleet-cache")
call3 = caller(repo3, cache3, "fleet-session")
d = call3("start", {"definitionFile": os.path.join(root, "workflows", "release-merge-and-deploy.json"), "context": context(repo3)})
d, _ = drive(call3, d, d.get("runId"), {"go-ahead": verdict("GO-AHEAD", "YES (standing)", {"state": "yes-standing"}),
                                        "go-ahead-recheck": verdict("GO-AHEAD", "YES (standing)", {"state": "yes-standing"})})
written = sorted(os.path.relpath(os.path.join(w, f), cache3) for w, _, fs in os.walk(cache3) for f in fs)
status = subprocess.run(["git", "-C", repo3, "status", "--porcelain", "--ignored"], capture_output=True, text=True).stdout
refs = subprocess.run(["git", "-C", repo3, "for-each-ref", "--format=%(refname)"], capture_output=True, text=True).stdout.split()
check("(131) mixed fleet: a full run on the runner leaves the repository untouched and writes only its own state file",
      (d.get("outcome"), status, refs, [f.split(os.sep)[:2] for f in written]),
      ("completed", "", ["refs/heads/main"], [["devstride-plugin", "workflows"]]))
BASE = "devstride--v4.7.0"  # the last release before the split; what it held is kept as a fixture
records_file = os.path.join(root, "scripts/tests/fixtures/release-split-base", "records.json")
if not os.path.isfile(records_file):
    check("(132) mixed fleet: the record lines and script fingerprints of %s are in %s" % (BASE, records_file), False)
else:
    import hashlib
    base_records = json.load(open(records_file, encoding="utf-8"))
    now = " ".join(" ".join(open(os.path.join(w, f), encoding="utf-8").read().split()) for base in ("skills/release", "skills/release-steps")
                   for w, _, fs in os.walk(os.path.join(root, base)) for f in fs if f.endswith(".md"))
    lost = ["%s: %s" % (r["path"], r["line"].strip()[:100]) for r in base_records["recordLines"]
            if " ".join(r["line"].split()).strip("- ") not in now]
    count = len(base_records["recordLines"])
    # The one sentence the merge-and-deploy scope's adoption rule rewrote (clearance.md, "0a moves") names no record format.
    check("(132) mixed fleet: each of the %d record lines the base release's references tell a step to write is still there, word for word" % count,
          (lost, count >= 30), ([], True))
    here = dict(("skills/release/scripts/" + os.path.relpath(os.path.join(w, f), os.path.join(root, "skills/release/scripts")).replace(os.sep, "/"),
                 hashlib.sha256(open(os.path.join(w, f), "rb").read()).hexdigest())
                for w, _, fs in os.walk(os.path.join(root, "skills/release/scripts")) if "__pycache__" not in w for f in fs)
    # The fingerprints are those of the scripts the release page in use runs today: a later change to
    # one is a change to what both kinds of session write, and has to re-pin it on purpose.
    check("(133) ... and no script that writes a marker, a claim, the clearance record or the owed file changed since it was pinned",
          sorted(k for k in set(here) | set(base_records["scripts"]) if here.get(k) != base_records["scripts"].get(k)), [])

# --- the switch is off --------------------------------------------------------------------------
# /devstride:release still follows the page of the last release before the split, word for word,
# and the runner refuses every release definition unless the start is a rehearsal.
live_page = open(os.path.join(root, "skills/release/SKILL.md"), encoding="utf-8").read()
base_page = open(os.path.join(root, "scripts/tests/fixtures/release-split-base/release.md"), encoding="utf-8").read()
check("(140) not switched on: the live release page is the page of the last release before the split, byte for byte, and names no runner",
      (live_page == base_page, "run-workflow" in live_page or "release-steps" in live_page), (True, False))
dormant_env = dict(os.environ, XDG_CACHE_HOME=os.path.join(tmp, "dormant-cache"))
for name in ("CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID", "GIT_DIR", "GIT_WORK_TREE"):
    dormant_env.pop(name, None)
refusals = []
for ident in ("release", "release-cut-to-deploy", "release-merge-and-deploy", "release-docs", "release-notes", "release-post-deploy"):
    done = subprocess.run([sys.executable, "-B", runner, "start"], capture_output=True, text=True, env=dormant_env, cwd=repo_at("dormant-" + ident),
                          input=json.dumps({"definitionFile": os.path.join(root, "workflows", ident + ".json"), "session": "dormant",
                                            "context": context(repo_at("dormant-" + ident + "-context"))}))
    refusals.append((ident, done.returncode, done.stdout, done.stderr.split(":")[1].strip() if done.stderr.count(":") > 1 else done.stderr))
check("(141) not switched on: the runner refuses every release definition that is not a rehearsal (skill-dormant), and answers nothing",
      [(rc, out, code) for _, rc, out, code in refusals], [(2, "", "skill-dormant")] * 6)
check("(142) ... and no run was written", os.path.isdir(os.path.join(tmp, "dormant-cache", "devstride-plugin", "workflows"))
      and os.listdir(os.path.join(tmp, "dormant-cache", "devstride-plugin", "workflows")) != [], False)

# A forwarding command that fails (`reported` with ok false, as the loop records an exit 1) leaves
# the run's order and outcome unchanged.
def partial(repo_name, fail):
    r, cdir = repo_at(repo_name), os.path.join(tmp, repo_name + "-cache")
    call4 = caller(r, cdir, repo_name)
    x = call4("start", {"definitionFile": os.path.join(root, "workflows", "release-docs.json"), "context": context(r, scope="release")})
    run_id, said_at = x.get("runId"), []
    if fail:
        said_at.append(call4("reported", {"runId": run_id, "ok": False}).get("say"))
    x, seen = drive(call4, x, run_id, {"merged-release": verdict("MERGED RELEASE", "FOUND 42", {"sha": "%040x" % 0x17, "pullRequest": 42})})
    return seen, x.get("outcome"), said_at
good, bad = partial("forward-ok", False), partial("forward-fail", True)
check("(134) a forwarding failure is said once and changes neither the order nor the outcome",
      (good[:2] == bad[:2], good[1], len(bad[2]) == 1 and bool(bad[2][0])), (True, "completed", True))
PY
PRC=$?; OUT="$(cat "$T/replays2.out")"
echo "$OUT" | sed 's/^ok   /  ok   /; s/^FAIL /  FAIL /'
echo "$OUT" | grep -q '^FAIL' && FAIL=1
[ "$PRC" -eq 0 ] || bad "(79b) the second replay cases crashed (exit $PRC)"

# --- no runner: with python3 hidden from PATH, each definition's step order is read from the file
# with the tools every machine has, and equals the order the definition lists (checked at (2)
# against the pinned lists): the generated files keep one step id per line at a fixed depth.
NOPY="$T/no-python"; mkdir -p "$NOPY"
for tool in sed tr cat; do ln -s "$(command -v "$tool")" "$NOPY/$tool"; done
for ident in release release-cut-to-deploy release-merge-and-deploy release-post-deploy release-docs release-notes; do
  got="$(env -i PATH="$NOPY" /bin/sh -c 'command -v python3 >/dev/null 2>&1 && echo "python3 visible"; sed -n "s/^          \"id\": \"\([a-z0-9-]*\)\",\$/\1/p" "$1" | tr "\n" " "' sh "$ROOT/workflows/$ident.json")"
  want="$(python3 -c 'import json,sys; print(" ".join(s["id"] for p in json.load(open(sys.argv[1]))["phases"] for s in p["steps"]) + " ")' "$ROOT/workflows/$ident.json")"
  if [ "$got" = "$want" ]; then echo "  ok   (135) no runner: $ident's step order is read from the file without python3"; else bad "(135) no runner: $ident — got [$got], want [$want]"; fi
done

exit $FAIL
