#!/bin/bash
# scripts/tests/step-contracts.sh — the step contract catalog (schemas/step-contracts.json) says
# what was published, the run-workflow skill and its reference keep their shape, and every skill
# the catalog names either exists with a verdict that matches its contract or is still pending.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export PYTHONDONTWRITEBYTECODE=1

# Step skills the catalog names that a later change on this branch adds: none now.
PENDING_SKILLS=""

cat > "$WORK/cases.py" <<'PY'
import copy, importlib.util, json, math, os, re, shutil, sys

root, work, pending = sys.argv[1], sys.argv[2], sys.argv[3:]
STEP_POINTER = "Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/step-skills.md` first: the rule every step skill follows."
POINTER = "**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message."


def check(label, good, detail=""):
    print(("ok   " if good else "FAIL ") + label + ("" if good else " -> %s" % (detail,)))


def tokens(raw):
    return math.ceil(len(raw) / 3)  # the plugin's own measure (scripts/measure-cost.sh)


def frontmatter(text):
    match = re.match(r"---\n(.*?)\n---\n", text, re.S)
    return dict(re.findall(r"^(\w[\w-]*):\s*(.*)$", match.group(1), re.M)) if match else None


def verdict_line(entry):
    """A contract's verdict as one line: the label, then each value with <name> where it must
    carry its detail and [<name>] where it may, the name being the value's detailName."""
    marks = {"none": "%s", "required": "%s <%s>", "optional": "%s [<%s>]"}
    return "%s: %s" % (entry["verdict"]["label"], " | ".join(
        marks[v["detail"]] % ((v["value"],) if v["detail"] == "none" else (v["value"], v["detailName"])) for v in entry["verdict"]["values"]))


def fields_ok(text):
    fields = frontmatter(text) or {}
    return fields.get("description", "").strip().strip('"').startswith("Step:")


def skill_faults(root, name, contracts, words, body_tokens):
    """What is wrong with one skill that serves catalog contracts; an empty list when nothing is."""
    path = os.path.join(root, "skills", name, "SKILL.md")
    if not os.path.isfile(path):
        return ["missing"]
    raw = open(path, "rb").read()
    text = raw.decode("utf-8")
    fields = frontmatter(text)
    if fields is None:
        return ["no frontmatter"]
    faults = []
    if fields.get("name") != name:
        faults.append("name is %r" % fields.get("name"))
    description = fields.get("description", "").strip().strip('"')
    if not description or len(description.split()) > words:
        faults.append("description has %d words" % len(description.split()))
    if tokens(raw) > body_tokens:
        faults.append("body is %d tokens" % tokens(raw))
    if re.sub(r"\s+", " ", text).count(re.sub(r"\s+", " ", POINTER)) != 1:
        faults.append("the plain-language pointer does not appear exactly once")
    if contracts is not None:
        section = re.search(r"^## Verdict\n(.*?)(?=^## |\Z)", text, re.S | re.M)
        said = re.findall(r"`([^`]+)`", section.group(1)) if section else None
        want = [verdict_line(entry) for entry in contracts]
        if said != want:
            faults.append("its Verdict section says %r, the catalog %r" % (said, want))
    return faults


# The one list of phases a tower heartbeat may name (the clearance contract's), less the claim itself.
TOWER_PHASES = ["train", "cut", "pr", "review", "pre-ship", "final", "merging", "deploy", "close-out"]


def release_steps_faults(root, serves):
    """What is wrong with the grouped release-steps skill: its body, the shared resume-rules
    reference, and one reference per mode (and for no other name)."""
    name, flat = "release-steps", lambda s: re.sub(r"\s+", " ", s)
    faults = skill_faults(root, name, None, 15, 1200)
    if faults == ["missing"]:
        return faults
    base = os.path.join(root, "skills", name)
    text = open(os.path.join(base, "SKILL.md"), encoding="utf-8").read()
    if flat(text).count(STEP_POINTER) != 1 or "disable-model-invocation" in text or "$ARGUMENTS" not in text or "one JSON object" not in text:
        faults.append("the step-skill shape")
    if not fields_ok(text):
        faults.append("the description does not start with Step:")
    prefix = "${CLAUDE_PLUGIN_ROOT}/skills/%s/references/" % name
    if "Read `%s<mode>.md` in full" % prefix not in flat(text) or "contract name without `@1`" not in flat(text):
        faults.append("no mode rule naming the reference to read in full")
    if "Any other contract, or none" not in flat(text) or "no verdict line" not in flat(text):
        faults.append("no answer for a contract it does not carry")
    if "one fenced `json` block" not in flat(text):
        faults.append("no result-block statement")
    rules = re.search(r"\*\*Step rules\.\*\*(.*)", flat(text))
    rules = rules.group(1) if rules else ""
    for rule in ("verdict first", "safe to re-run", "config wins", "never decides what runs next", "subagent"):
        if rule not in rules:
            faults.append("its step rules lack %r" % rule)
    modes = sorted(n.split("@")[0] for n, _ in serves)
    refdir = os.path.join(base, "references")
    own = sorted(f[:-3] for f in os.listdir(refdir)) if os.path.isdir(refdir) else []
    if "resume-rules" not in own:
        faults.append("no resume-rules.md")
    own = [f for f in own if f != "resume-rules"]
    if own != modes:
        faults.append("references %r are not the modes %r" % (own, modes))
    shared = os.path.join(refdir, "resume-rules.md")
    rules_text = open(shared, encoding="utf-8").read() if os.path.isfile(shared) else ""
    forward = rules_text.split("\n## Cited by", 1)[0]
    if prefix + "resume-rules.md" not in text:
        faults.append("the body does not point at resume-rules.md")
    for heading in ("## What the payload carries", "## What each shape skips", "## Whose release it is", "## Heartbeats"):
        if "\n%s\n" % heading not in rules_text:
            faults.append("resume-rules.md lacks %r" % heading)
    for word in ("`shape`", "`tower`", "`NEW`", "`ADOPTED`", "`MERGED`", "`adopted: true`", "never adopted silently"):
        if word not in flat(forward):
            faults.append("resume-rules.md does not state %s" % word)
    beats = re.search(r"^## Heartbeats\n(.*?)(?=^## |\Z)", rules_text, re.S | re.M)
    beats = flat(beats.group(1)) if beats else ""
    if [p for p in TOWER_PHASES if not re.search(r"`%s[ `]" % re.escape(p), beats)]:
        faults.append("the heartbeat map does not name every tower phase")
    for rule in ("local clearance record", "Exit 4", "every step transition", "min(10, expiry ÷ 3)", "before anything else"):
        if rule not in beats:
            faults.append("the heartbeat rules lack %r" % rule)
    for mode in modes:
        if "`%s`" % mode not in flat(text):
            faults.append("the body does not name the mode %s" % mode)
        ref = "skills/%s/references/%s.md" % (name, mode)
        if "${CLAUDE_PLUGIN_ROOT}/" + ref not in text and "${CLAUDE_PLUGIN_ROOT}/" + ref not in forward:
            faults.append("%s is cited by neither the body nor resume-rules.md" % ref)
    for path in [shared] + [os.path.join(refdir, m + ".md") for m in own]:
        body = open(path, encoding="utf-8").read() if os.path.isfile(path) else ""
        rel = os.path.relpath(path, root)
        if not body.startswith("---\nload: contract\n---\n") or re.findall(r"^## .*$", body, re.M)[-1:] != ["## Cited by"]:
            faults.append("%s is not a contract ending with Cited by" % rel)
        if "`${CLAUDE_PLUGIN_ROOT}/skills/%s/SKILL.md`" % name not in body.split("\n## Cited by", 1)[-1]:
            faults.append("%s: its Cited by list does not name the skill" % rel)
        for cited in sorted(set(re.findall(r"\$\{CLAUDE_PLUGIN_ROOT\}/(skills/[a-z-]+/references/[a-z0-9-]+\.md)", body))):
            other = open(os.path.join(root, cited), encoding="utf-8").read() if os.path.isfile(os.path.join(root, cited)) else ""
            if not other.startswith("---\nload: contract\n---\n"):
                faults.append("%s cites %s, which is not a contract reference of this plugin" % (rel, cited))
    for contract, entry in serves:
        mode = contract.split("@")[0]
        if mode not in own:
            continue
        ref = "skills/%s/references/%s.md" % (name, mode)
        body = open(os.path.join(root, ref), encoding="utf-8").read()
        section = re.search(r"^## Verdict\n(.*?)(?=^## |\Z)", body, re.S | re.M)
        if (re.findall(r"`([^`]+)`", section.group(1)) if section else None) != [verdict_line(entry)]:
            faults.append("%s: its Verdict is not the catalog's" % ref)
        if "`%s`" % contract not in body.split("\n## ", 1)[0]:
            faults.append("%s does not name its contract before its first section" % ref)
        if not re.search(r"^1\. ", body, re.M):
            faults.append("%s has no numbered procedure" % ref)
        result = re.search(r"^## Result\n(.*?)(?=^## |\Z)", body, re.S | re.M)
        result = flat(result.group(1)) if result else ""
        keys = entry["result"]["required"] + sorted(k for k in entry["result"]["types"] if k not in entry["result"]["required"]) + entry["proof"].get("required", [])
        if [k for k in keys if "`%s`" % k not in result]:
            faults.append("%s: its Result section does not name every key" % ref)
        if re.search(r"\bWorkflow\b", body) and not entry.get("delegates"):
            faults.append("%s: a non-delegating step tells the model to start a Workflow" % ref)
    return faults


catalog = json.load(open(os.path.join(root, "schemas/step-contracts.json"), encoding="utf-8"))
contracts = catalog["contracts"]
spec = importlib.util.spec_from_file_location("workflow_under_test", os.path.join(root, "skills/run-workflow/scripts/workflow.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
faults = runner.check_catalog(catalog)
check("the catalog parses and passes the structural checks", faults == [], faults)
# The Plan and Rebalance contracts are pinned value by value in scripts/tests/workflow-plan.sh; the
# checks below pin the Build ones, and the skill checks further down cover every contract.
PLAN_FAMILY = ["session-model@1", "plan-orient@1", "plan-ground@1", "plan-discovery@1", "plan-sign-off-record@1", "plan-draft@1",
               "plan-draft-approval@1", "plan-create@1", "plan-wire@1", "rationalize-gantt@1", "plan-number@1", "plan-hand-off@1",
               "rebalance-gates@1", "rebalance-partition@1", "rebalance-proposal@1", "rebalance-probe@1", "rebalance-successors@1",
               "rebalance-rewire@1", "rebalance-renumber@1", "rebalance-archive@1", "rebalance-marker@1", "rebalance-report@1",
               "splice@1"]
all_contracts = contracts
contracts = dict((n, e) for n, e in all_contracts.items() if n not in PLAN_FAMILY)
check("every Plan and Rebalance contract is in the catalog", all(n in all_contracts for n in PLAN_FAMILY), [n for n in PLAN_FAMILY if n not in all_contracts])

# What was published, value by value: a change here is a change to the contract.
PUBLISHED = {
    "claim@1": ("claim-story", "CLAIM: WON=continue | RENEWED=continue | TOOK OVER=continue | HELD=end:held | NOT CONFIGURED=skipped | DEGRADED=skipped", "none", [], None, None),
    "start@1": ("story-lifecycle", "START: MOVED=continue | UNCHANGED=continue | FAILED=stop", "none", [], "Mark In Progress", None),
    "branch@1": ("branch-feature", "BRANCH: CREATED=continue | EXISTS=continue | REFUSED=stop", "none", [], "Branch", None),
    "build@1": ("ultracode-build", "BUILD: READY=continue | NEEDS DECISION=ask | BLOCKED=stop", "none", ["branch@1"], "Build", "building"),
    "risk-check@1": ("risk-check", "RISK CHECK: CLEAR=continue | FIXED=continue | NEEDS DECISION=ask | BLOCKED=stop", "story", ["build@1"], "STORY RISK CHECK", None),
    "local-checks@1": ("local-checks", "LOCAL CHECKS: PASS=continue | NOT CONFIGURED=continue | FAIL=stop", "tree", ["risk-check@1"], "Verify", "verifying"),
    "review@1": ("review-story", "REVIEW: SETTLED=continue | COVERED=continue | BLOCKED=stop", "patch", ["risk-check@1", "local-checks@1"], "Review", "reviewing"),
    "merge@1": ("merge-story", "MERGE: LANDED=continue | REFRESHED=redo:self | HELD=end:held | BLOCKED=stop", "none", ["review@1", "local-checks@1", "risk-check@1"], "Merge", "landing"),
    "complete@1": ("story-lifecycle", "COMPLETE: DONE=continue | LANDED=continue | FAILED=stop", "none", ["merge@1"], "Completion ritual", None),
    "capture@1": ("capture-findings", "FINDINGS: FILED=continue | NONE=continue", "none", ["complete@1"], None, None),
    "sync@1": ("sync-base", "SYNC: CLEAN=continue | DIRTY=stop", "none", ["complete@1"], None, None),
    "custom@1": (None, "STEP: PASS=continue | FAIL=stop | HOLD=end:held", "none", [], None, None),
    "hotfix-preflight@1": ("hotfix-steps", "HOTFIX PREFLIGHT: READY=continue | DIRTY=ask | NEEDS INPUT=ask | FAILED=stop", "none", [], None, None),
    "hotfix-branch@1": ("hotfix-steps", "HOTFIX BRANCH: CUT=continue | FAILED=stop", "none", ["hotfix-preflight@1"], None, None),
    "hotfix-stage@1": ("hotfix-steps", "HOTFIX STAGE: NAMED=continue | NONE=continue | PRODUCTION=ask | DECLINED=end:environment-declined", "none", ["hotfix-branch@1"], None, None),
    "hotfix-environment@1": ("hotfix-steps", "HOTFIX ENVIRONMENT: RECREATED=continue | MIGRATED=continue | UNCHANGED=continue | NEEDS ANSWER=ask | FAILED=stop", "none", ["hotfix-stage@1"], None, None),
    "hotfix-report@1": ("hotfix-steps", "HOTFIX CUT: DONE=continue", "none", ["hotfix-environment@1"], None, None),
    "hotfix-fix@1": ("hotfix-steps", "HOTFIX FIX: COMMITTED=continue | NEEDS DIRECTION=ask | ABANDONED=end:abandoned", "none", ["hotfix-report@1"], None, None),
    "hotfix-merge@1": ("hotfix-steps", "HOTFIX MERGE: MERGED=continue | WAITING FOR YES=ask | REFUSED=stop | ERROR=stop", "none", ["review@1", "local-checks@1", "risk-check@1"], None, None),
    "deploy-approval@1": ("hotfix-steps", "DEPLOY APPROVAL: APPROVED=continue | WAITING FOR YES=ask | RETRY=redo:self | NOT CONFIGURED=skipped | STOPPED=stop", "none", ["hotfix-merge@1"], None, None),
    "deploy-confirm@1": ("hotfix-steps", "DEPLOY: CONFIRMED=continue | UNCONFIRMED=stop | OWNER TO CONFIRM=ask | NOT CONFIGURED=skipped", "none", ["hotfix-merge@1"], None, None),
    "hotfix-close@1": ("hotfix-steps", "HOTFIX CLOSED: CLOSED=continue | OPEN RELEASE=continue", "none", ["hotfix-merge@1"], None, None),
}
# The Release contracts, pinned the same way: a change here is a change to the contract.
RELEASE_PUBLISHED = {
    'release-shape@1': ('release-steps', 'RELEASE SHAPE: NEW=continue | ADOPTED=continue | MERGED=continue | CONFLICT=stop | REFUSED=stop', 'none', [], 'Read the release shape', None),
    'tower-claim@1': ('release-steps', 'TOWER CLAIM: CLEARED=continue | NOT APPLICABLE=skipped | BUSY=stop | STALE=ask | STUCK=ask | ERROR=stop', 'none', [], 'Claim the tower', None),
    'merged-release@1': ('release-steps', 'MERGED RELEASE: FOUND=continue | NONE=stop', 'none', [], 'Find the merged release', None),
    'train-claim@1': ('release-steps', 'TRAIN CLAIM: WON=continue | LOST=end:lost-train-claim | DEGRADED=stop | NOT CONFIGURED=skipped', 'none', [], 'Claim the release train', None),
    'ground-truth@1': ('release-steps', 'GROUND TRUTH: READ=continue | ANOTHER SESSION ACTIVE=continue | FAILED=stop', 'none', [], 'Read ground truth', None),
    'ci-hold-proof@1': ('release-steps', 'CI HOLD: PROVEN=continue | NO PULL-REQUEST CI=continue | NOT PROVEN=stop', 'none', [], 'Prove the CI hold', None),
    'train-finish@1': ('release-steps', 'EARLIER TRAIN: FINISHED=continue | NONE=continue | NOT APPLICABLE=skipped', 'none', [], 'Finish the earlier train', None),
    'ship-plan@1': ('release-steps', 'SHIP PLAN: GO=continue | WAITED=continue | NOT APPLICABLE=skipped', 'none', [], 'Gather the ship plan', None),
    'train-snapshot@1': ('release-steps', 'TRAIN SNAPSHOT: CUT=continue | ADOPTED=continue | NOTHING TO SHIP=skipped | HELD=stop | REFUSED=stop | OTHER HOLDER=ask | CONFLICT=stop | NOT APPLICABLE=skipped', 'none', [], 'Snapshot the train', None),
    'train-pr@1': ('release-steps', 'TRAIN PR: OPENED=continue | ADOPTED=continue | NOT APPLICABLE=skipped', 'none', [], 'Open the train pull request', None),
    'train-review@1': ('release-steps', 'TRAIN REVIEW: RECEIPTED=continue | SETTLED=continue | LATE ARRIVAL=redo:self | BLOCKED=stop | NOT APPLICABLE=skipped', 'none', [], 'Review the train', None),
    'train-pre-ship@1': ('pre-ship', 'PRE-SHIP: PASS=continue | FAIL=stop | NOTHING TO RUN=skipped | NOT APPLICABLE=skipped', 'none', [], 'Pre-ship checks on the train', None),
    'train-merge@1': ('release-steps', 'TRAIN MERGE: MERGED=continue | REFUSED=stop | ERROR=stop | NOT APPLICABLE=skipped', 'none', [], 'Merge the train', None),
    'train-close-out@1': ('release-steps', 'TRAIN CLOSE-OUT: CLOSED=continue | NONE=continue | PARTIAL=continue | NOT APPLICABLE=skipped', 'none', [], 'Close out the train', None),
    'train-level@1': ('release-steps', 'TRAIN LEVEL: FAST-FORWARDED=continue | MERGED SOURCE=continue | ALREADY LEVEL=continue | CONFLICT=stop | NOT APPLICABLE=skipped', 'none', [], 'Level the train', None),
    'release-delta@1': ('release-steps', 'RELEASE DELTA: ITEMS=continue | NOTHING TO RELEASE=end:nothing-to-release | HELD=stop', 'none', [], 'Work out the release delta', None),
    'classify-release@1': ('classify-release', 'RELEASE CLASS: LIGHT=continue | FULL=continue | NOT APPLICABLE=skipped', 'none', [], 'Classify the release', None),
    'tower-queue@1': ('release-steps', 'QUEUE: CLEAR=continue | WAIT=stop | ASK=ask | TIMED OUT=stop | NOT APPLICABLE=skipped', 'none', [], 'Wait in the release queue', None),
    'release-branch@1': ('release-steps', 'RELEASE BRANCH: CUT=continue | ADOPTED=continue | NOT CONFIGURED=skipped | NAME TAKEN=stop | REFUSED=stop', 'none', [], 'Cut the release branch', None),
    'production-in-branch@1': ('release-steps', 'PRODUCTION IN BRANCH: CONTAINS=continue | MERGED=continue | CONFLICT=stop | NOT APPLICABLE=skipped', 'none', [], 'Bring production in', None),
    'release-pr@1': ('release-steps', 'RELEASE PR: OPENED=continue | ADOPTED=continue', 'none', [], 'Open the release pull request', None),
    'train-claim-hand-on@1': ('release-steps', 'TRAIN CLAIM: HANDED ON=continue | HELD=continue | NOT APPLICABLE=skipped', 'none', [], 'Hand on the train claim', None),
    'release-tip@1': ('release-steps', 'PRODUCTION TIP: AT=continue', 'none', [], 'Read the production tip', None),
    'classify-at-checks@1': ('classify-release', 'RELEASE CLASS: LIGHT=continue | FULL=continue | NOT APPLICABLE=skipped', 'none', [], 'Classify at the checks', None),
    'pre-ship-at-checks@1': ('pre-ship', 'PRE-SHIP: PASS=continue | FAIL=stop | NOTHING TO RUN=skipped | NOT APPLICABLE=skipped', 'none', [], 'Pre-ship before the tower', None),
    'dev-deploy-wait@1': ('release-steps', 'DEV DEPLOY: SERVING=continue | FAILED=stop | TIMED OUT=stop | NOT APPLICABLE=skipped', 'none', [], 'Wait for the staging deploy', None),
    'pre-merge-at-checks@1': ('pre-merge-check', 'PRE-MERGE: CLEAR=continue | HOLD=stop | NOT RUN=confirm | NOT CONFIGURED=skipped | NOT APPLICABLE=skipped', 'none', [], 'Pre-merge check at the checks', None),
    'release-stamp@1': ('release-steps', 'CHECKS STAMP: STAMPED=continue | CHANGED=redo:self', 'none', [], 'Stamp the checks', None),
    'release-review@1': ('release-steps', 'RELEASE REVIEW: SETTLED=continue | HEAD MOVED=redo:self | BLOCKED=stop', 'none', [], 'Review the release', None),
    'classify-at-pre-ship@1': ('classify-release', 'RELEASE CLASS: LIGHT=continue | FULL=continue | NOT APPLICABLE=skipped', 'none', [], 'Classify before pre-ship', None),
    'pre-ship-release@1': ('pre-ship', 'PRE-SHIP: PASS=continue | FAIL=stop | NOT APPLICABLE=continue', 'none', ['release-review@1'], 'Pre-ship checks', None),
    'pre-ship-resume@1': ('release-steps', 'PRE-SHIP HOLD: DISCHARGED=continue | NO HOLD=skipped | STILL HELD=stop', 'none', [], 'Discharge the pre-ship hold', None),
    'release-docs-plan@1': ('release-steps', 'DOCS PLAN: HOOKS=continue | NONE REGISTERED=continue | SUPPRESSED=continue', 'none', [], 'Plan the documentation', None),
    'hotfix-catch-up@1': ('release-steps', 'HOTFIX CATCH-UP: NONE=continue | MERGED=rewind:release-review@1 | SAME TREE=continue', 'none', [], 'Catch up with a hotfix', None),
    'previous-release@1': ('release-steps', 'PREVIOUS RELEASE: SUCCESS=continue | PENDING=stop | FAILED=ask | NOT GATED=continue | UNREADABLE=ask', 'none', [], 'Check the previous release', None),
    'pre-merge-check@1': ('pre-merge-check', 'PRE-MERGE: CLEAR=continue | HOLD=stop | NOT RUN=confirm | NOT CONFIGURED=skipped | NOT APPLICABLE=skipped', 'none', [], 'Pre-merge check', None),
    'pre-merge-recheck@1': ('pre-merge-check', 'PRE-MERGE: CLEAR=continue | HOLD=stop | NOT RUN=confirm | NOT CONFIGURED=skipped | NOT APPLICABLE=skipped', 'none', [], 'Pre-merge recheck', None),
    'owner-go-ahead@1': ('release-steps', 'GO-AHEAD: YES=continue | NOT YET=ask | NO=end:declined', 'none', ['release-review@1', 'pre-ship-release@1'], 'Wait for the go-ahead', None),
    'owner-go-ahead-recheck@1': ('release-steps', 'GO-AHEAD: YES=continue | NOT YET=ask | NO=end:declined', 'none', ['release-review@1', 'pre-ship-release@1', 'owner-go-ahead@1'], 'Recheck the go-ahead', None),
    'release-stamp-verify@1': ('release-steps', 'CHECKS STAMP: UNCHANGED=continue | CHANGED=stop | BEHIND=stop | ERROR=stop', 'none', [], 'Verify the checks stamp', None),
    'rerun-at-merge@1': ('pre-ship', 'PRE-SHIP: PASS=continue | FAIL=stop | NOTHING TO RUN=skipped | NOT APPLICABLE=skipped', 'none', [], 'Re-run checks at the merge', None),
    'merge-confirmations@1': ('release-steps', 'MERGE CONFIRMED: HEAD=continue | NOT CONFIRMED=stop', 'none', ['release-review@1', 'pre-ship-release@1', 'owner-go-ahead@1'], 'Confirm the merge', None),
    'production-merge@1': ('release-steps', 'PRODUCTION MERGE: MERGED=continue | REFUSED=stop | ERROR=stop', 'none', ['release-review@1', 'pre-ship-release@1', 'owner-go-ahead@1', 'merge-confirmations@1'], 'Merge to production', None),
    'post-deploy-pending@1': ('release-steps', 'POST-DEPLOY STATUS: PENDING POSTED=continue | NOT APPLICABLE=skipped', 'none', [], 'Post the pending status', None),
    'estimates-score@1': ('release-steps', 'ESTIMATES: SCORED=continue | NONE=continue | NOTED FAILURE=continue', 'none', [], 'Score estimates', None),
    'tower-hand-back@1': ('release-steps', 'TOWER: HANDED BACK=continue | KEPT=stop | NOT APPLICABLE=skipped', 'none', [], 'Hand back the tower', None),
    'post-deploy-check@1': ('post-deploy', 'POST-DEPLOY HEALTH: PASS=continue | FAIL=stop | NOT RUN=confirm | NOT CONFIGURED=skipped', 'none', [], 'Post-deploy health check', None),
    'post-deploy-check-owed@1': ('post-deploy', 'POST-DEPLOY HEALTH: PASS=continue | FAIL=continue | NOT RUN=continue | NOT CONFIGURED=skipped', 'none', [], 'Post-deploy health check', None),
    'post-deploy-result@1': ('release-steps', 'POST-DEPLOY STATUS: SUCCESS POSTED=continue | FAILURE POSTED=stop | ERROR POSTED=stop | NEEDS DECISION=ask | NOT APPLICABLE=skipped', 'none', [], 'Post the health result', None),
    'release-sync@1': ('release-steps', 'SYNC: DONE=continue | ALREADY SYNCED=continue | STOPPED=stop', 'none', [], 'Sync production back', None),
    'release-branch-delete@1': ('release-steps', 'RELEASE BRANCH DELETE: DELETED=continue | KEPT=continue | NOT APPLICABLE=skipped', 'none', [], 'Delete the release branch', None),
    'release-docs@1': ('release-steps', 'UPDATE DOCS: PUBLISHED=continue | STAGED=continue | CURRENT=continue | NOT CONFIGURED=skipped | FAILED=continue | NOT APPLICABLE=skipped', 'none', [], 'Update documentation', None),
    'release-kb-sync@1': ('release-steps', 'KNOWLEDGE BASE SYNC: DONE=continue | CURRENT=continue | FAILED=continue | NOT RUN=continue | NOT CONFIGURED=skipped | NOT APPLICABLE=skipped', 'none', [], 'Sync the knowledge base', None),
    'release-close-out@1': ('release-steps', 'POST-DEPLOY CLOSE-OUT: DONE=continue | PARTIAL=continue | NOT APPLICABLE=skipped', 'none', [], 'Close out the release', None),
    'release-notes@1': ('release-steps', 'RELEASE NOTES: PUBLISHED=continue | DRAFTED=continue | NOT REQUESTED=skipped | NOT CONFIGURED=stop | FAILED=continue', 'none', [], 'Write release notes', None),
    'release-recap@1': ('release-steps', 'RELEASE RECAP: MERGED=continue | STOPPED AT=continue | NOTHING TO RELEASE=continue', 'none', [], 'Recap the release', None),
    'auto-start@1': ('release-steps', 'AUTO START: START=continue | SKIP=continue | NOT CONFIGURED=skipped | ERROR=continue', 'none', [], 'Decide the next release', None),
}
RELEASE_LINES = {
    'release-shape@1': 'RELEASE SHAPE: NEW | ADOPTED <pr> | MERGED <pr> | CONFLICT <prs> | REFUSED <files>',
    'tower-claim@1': 'TOWER CLAIM: CLEARED | NOT APPLICABLE | BUSY <holder> | STALE <pr> | STUCK <holder> | ERROR <reason>',
    'merged-release@1': 'MERGED RELEASE: FOUND <pr> | NONE',
    'train-claim@1': 'TRAIN CLAIM: WON | LOST <holder> | DEGRADED <reason> | NOT CONFIGURED',
    'ground-truth@1': 'GROUND TRUTH: READ | ANOTHER SESSION ACTIVE <what> | FAILED <reason>',
    'ci-hold-proof@1': 'CI HOLD: PROVEN | NO PULL-REQUEST CI | NOT PROVEN <facts>',
    'train-finish@1': 'EARLIER TRAIN: FINISHED <pr> | NONE | NOT APPLICABLE',
    'ship-plan@1': 'SHIP PLAN: GO | WAITED <minutes> | NOT APPLICABLE',
    'train-snapshot@1': 'TRAIN SNAPSHOT: CUT <branch> | ADOPTED <pr> | NOTHING TO SHIP | HELD <reason> | REFUSED <files> | OTHER HOLDER <pr> | CONFLICT <files> | NOT APPLICABLE',
    'train-pr@1': 'TRAIN PR: OPENED <pr> | ADOPTED <pr> | NOT APPLICABLE',
    'train-review@1': 'TRAIN REVIEW: RECEIPTED | SETTLED <head> | LATE ARRIVAL <count> | BLOCKED <reason> | NOT APPLICABLE',
    'train-pre-ship@1': 'PRE-SHIP: PASS [<counts>] | FAIL [<names>] | NOTHING TO RUN | NOT APPLICABLE',
    'train-merge@1': 'TRAIN MERGE: MERGED <pr> | REFUSED <reason> | ERROR <reason> | NOT APPLICABLE',
    'train-close-out@1': 'TRAIN CLOSE-OUT: CLOSED <count> | NONE | PARTIAL <skipped> | NOT APPLICABLE',
    'train-level@1': 'TRAIN LEVEL: FAST-FORWARDED | MERGED SOURCE | ALREADY LEVEL | CONFLICT <files> | NOT APPLICABLE',
    'release-delta@1': 'RELEASE DELTA: ITEMS <count> | NOTHING TO RELEASE | HELD <reason>',
    'classify-release@1': 'RELEASE CLASS: LIGHT | FULL | NOT APPLICABLE',
    'tower-queue@1': 'QUEUE: CLEAR | WAIT <pr> | ASK <pr> | TIMED OUT <pr> | NOT APPLICABLE',
    'release-branch@1': 'RELEASE BRANCH: CUT <branch> | ADOPTED <branch> | NOT CONFIGURED | NAME TAKEN <branch> | REFUSED <files>',
    'production-in-branch@1': 'PRODUCTION IN BRANCH: CONTAINS | MERGED <sha> | CONFLICT <files> | NOT APPLICABLE',
    'release-pr@1': 'RELEASE PR: OPENED <pr> | ADOPTED <pr>',
    'train-claim-hand-on@1': 'TRAIN CLAIM: HANDED ON | HELD <why> | NOT APPLICABLE',
    'release-tip@1': 'PRODUCTION TIP: AT <sha>',
    'classify-at-checks@1': 'RELEASE CLASS: LIGHT | FULL | NOT APPLICABLE',
    'pre-ship-at-checks@1': 'PRE-SHIP: PASS [<counts>] | FAIL [<names>] | NOTHING TO RUN | NOT APPLICABLE',
    'dev-deploy-wait@1': 'DEV DEPLOY: SERVING | FAILED <reason> | TIMED OUT | NOT APPLICABLE',
    'pre-merge-at-checks@1': 'PRE-MERGE: CLEAR | HOLD | NOT RUN | NOT CONFIGURED | NOT APPLICABLE',
    'release-stamp@1': 'CHECKS STAMP: STAMPED <stamp> | CHANGED <range>',
    'release-review@1': 'RELEASE REVIEW: SETTLED <head> | HEAD MOVED | BLOCKED <findings>',
    'classify-at-pre-ship@1': 'RELEASE CLASS: LIGHT | FULL | NOT APPLICABLE',
    'pre-ship-release@1': 'PRE-SHIP: PASS [<counts>] | FAIL [<names>] | NOT APPLICABLE',
    'pre-ship-resume@1': 'PRE-SHIP HOLD: DISCHARGED | NO HOLD | STILL HELD <why>',
    'release-docs-plan@1': 'DOCS PLAN: HOOKS <hooks> | NONE REGISTERED | SUPPRESSED',
    'hotfix-catch-up@1': 'HOTFIX CATCH-UP: NONE | MERGED <pr> | SAME TREE <sha>',
    'previous-release@1': 'PREVIOUS RELEASE: SUCCESS | PENDING | FAILED <release> | NOT GATED | UNREADABLE',
    'pre-merge-check@1': 'PRE-MERGE: CLEAR | HOLD | NOT RUN | NOT CONFIGURED | NOT APPLICABLE',
    'pre-merge-recheck@1': 'PRE-MERGE: CLEAR | HOLD | NOT RUN | NOT CONFIGURED | NOT APPLICABLE',
    'owner-go-ahead@1': 'GO-AHEAD: YES <source> | NOT YET | NO',
    'owner-go-ahead-recheck@1': 'GO-AHEAD: YES <source> | NOT YET | NO',
    'release-stamp-verify@1': 'CHECKS STAMP: UNCHANGED | CHANGED | BEHIND | ERROR <reason>',
    'rerun-at-merge@1': 'PRE-SHIP: PASS [<counts>] | FAIL [<names>] | NOTHING TO RUN | NOT APPLICABLE',
    'merge-confirmations@1': 'MERGE CONFIRMED: HEAD <head> | NOT CONFIRMED <which>',
    'production-merge@1': 'PRODUCTION MERGE: MERGED <pr> | REFUSED <reason> | ERROR <reason>',
    'post-deploy-pending@1': 'POST-DEPLOY STATUS: PENDING POSTED | NOT APPLICABLE',
    'estimates-score@1': 'ESTIMATES: SCORED <count> | NONE | NOTED FAILURE',
    'tower-hand-back@1': 'TOWER: HANDED BACK <owed> | KEPT <why> | NOT APPLICABLE',
    'post-deploy-check@1': 'POST-DEPLOY HEALTH: PASS | FAIL | NOT RUN | NOT CONFIGURED',
    'post-deploy-check-owed@1': 'POST-DEPLOY HEALTH: PASS | FAIL | NOT RUN | NOT CONFIGURED',
    'post-deploy-result@1': 'POST-DEPLOY STATUS: SUCCESS POSTED | FAILURE POSTED | ERROR POSTED | NEEDS DECISION <question> | NOT APPLICABLE',
    'release-sync@1': 'SYNC: DONE | ALREADY SYNCED | STOPPED <why>',
    'release-branch-delete@1': 'RELEASE BRANCH DELETE: DELETED <branch> | KEPT <why> | NOT APPLICABLE',
    'release-docs@1': 'UPDATE DOCS: PUBLISHED | STAGED | CURRENT | NOT CONFIGURED | FAILED | NOT APPLICABLE',
    'release-kb-sync@1': 'KNOWLEDGE BASE SYNC: DONE | CURRENT | FAILED | NOT RUN | NOT CONFIGURED | NOT APPLICABLE',
    'release-close-out@1': 'POST-DEPLOY CLOSE-OUT: DONE | PARTIAL | NOT APPLICABLE',
    'release-notes@1': 'RELEASE NOTES: PUBLISHED | DRAFTED | NOT REQUESTED | NOT CONFIGURED | FAILED',
    'release-recap@1': 'RELEASE RECAP: MERGED <pr> | STOPPED AT <step> | NOTHING TO RELEASE',
    'auto-start@1': 'AUTO START: START | SKIP <reason> | NOT CONFIGURED | ERROR <why>',
}
RELEASE_RESULTS = {
    'release-shape@1': (['shape'], {'shape': 'string', 'pullRequest': 'number|null', 'branch': 'string|null'}),
    'tower-claim@1': (['state'], {'state': 'string', 'adopted': 'boolean'}),
    'merged-release@1': (['sha', 'pullRequest'], {'sha': 'string', 'pullRequest': 'number|null'}),
    'train-claim@1': (['state'], {'state': 'string'}),
    'ground-truth@1': (['state'], {'state': 'string'}),
    'ci-hold-proof@1': (['state'], {'state': 'string'}),
    'train-finish@1': (['state'], {'state': 'string'}),
    'ship-plan@1': (['state'], {'state': 'string'}),
    'train-snapshot@1': (['state'], {'state': 'string', 'head': 'string', 'sourceBefore': 'string'}),
    'train-pr@1': (['state'], {'state': 'string'}),
    'train-review@1': (['state'], {'state': 'string'}),
    'train-pre-ship@1': (['state'], {'state': 'string', 'ranAtTrain': 'string'}),
    'train-merge@1': (['state'], {'state': 'string'}),
    'train-close-out@1': (['state'], {'state': 'string'}),
    'train-level@1': (['state'], {'state': 'string', 'autoStart': 'string'}),
    'release-delta@1': (['state'], {'state': 'string', 'sourceHead': 'string', 'productionHead': 'string'}),
    'classify-release@1': (['state'], {'state': 'string'}),
    'tower-queue@1': (['state'], {'state': 'string'}),
    'release-branch@1': (['state'], {'state': 'string'}),
    'production-in-branch@1': (['state'], {'state': 'string'}),
    'release-pr@1': (['state'], {'state': 'string', 'pullRequest': 'number'}),
    'train-claim-hand-on@1': (['state'], {'state': 'string'}),
    'release-tip@1': (['state'], {'state': 'string', 'head': 'string', 'productionTip': 'string'}),
    'classify-at-checks@1': (['state'], {'state': 'string'}),
    'pre-ship-at-checks@1': (['state'], {'state': 'string'}),
    'dev-deploy-wait@1': (['state'], {'state': 'string'}),
    'pre-merge-at-checks@1': (['state'], {'state': 'string', 'answer': 'string'}),
    'release-stamp@1': (['state'], {'state': 'string'}),
    'release-review@1': (['state', 'reviewedHead'], {'state': 'string', 'reviewedHead': 'string'}),
    'classify-at-pre-ship@1': (['state'], {'state': 'string'}),
    'pre-ship-release@1': (['state'], {'state': 'string'}),
    'pre-ship-resume@1': (['state'], {'state': 'string'}),
    'release-docs-plan@1': (['state'], {'state': 'string'}),
    'hotfix-catch-up@1': (['state'], {'state': 'string'}),
    'previous-release@1': (['state'], {'state': 'string'}),
    'pre-merge-check@1': (['state'], {'state': 'string', 'answer': 'string'}),
    'pre-merge-recheck@1': (['state'], {'state': 'string', 'answer': 'string'}),
    'owner-go-ahead@1': (['state'], {'state': 'string', 'answer': 'string'}),
    'owner-go-ahead-recheck@1': (['state'], {'state': 'string', 'answer': 'string'}),
    'release-stamp-verify@1': (['state'], {'state': 'string'}),
    'rerun-at-merge@1': (['state'], {'state': 'string'}),
    'merge-confirmations@1': (['state'], {'state': 'string'}),
    'production-merge@1': (['sha', 'pullRequest'], {'sha': 'string', 'pullRequest': 'number|null'}),
    'post-deploy-pending@1': (['state'], {'state': 'string'}),
    'estimates-score@1': (['state'], {'state': 'string'}),
    'tower-hand-back@1': (['state'], {'state': 'string'}),
    'post-deploy-check@1': (['state'], {'state': 'string', 'answer': 'string'}),
    'post-deploy-check-owed@1': (['state'], {'state': 'string'}),
    'post-deploy-result@1': (['state'], {'state': 'string'}),
    'release-sync@1': (['state'], {'state': 'string'}),
    'release-branch-delete@1': (['state'], {'state': 'string'}),
    'release-docs@1': (['state'], {'state': 'string'}),
    'release-kb-sync@1': (['state'], {'state': 'string'}),
    'release-close-out@1': (['state'], {'state': 'string'}),
    'release-notes@1': (['state'], {'state': 'string'}),
    'release-recap@1': (['state'], {'state': 'string'}),
    'auto-start@1': (['state'], {'state': 'string'}),
}
# Each Release contract's payload and argument template, as published.
RELEASE_PAYLOADS = {
    'release-shape@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?'}, None),
    'tower-claim@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'answer': 'step.answer?'}, None),
    'merged-release@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?'}, None),
    'train-claim@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?'}, None),
    'ground-truth@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?'}, None),
    'ci-hold-proof@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?'}, None),
    'train-finish@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?'}, None),
    'ship-plan@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?'}, None),
    'train-snapshot@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?', 'answer': 'step.answer?'}, None),
    'train-pr@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?'}, None),
    'train-review@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?'}, None),
    'train-pre-ship@1': ({'base': 'result:train-snapshot@1.sourceBefore?', 'head': 'result:train-snapshot@1.head?', 'shape': 'result:release-shape@1.shape?'}, 'train run {base} {head} --shape {shape}'),
    'train-merge@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?'}, None),
    'train-close-out@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?'}, None),
    'train-level@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?'}, None),
    'release-delta@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?'}, None),
    'classify-release@1': ({'productionBranch': 'context.productionBranch', 'releaseSource': 'context.releaseSource', 'head': 'result:release-delta@1.sourceHead?', 'shape': 'result:release-shape@1.shape?'}, None),
    'tower-queue@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?', 'answer': 'step.answer?'}, None),
    'release-branch@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?'}, None),
    'production-in-branch@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?'}, None),
    'release-pr@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?'}, None),
    'train-claim-hand-on@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?'}, None),
    'release-tip@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?'}, None),
    'classify-at-checks@1': ({'productionBranch': 'context.productionBranch', 'releaseSource': 'context.releaseSource', 'head': 'result:release-tip@1.head?', 'shape': 'result:release-shape@1.shape?'}, None),
    'pre-ship-at-checks@1': ({'base': 'result:release-tip@1.productionTip?', 'head': 'result:release-tip@1.head?', 'releaseClass': 'result:classify-at-checks@1.state?', 'shape': 'result:release-shape@1.shape?'}, 'release run {base} {head} {releaseClass} --shape {shape}'),
    'dev-deploy-wait@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?'}, None),
    'pre-merge-at-checks@1': ({'productionBranch': 'context.productionBranch', 'releaseSource': 'context.releaseSource', 'head': 'result:release-tip@1.head?', 'pullRequest': 'result:release-pr@1.pullRequest?', 'answer': 'step.answer?', 'shape': 'result:release-shape@1.shape?'}, None),
    'release-stamp@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?'}, None),
    'release-review@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?', 'profile': 'context.profile?'}, None),
    'classify-at-pre-ship@1': ({'productionBranch': 'context.productionBranch', 'releaseSource': 'context.releaseSource', 'head': 'result:release-review@1.reviewedHead?', 'shape': 'result:release-shape@1.shape?'}, None),
    'pre-ship-release@1': ({'base': 'result:release-delta@1.productionHead?', 'head': 'result:release-review@1.reviewedHead', 'releaseClass': 'result:classify-at-pre-ship@1.state?', 'ranAtTrain': 'result:train-pre-ship@1.ranAtTrain?', 'releaseReview': 'result:release-review@1', 'shape': 'result:release-shape@1.shape?'}, 'release run {base} {head} {releaseClass} {ranAtTrain} --shape {shape}'),
    'pre-ship-resume@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?'}, None),
    'release-docs-plan@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?', 'releaseNotes': 'context.releaseNotes?', 'noDocs': 'context.noDocs?'}, None),
    'hotfix-catch-up@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?'}, None),
    'previous-release@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?', 'answer': 'step.answer?'}, None),
    'pre-merge-check@1': ({'productionBranch': 'context.productionBranch', 'releaseSource': 'context.releaseSource', 'head': 'result:release-review@1.reviewedHead?', 'pullRequest': 'result:release-pr@1.pullRequest?', 'answer': 'step.answer?', 'shape': 'result:release-shape@1.shape?'}, None),
    'pre-merge-recheck@1': ({'productionBranch': 'context.productionBranch', 'releaseSource': 'context.releaseSource', 'head': 'result:release-review@1.reviewedHead?', 'pullRequest': 'result:release-pr@1.pullRequest?', 'answer': 'step.answer?', 'shape': 'result:release-shape@1.shape?'}, None),
    'owner-go-ahead@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?', 'answer': 'step.answer?', 'releaseReview': 'result:release-review@1', 'preShipRelease': 'result:pre-ship-release@1'}, None),
    'owner-go-ahead-recheck@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?', 'answer': 'step.answer?', 'releaseReview': 'result:release-review@1', 'preShipRelease': 'result:pre-ship-release@1', 'goAhead': 'result:owner-go-ahead@1'}, None),
    'release-stamp-verify@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?'}, None),
    'rerun-at-merge@1': ({'base': 'result:release-delta@1.productionHead?', 'head': 'result:release-review@1.reviewedHead?', 'releaseClass': 'result:classify-at-pre-ship@1.state?', 'rerunNames': 'context.rerunAtMerge?', 'shape': 'result:release-shape@1.shape?'}, 'release run {base} {head} {releaseClass} --only {rerunNames} --shape {shape}'),
    'merge-confirmations@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?', 'releaseReview': 'result:release-review@1', 'preShipRelease': 'result:pre-ship-release@1', 'ownerGoAhead': 'result:owner-go-ahead@1'}, None),
    'production-merge@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?', 'releaseReview': 'result:release-review@1', 'preShipRelease': 'result:pre-ship-release@1', 'ownerGoAhead': 'result:owner-go-ahead@1', 'mergeConfirmations': 'result:merge-confirmations@1'}, None),
    'post-deploy-pending@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?'}, None),
    'estimates-score@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?'}, None),
    'tower-hand-back@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?'}, None),
    'post-deploy-check@1': ({'productionBranch': 'context.productionBranch', 'mergeCommit': 'result:hotfix-merge@1.sha?', 'deployConfirmedAt': 'result:deploy-confirm@1.confirmedAt?', 'answer': 'step.answer?'}, 'check\n```json\n{"productionBranch": "{productionBranch}", "mergeCommit": "{mergeCommit}", "deployConfirmedAt": "{deployConfirmedAt}"}\n```'),
    'post-deploy-check-owed@1': ({'productionBranch': 'context.productionBranch', 'mergeCommit': 'result:hotfix-merge@1.sha?', 'deployConfirmedAt': 'result:deploy-confirm@1.confirmedAt?'}, 'check\n```json\n{"productionBranch": "{productionBranch}", "mergeCommit": "{mergeCommit}", "deployConfirmedAt": "{deployConfirmedAt}"}\n```'),
    'post-deploy-result@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?', 'answer': 'step.answer?'}, None),
    'release-sync@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?'}, None),
    'release-branch-delete@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?'}, None),
    'release-docs@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?'}, None),
    'release-kb-sync@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?'}, None),
    'release-close-out@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?'}, None),
    'release-notes@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?', 'releaseNotes': 'context.releaseNotes?'}, None),
    'release-recap@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?'}, None),
    'auto-start@1': ({'scope': 'context.scope?', 'startedBy': 'context.startedBy?', 'shape': 'result:release-shape@1?', 'tower': 'result:tower-claim@1?'}, None),
}
OWN = {"Build": 12, "Hotfix": 10, "Release": 57}
check("each workflow's own contracts are pinned: %d Build, %d Hotfix, %d Release" % (OWN["Build"], OWN["Hotfix"], OWN["Release"]),
      (len(PUBLISHED), len(RELEASE_PUBLISHED)) == (OWN["Build"] + OWN["Hotfix"], OWN["Release"]), (len(PUBLISHED), len(RELEASE_PUBLISHED)))
# The approval gate's contract: no skill (the reserved built-in reference gate runs it), and the
# one verdict whose class is wait. It is stamped with the release that first carries it.
GATE_PUBLISHED = {
    "approval@1": (None, "APPROVAL: REQUESTED=park | APPROVED=continue | CHANGES=redo:self | REJECTED=stop | UNAVAILABLE=stop", "none", [], "Wait for approval", None),
    # A step a person does by hand: requested like a gate, answered done or skipped by the person.
    "checkpoint@1": (None, "CHECKPOINT: REQUESTED=park | DONE=continue | SKIPPED=skipped | UNAVAILABLE=stop", "none", [], "Wait for a person", None),
}
PUBLISHED.update(RELEASE_PUBLISHED)
PUBLISHED.update(GATE_PUBLISHED)
check("the catalog holds exactly the published contracts (the Build ones, then the Hotfix ones, then the Release ones, then the gate and the checkpoint), in order", list(contracts) == list(PUBLISHED), list(contracts))
STAMP = r"^(unreleased|[0-9]+\.[0-9]+\.[0-9]+)$"
NEW = ["owner-go-ahead-recheck@1", "post-deploy-check-owed@1", "approval@1", "checkpoint@1"]  # every contract added since since was written
check("approval@1 and checkpoint@1 are the only contracts with a park verdict, and each contract added since carries since: unreleased until a release stamps it",
      [n for n, e in all_contracts.items() if any(v["class"] == "park" for v in e["verdict"]["values"])] == ["approval@1", "checkpoint@1"]
      and all(re.match(STAMP, str(all_contracts[n].get("since"))) is not None for n in NEW)
      and [n for n, e in all_contracts.items() if "since" in e] == NEW, [n for n, e in all_contracts.items() if "since" in e])
check("the four steps every workflow runs are marked neverOptional, and no other",
      [n for n, e in all_contracts.items() if e.get("neverOptional")] == ["risk-check@1", "local-checks@1", "review@1", "merge@1"]
      and all(e["neverOptional"] is True for e in all_contracts.values() if "neverOptional" in e),
      [n for n, e in all_contracts.items() if "neverOptional" in e])
check("the features map names when-condition, when-manual and on-fail-continue, each with since: unreleased until a release stamps it",
      list(catalog.get("features", {})) == ["when-condition", "when-manual", "on-fail-continue"] == list(runner.FEATURES)
      and all(re.match(STAMP, str(f.get("since"))) is not None and isinstance(f.get("summary"), str) for f in catalog["features"].values()),
      catalog.get("features"))
for bad in ({"since": "soon"}, {"since": "unreleased", "colour": "red"}, "unreleased"):
    edited = copy.deepcopy(catalog)
    edited["features"]["when-manual"] = bad
    check("a feature that is not {since, summary} fails the catalog: %r" % (bad,),
          any(f.startswith("shape: features: ") for f in runner.check_catalog(edited)), runner.check_catalog(edited))
edited = copy.deepcopy(catalog)
edited["contracts"]["review@1"]["neverOptional"] = "yes"
check("a neverOptional that is not true fails the catalog", any(f.startswith("shape: review@1: neverOptional") for f in runner.check_catalog(edited)),
      runner.check_catalog(edited))
for bad in ("soon", "4.9", 49):
    edited = copy.deepcopy(catalog)
    edited["contracts"]["approval@1"]["since"] = bad
    check("a since that is not a version or unreleased fails the catalog: %r" % (bad,),
          any(f.startswith("shape: approval@1: since") for f in runner.check_catalog(edited)), runner.check_catalog(edited))
for name, entry in contracts.items():
    said = (entry["builtinSkill"], "%s: %s" % (entry["verdict"]["label"], " | ".join("%s=%s" % (v["value"], v["class"]) for v in entry["verdict"]["values"])),
            entry["proof"]["binding"], entry["requires"], entry["claimPhase"], entry["shipIntentStage"])
    check("%s is as published: skill, verdicts and classes, binding, requirements, phase, stage" % name, said == PUBLISHED.get(name), said)
# A verdict value that records the run's outcome: the tracker's literal list (the three a run ends
# with today plus landed, handed-up and shipped), and only the marks published so far.
TRACKER_OUTCOMES = ["completed", "failed", "interrupted", "landed", "handed-up", "shipped"]
RECORDED = dict(("%s %s" % (name, v["value"]), v["recordsOutcome"]) for name, entry in all_contracts.items()
                for v in entry["verdict"]["values"] if "recordsOutcome" in v)
check("every recorded outcome is in the tracker's literal list", all(o in TRACKER_OUTCOMES for o in RECORDED.values()), RECORDED)
check("the published recording marks: COMPLETE DONE records shipped, LANDED records landed",
      RECORDED == {"complete@1 DONE": "shipped", "complete@1 LANDED": "landed"}, RECORDED)
check("the runner's list of recordable outcomes is the literal list's last three",
      list(runner.RECORDED_OUTCOMES) == TRACKER_OUTCOMES[3:] and list(runner.TRACKER_OUTCOMES) == TRACKER_OUTCOMES)
for bad in ("merged", "completed", "Landed"):
    edited = copy.deepcopy(catalog)
    edited["contracts"]["complete@1"]["verdict"]["values"][1]["recordsOutcome"] = bad
    check("a recorded outcome outside the list fails the catalog: %s" % bad,
          any(f.startswith("records-outcome: complete@1: ") for f in runner.check_catalog(edited)), runner.check_catalog(edited))
needs = dict((name, [v["value"] for v in entry["verdict"]["values"] if v["detail"] == "required"]) for name, entry in contracts.items())
check("the values that must carry a detail: a held claim's holder and the two questions",
      dict((k, v) for k, v in needs.items() if v and contracts[k]["builtinSkill"] not in ("hotfix-steps", "release-steps") and k not in ("approval@1", "checkpoint@1")) == {"claim@1": ["HELD"], "build@1": ["NEEDS DECISION"], "risk-check@1": ["NEEDS DECISION"]}, needs)
check("a gate that cannot be requested names why", needs["approval@1"] == ["UNAVAILABLE"], needs["approval@1"])
check("a checkpoint that cannot be requested names why", needs["checkpoint@1"] == ["UNAVAILABLE"], needs["checkpoint@1"])
# Every value's detail, as the step skills a later release writes must repeat it: <name> must, [<name>] may.
LINES = {
    "claim@1": "CLAIM: WON | RENEWED | TOOK OVER | HELD <holder> | NOT CONFIGURED | DEGRADED [<reason>]",
    "start@1": "START: MOVED [<status>] | UNCHANGED | FAILED [<reason>]",
    "branch@1": "BRANCH: CREATED [<branch>] | EXISTS [<branch>] | REFUSED [<reason>]",
    "build@1": "BUILD: READY | NEEDS DECISION <question> | BLOCKED [<reason>]",
    "risk-check@1": "RISK CHECK: CLEAR | FIXED [<count>] | NEEDS DECISION <question> | BLOCKED [<reason>]",
    "local-checks@1": "LOCAL CHECKS: PASS [<count>] | NOT CONFIGURED | FAIL [<checks>]",
    "review@1": "REVIEW: SETTLED | COVERED [<reason>] | BLOCKED [<reason>]",
    "merge@1": "MERGE: LANDED [<target>] | REFRESHED | HELD [<reason>] | BLOCKED [<reason>]",
    "complete@1": "COMPLETE: DONE | LANDED | FAILED [<reason>]",
    "capture@1": "FINDINGS: FILED [<items>] | NONE",
    "sync@1": "SYNC: CLEAN | DIRTY [<paths>]",
    "custom@1": "STEP: PASS | FAIL | HOLD",
    "hotfix-preflight@1": "HOTFIX PREFLIGHT: READY <branch> | DIRTY | NEEDS INPUT <what> | FAILED <why>",
    "hotfix-branch@1": "HOTFIX BRANCH: CUT <branch> | FAILED <step>",
    "hotfix-stage@1": "HOTFIX STAGE: NAMED <stage> | NONE | PRODUCTION <stage> | DECLINED <stage>",
    "hotfix-environment@1": "HOTFIX ENVIRONMENT: RECREATED | MIGRATED | UNCHANGED | NEEDS ANSWER <why> | FAILED <why>",
    "hotfix-report@1": "HOTFIX CUT: DONE <branch>",
    "hotfix-fix@1": "HOTFIX FIX: COMMITTED <sha> | NEEDS DIRECTION <what> | ABANDONED",
    "hotfix-merge@1": "HOTFIX MERGE: MERGED <sha> | WAITING FOR YES | REFUSED <reason> | ERROR <reason>",
    "deploy-approval@1": "DEPLOY APPROVAL: APPROVED | WAITING FOR YES | RETRY | NOT CONFIGURED | STOPPED <why>",
    "deploy-confirm@1": "DEPLOY: CONFIRMED <sha> | UNCONFIRMED | OWNER TO CONFIRM | NOT CONFIGURED",
    "hotfix-close@1": "HOTFIX CLOSED: CLOSED <sha> | OPEN RELEASE <branch>",
}
LINES.update(RELEASE_LINES)
LINES["approval@1"] = "APPROVAL: REQUESTED | APPROVED | CHANGES [<note>] | REJECTED [<note>] | UNAVAILABLE <reason>"
LINES["checkpoint@1"] = "CHECKPOINT: REQUESTED | DONE | SKIPPED | UNAVAILABLE <reason>"
for name, entry in contracts.items():
    check("%s: every value's detail mode and name are as published" % name, verdict_line(entry) == LINES.get(name), verdict_line(entry))
# Every contract's result keys, which are required and each one's type.
RESULTS = {
    "claim@1": (["state"], {"state": "string", "heldBy": "string", "since": "string"}),
    "start@1": (["statusBefore", "statusAfter", "boardPlaced"], {"statusBefore": "string", "statusAfter": "string", "boardPlaced": "boolean"}),
    "branch@1": (["branch", "base", "created"], {"branch": "string", "base": "string", "created": "boolean"}),
    "build@1": (["deferrals", "deviations", "untrackedDeferrals", "dismissed", "scopeLine", "head"],
                {"deferrals": "array", "deviations": "array", "untrackedDeferrals": "array", "dismissed": "array", "scopeLine": "string", "head": "string"}),
    "risk-check@1": (["ledger", "report", "counts", "untrackedDeferrals", "dismissed"],
                     {"ledger": "string", "report": "string", "counts": "object", "untrackedDeferrals": "array", "dismissed": "array",
                      "deferrals": "array", "deviations": "array", "resolved": "array"}),
    "local-checks@1": (["commands", "results", "receipt", "tree", "head", "skippedSuites"],
                       {"commands": "array", "results": "array", "receipt": "string|null", "tree": "string", "head": "string", "skippedSuites": "array"}),
    "review@1": (["path", "cycles", "untrackedDeferrals", "dismissed", "pullRequest", "mergeBody"],
                 {"path": "string", "cycles": "count", "untrackedDeferrals": "array", "dismissed": "array", "pullRequest": "number|null", "mergeBody": "string|null",
                  "deferrals": "array", "deviations": "array"}),
    "merge@1": (["target", "sha", "pullRequest", "deletedBranch"], {"target": "string", "sha": "string", "pullRequest": "number|null", "deletedBranch": "boolean"}),
    "complete@1": (["status", "statusName", "startDate", "dueDate", "pullRequest", "asBuilt", "claimReleased", "shipIntentReleased"],
                   {"status": "string", "statusName": "string|null", "startDate": "string|null", "dueDate": "string|null", "pullRequest": "number|null",
                    "asBuilt": "string", "claimReleased": "boolean", "shipIntentReleased": "boolean"}),
    "capture@1": (["filed", "inserted"], {"filed": "array", "inserted": "array"}),
    "sync@1": (["branch", "clean"], {"branch": "string", "clean": "boolean"}),
    "custom@1": ([], {}),
    "hotfix-preflight@1": (["branch", "base", "prefix", "date", "dateFormat", "configSource"], {"branch": "string", "base": "string", "prefix": "string", "date": "string", "dateFormat": "string", "configSource": "string"}),
    "hotfix-branch@1": (["branch", "base", "baseSha", "pushed", "shipIntent"], {"branch": "string", "base": "string", "baseSha": "string", "pushed": "boolean", "shipIntent": "string"}),
    "hotfix-stage@1": (["stage", "production"], {"stage": "string|null", "production": "boolean"}),
    "hotfix-environment@1": (["case", "mode", "why", "restartDevServer"], {"case": "number|null", "mode": "string|null", "why": "string", "restartDevServer": "boolean"}),
    "hotfix-report@1": (["branch", "case"], {"branch": "string", "case": "string"}),
    "hotfix-fix@1": (["commit", "deferrals", "deviations", "untrackedDeferrals", "dismissed", "scopeLine", "head"], {"commit": "string", "deferrals": "array", "deviations": "array", "untrackedDeferrals": "array", "dismissed": "array", "scopeLine": "string", "head": "string"}),
    "hotfix-merge@1": (["sha", "pullRequest"], {"sha": "string", "pullRequest": "number|null"}),
    "deploy-approval@1": (["mergeSha", "approved"], {"mergeSha": "string", "approved": "boolean"}),
    "deploy-confirm@1": (["mergeCommit", "confirmedAt"], {"mergeCommit": "string", "confirmedAt": "string|null"}),
    "hotfix-close@1": (["mergeSha", "openRelease"], {"mergeSha": "string", "openRelease": "string|null"}),
}
RESULTS.update(RELEASE_RESULTS)
RESULTS["approval@1"] = ([], {"id": "string", "gateId": "string", "status": "string", "requestedAt": "string"})
RESULTS["checkpoint@1"] = RESULTS["approval@1"]
for name, entry in contracts.items():
    check("%s: its result keys and their types are as published" % name, (entry["result"]["required"], entry["result"]["types"]) == RESULTS.get(name), entry["result"])
# Every contract's payload, key by key: a key is only ever added, never renamed or dropped.
PAYLOADS = {
    "risk-check@1": {"item": "context.item?", "profile": "context.profile.name", "reviewMoment": "context.reviewMoment",
                     "workingBase": "context.workingBase", "build": "result:build@1", "answer": "step.answer?",
                     "previousProof": "step.passedProof?", "previousResult": "step.passedResult?",
                     "baselineUnreadable": "step.passedUnreadable?"},
    "review@1": {"item": "context.item?", "profile": "context.profile.name", "reviewMoment": "context.reviewMoment",
                 "workingBase": "context.workingBase", "route": "context.route", "riskCheck": "result:risk-check@1",
                 "build": "result:build@1", "localChecks": "result:local-checks@1", "localChecksProof": "proof:local-checks@1"},
    "local-checks@1": {"item": "context.item?", "profile": "context.profile.name", "workingBase": "context.workingBase", "route": "context.route",
                       "oneOff": "context.oneOff", "branch": "result:branch@1.branch", "previousProof": "step.proof?", "reviewMoment": "context.reviewMoment"},
    "merge@1": {"item": "context.item", "profile": "context.profile.name", "workingBase": "context.workingBase", "route": "context.route",
                "branch": "result:branch@1.branch", "review": "result:review@1", "build": "result:build@1", "riskCheck": "result:risk-check@1",
                "commit": "step.head?", "reviewProof": "proof:review@1", "localChecks": "result:local-checks@1"},
    "complete@1": {"item": "context.item", "profile": "context.profile.name", "workingBase": "context.workingBase", "oneOff": "context.oneOff",
                   "releaseUnit": "context.releaseUnit", "route": "context.route", "profileSource": "context.profile.source", "merge": "result:merge@1",
                   "build": "result:build@1", "riskCheck": "result:risk-check@1", "review": "result:review@1"},
}
PAYLOADS["approval@1"] = {"item": "context.item?"}
PAYLOADS["checkpoint@1"] = {"item": "context.item?"}
for name, payload in PAYLOADS.items():
    check("%s: its payload is as published" % name, contracts[name]["payload"] == payload, contracts[name]["payload"])
for name, (payload, argument) in RELEASE_PAYLOADS.items():
    check("%s: its payload and argument template are as published" % name, (contracts[name]["payload"], contracts[name]["argument"]) == (payload, argument),
          (contracts[name]["payload"], contracts[name]["argument"]))
check("the two Build skills that take text keep their argument templates; the Release ones are pinned above",
      dict((n, e["argument"]) for n, e in contracts.items() if e["argument"] and n not in RELEASE_PUBLISHED) ==
      {"branch@1": "{branchSlug} base: {workingBase}", "build@1": "{item} {goal} profile: {profile} review-moment: {reviewMoment}"})
check("the four proofs name their fields",
      dict((n, e["proof"].get("required")) for n, e in contracts.items() if "required" in e["proof"]) ==
      {"risk-check@1": ["base", "head", "triggers", "verifiers", "lenses"], "local-checks@1": ["kind", "tree", "head", "receipt"],
       "review@1": ["path", "head", "base", "patchId"], "merge@1": ["head"]})
check("the proof values each kind of local check and review may give, and the verdict each local check pins",
      dict((n, e["proof"]["values"]) for n, e in contracts.items() if "values" in e["proof"]) ==
      {"local-checks@1": {"kind": ["receipt", "none-configured"]}, "review@1": {"path": ["fast-local", "pull-request"]}}
      and dict((v["value"], v.get("proof")) for v in contracts["local-checks@1"]["verdict"]["values"]) ==
      {"PASS": {"kind": "receipt"}, "NOT CONFIGURED": {"kind": "none-configured"}, "FAIL": None}
      and not any("proof" in v for n, e in contracts.items() if n != "local-checks@1" for v in e["verdict"]["values"]))
check("a count is a count: the risk check's verifiers and the review's cycles",
      contracts["risk-check@1"]["proof"]["types"]["verifiers"] == "count" and contracts["review@1"]["result"]["types"]["cycles"] == "count")
check("the satisfiers shipped: hotfix-branch for branch, hotfix-fix for build, the production merge and a found merged release for the hotfix merge the deploy steps read, and the final-gate recheck for the go-ahead",
      dict((n, e["satisfiedBy"]) for n, e in contracts.items() if "satisfiedBy" in e) ==
      {"branch@1": ["hotfix-branch@1"], "build@1": ["hotfix-fix@1"], "hotfix-merge@1": ["production-merge@1", "merged-release@1"],
       "owner-go-ahead@1": ["owner-go-ahead-recheck@1"]})
check("the merge confirmations and the production merge need the go-ahead after the tower claim, and no other contract orders a requirement",
      dict((n, e["requiresAfter"]) for n, e in contracts.items() if "requiresAfter" in e) ==
      {"merge-confirmations@1": {"owner-go-ahead@1": ["tower-claim@1"]}, "production-merge@1": {"owner-go-ahead@1": ["tower-claim@1"]}})
check("the production merge requires review, pre-ship, the go-ahead and the merge confirmations",
      contracts["production-merge@1"]["requires"] == ["release-review@1", "pre-ship-release@1", "owner-go-ahead@1", "merge-confirmations@1"])
check("the raised automatic re-issue caps, and no other",
      dict((n, e["maxAutoRedo"]) for n, e in contracts.items() if "maxAutoRedo" in e) ==
      {"release-review@1": 8, "train-review@1": 8, "hotfix-catch-up@1": 6, "production-in-branch@1": 6, "pre-ship-release@1": 6})

# run-workflow: the entry skill and its reference
faults = skill_faults(root, "run-workflow", None, 15, 1200)
check("run-workflow: name, a description of at most 15 words, a body of at most 1,200 tokens, the pointer once", faults == [], faults)
skill = open(os.path.join(root, "skills/run-workflow/SKILL.md"), encoding="utf-8").read()
check("run-workflow can be invoked by the loop (no disable-model-invocation)", "disable-model-invocation" not in skill)
# the reference is split: the loop half (driving a run) and the contracts half (definitions and proofs)
reference = "skills/run-workflow/references/workflow-runner.md"
authoring = "skills/run-workflow/references/workflow-contracts.md"
text = open(os.path.join(root, reference), encoding="utf-8").read()
rules = open(os.path.join(root, authoring), encoding="utf-8").read()
for path, body in ((reference, text), (authoring, rules)):
    check("%s opens with load: contract" % path, body.startswith("---\nload: contract\n---\n"))
    last = re.findall(r"^## .*$", body, re.M)[-1]
    cited = body[body.rindex("\n## Cited by"):]
    check("%s ends with ## Cited by, naming the skill" % path, last == "## Cited by" and "`skills/run-workflow/SKILL.md`" in cited, last)
    check("%s is reachable from the skill with a read-in-full instruction" % path,
          re.search(r"Read\s+`\$\{CLAUDE_PLUGIN_ROOT\}/%s`\s+in\s+full" % re.escape(path), skill) is not None)
check("the loop half points at the contracts half, and the Build loop reads the loop half in full",
      "${CLAUDE_PLUGIN_ROOT}/" + authoring in text
      and re.search(r"Read\s+`\$\{CLAUDE_PLUGIN_ROOT\}/%s` in full" % re.escape(reference),
                    open(os.path.join(root, "skills/build-item/SKILL.md"), encoding="utf-8").read()) is not None)
SECTIONS = {reference: ["## Commands", "## A step's answer", "## Waiting and parked", "## Going back", "## Counting a step's re-issues", "## Stops", "## Reporting", "## Heartbeat and ship intent", "## Resuming", "## Cited by"],
            authoring: ["## What `start` refuses", "## What is reported", "## Payloads", "## Proofs",
                        "## satisfiedBy — one step standing in for another's proof", "## Cited by"]}
check("every section of the reference before the split is in exactly one half",
      re.findall(r"^## .*$", text, re.M) == SECTIONS[reference] and re.findall(r"^## .*$", rules, re.M) == SECTIONS[authoring],
      (re.findall(r"^## .*$", text, re.M), re.findall(r"^## .*$", rules, re.M)))
check("the skill names the five commands' loop and the reference names all five",
      all("`%s`" % c in text for c in runner.COMMANDS) and all("`%s`" % c in skill for c in ("start", "done", "status", "resume")))
codes = ["bad-schema", "duplicate-step-id", "unknown-contract", "unknown-contract-major", "requires-missing", "requires-not-earlier",
         "requires-not-after", "rewind-missing", "rewind-not-always", "required-not-always", "required-not-stop", "required-off", "skill-missing",
         "skill-dormant", "plugin-too-old", "repository-required",
         "unsupported-gate", "unsupported-when", "unsupported-source", "library-version", "unsupported-on-fail", "credential-in-definition",
         "bad-condition", "unsupported-checkpoint", "gate-needs-item"]
source = open(os.path.join(root, "skills/run-workflow/scripts/workflow.py"), encoding="utf-8").read()
check("every validation code is in the runner and in the contracts half", all('"%s"' % c in source and "`%s`" % c in rules for c in codes),
      [c for c in codes if '"%s"' % c not in source or "`%s`" % c not in rules])
kinds = ["failed", "needs-person", "attempts-exhausted", "no-verdict", "proof"]
check("every stop kind is in the reference's table", all("| `%s` |" % k in text for k in kinds))
check("the five named proof rules are in the runner and the contracts half", all(r in source and "`%s`" % r in rules for r in (
    "risk-triggers-need-verifiers", "risk-check-accumulates", "none-configured-needs-pull-request-route", "review-names-one-path",
    "merge-lands-what-was-checked")))
check("the merge stop's own rule is in the runner and the loop half", "merge-may-have-landed" in source and "`merge-may-have-landed`" in text)
check("adoption's refusal across repositories is in the runner and the loop half", '"run-other-repository"' in source and "`run-other-repository`" in text)
check("an adopted run's story-branch refusal is in the runner and the loop half", '"wrong-branch"' in source and "`wrong-branch`" in text)
check("every binding the runner knows is spelled in the contracts half", all("- **%s**:" % b in rules for b in runner.BINDINGS), runner.BINDINGS)

contracts = all_contracts
# the skills the catalog names
present = sorted(n for n in os.listdir(os.path.join(root, "skills")) if os.path.isfile(os.path.join(root, "skills", n, "SKILL.md")))
named = sorted(set(e["builtinSkill"] for e in contracts.values() if e["builtinSkill"]))
check("every skill the catalog names exists or is pending", all(n in present or n in pending for n in named), [n for n in named if n not in present and n not in pending])
check("no step skill the catalog names is pending any more", pending == [], pending)
flat = lambda s: re.sub(r"\s+", " ", s)
PLAN_SKILLS = ["plan-steps", "comprehend-plan", "rationalize-gantt", "insert-story"]
# The existing seam step skills the release uses unchanged at several positions: each keeps its own
# verdict line, and every contract it serves must use that line's label and values.
SEAM_STEPS = {"classify-release", "pre-ship", "pre-merge-check", "post-deploy"}
BUILD_STEPS = ["claim-story", "story-lifecycle", "risk-check", "local-checks", "review-story", "merge-story", "capture-findings", "sync-base"]
check("the eight Build step skills are the catalog's own skills, less the two engines", sorted(BUILD_STEPS) == sorted(set(named) - {"branch-feature", "ultracode-build", "hotfix-steps", "release-steps"} - SEAM_STEPS - set(PLAN_SKILLS)), named)
for name in named:
    if name in pending:
        continue
    serves = [(n, e) for n, e in contracts.items() if e["builtinSkill"] == name]
    text = open(os.path.join(root, "skills", name, "SKILL.md"), encoding="utf-8").read()
    if name in ("comprehend-plan", "rationalize-gantt", "insert-story"):
        # plan-family skills people also type: their verdict and the pointer; bodies and descriptions unchanged
        faults = skill_faults(root, name, [e for _, e in serves], 10 ** 6, 10 ** 9)
        check("%s carries its contract's verdict and the pointer once" % name, faults == [], faults)
        continue
    if name == "release-steps":
        # the grouped Release step skill: the body names every mode, and each mode has a reference
        faults = release_steps_faults(root, serves)
        check("step skill release-steps keeps the grouped shape: a reference per mode, and for no other name", faults == [], faults)
        # the check itself, on a throwaway copy: a missing reference, a stray one and a stale verdict are each caught
        def drop(d):
            os.remove(os.path.join(d, "references/tower-claim.md"))

        def stray(d):
            shutil.copy(os.path.join(d, "references/tower-claim.md"), os.path.join(d, "references/tower-wave.md"))

        def stale(d):
            path = os.path.join(d, "references/train-claim.md")
            body = open(path, encoding="utf-8").read()
            with open(path, "w", encoding="utf-8") as out:
                out.write(body.replace("| DEGRADED <reason> ", ""))

        def wordy(d):
            with open(os.path.join(d, "SKILL.md"), "a", encoding="utf-8") as out:
                out.write("\n" + "word " * 800)

        cited_elsewhere = set()
        for f in os.listdir(os.path.join(root, "skills/release-steps/references")):
            cited_elsewhere |= set(re.findall(r"\$\{CLAUDE_PLUGIN_ROOT\}/(skills/[a-z-]+/references/[a-z0-9-]+\.md)",
                                              open(os.path.join(root, "skills/release-steps/references", f), encoding="utf-8").read()))
        for number, (label, change, word) in enumerate((
                ("a mode with no reference is caught", drop, "are not the modes"),
                ("a reference for no mode is caught", stray, "are not the modes"),
                ("a reference whose verdict differs from the catalog is caught", stale, "Verdict is not the catalog's"),
                ("a body over 1,200 tokens is caught", wordy, "body is"))):
            copy = os.path.join(work, "release-copy-%d" % number)
            shutil.copytree(os.path.join(root, "skills/release-steps"), os.path.join(copy, "skills/release-steps"))
            for other in sorted(cited_elsewhere):
                if not other.startswith("skills/release-steps/") and os.path.isfile(os.path.join(root, other)):
                    os.makedirs(os.path.dirname(os.path.join(copy, other)), exist_ok=True)
                    shutil.copy(os.path.join(root, other), os.path.join(copy, other))
            change(os.path.join(copy, "skills/release-steps"))
            found = release_steps_faults(copy, serves)
            check("release-steps: " + label, any(word in f for f in found), found)
        clean = os.path.join(work, "release-copy-clean")
        shutil.copytree(os.path.join(root, "skills/release-steps"), os.path.join(clean, "skills/release-steps"))
        for other in sorted(cited_elsewhere):
            if not other.startswith("skills/release-steps/") and os.path.isfile(os.path.join(root, other)):
                os.makedirs(os.path.dirname(os.path.join(clean, other)), exist_ok=True)
                shutil.copy(os.path.join(root, other), os.path.join(clean, other))
        check("release-steps: an untouched copy has no fault, so each fault above is the change's own", release_steps_faults(clean, serves) == [],
              release_steps_faults(clean, serves))
        continue
    if name == "plan-steps":
        # the grouped Plan and Rebalance step skill: each mode's verdict and result keys live in its reference
        faults = skill_faults(root, name, None, 15, 1200)
        if flat(text).count(STEP_POINTER) != 1 or "disable-model-invocation" in text or "$ARGUMENTS" not in text or "`<mode> <item>`" not in flat(text) or "one JSON object" in text:
            faults.append("the step-skill shape")
        if not fields_ok(text):
            faults.append("the description does not start with Step:")
        modes = sorted(n.split("@")[0] for n, _ in serves)
        own = sorted(f[:-3] for f in os.listdir(os.path.join(root, "skills", name, "references")))
        if modes != own:
            faults.append("references %r are not the modes %r" % (own, modes))
        for contract, entry in serves:
            mode = contract.split("@")[0]
            if not (entry["argument"] or "").startswith(mode + " "):
                faults.append("%s: the argument does not begin with its mode" % contract)
            ref = "skills/%s/references/%s.md" % (name, mode)
            if "`%s` → read `${CLAUDE_PLUGIN_ROOT}/%s`" % (mode, ref) not in flat(text):
                faults.append("no dispatch line for %s" % contract)
            body = open(os.path.join(root, ref), encoding="utf-8").read() if os.path.isfile(os.path.join(root, ref)) else ""
            section = re.search(r"^## Verdict\n(.*?)(?=^## |\Z)", body, re.S | re.M)
            if (re.findall(r"`([^`]+)`", section.group(1)) if section else None) != [verdict_line(entry)]:
                faults.append("%s: its Verdict is not the catalog's" % ref)
            if not body.startswith("---\nload: contract\n---\n") or re.findall(r"^## .*$", body, re.M)[-1:] != ["## Cited by"]:
                faults.append("%s is not a contract ending with Cited by" % ref)
            result = re.search(r"^## Result\n(.*?)(?=^## |\Z)", body, re.S | re.M)
            result = flat(result.group(1)) if result else ""
            keys = entry["result"]["required"] + sorted(k for k in entry["result"]["types"] if k not in entry["result"]["required"]) + entry["proof"].get("required", [])
            if [k for k in keys if "`%s`" % k not in result]:
                faults.append("%s: its Result section does not name every key" % ref)
            if "Workflow" in re.sub(r"\(`delegates: true`\)[^.]*\.", "", body.replace("no subagent and no Workflow", "").replace("never rerun the whole Workflow", "")) and not entry.get("delegates"):
                faults.append("%s: a non-delegating step tells the model to start a Workflow" % ref)
        if "Any other first word, or none → no verdict line" not in flat(text):
            faults.append("no answer for a contract it does not carry")
        check("step skill plan-steps keeps the grouped shape: a reference per mode with the catalog's verdict and result keys", faults == [], faults)
        continue
    if name in SEAM_STEPS:
        section = re.search(r"^## Verdict\n(.*?)(?=^## |\Z)", text, re.S | re.M)
        said = " ".join(re.findall(r"`([^`]+)`", section.group(1))) if section else ""
        lost = [(n, v["value"]) for n, e in serves for v in e["verdict"]["values"]
                if not re.search(r"%s: (?:[^`]*\| )?%s\b" % (re.escape(e["verdict"]["label"]), re.escape(v["value"])), said)]
        check("seam step %s: every contract it serves uses its own verdict label and values" % name, lost == [], lost)
        continue
    if name in ("branch-feature", "ultracode-build"):
        # engines with floors of their own: the verdict, the step pointer (branch-feature), a short description
        faults = skill_faults(root, name, [e for _, e in serves], 15, 10 ** 9)
        if name == "branch-feature" and STEP_POINTER not in text:
            faults.append("no step-skill pointer")
        check("%s carries its contract's verdict, the pointer once and a description of at most 15 words" % name, faults == [], faults)
        continue
    faults = skill_faults(root, name, [e for _, e in serves], 15, 1200)
    if flat(text).count(STEP_POINTER) != 1:
        faults.append("the step-skill pointer does not appear exactly once")
    if "disable-model-invocation" in text:
        faults.append("the loop cannot invoke it")
    if "$ARGUMENTS" not in text or "one JSON object" not in text:
        faults.append("no arguments line naming one JSON object")
    result = re.search(r"^## Result\n(.*?)(?=^## |\Z)", text, re.S | re.M)
    result = flat(result.group(1)) if result else ""
    if "After the verdict and its evidence, one fenced `json` block" not in result:
        faults.append("no result-block statement")
    for _, entry in serves:
        keys = entry["result"]["required"] + sorted(k for k in entry["result"]["types"] if k not in entry["result"]["required"])
        keys += entry["proof"].get("required", [])
        lost = [k for k in keys if "`%s`" % k not in result]
        if lost:
            faults.append("its Result section does not name %s" % lost)
        if entry["proof"].get("required") and "`proof`" not in result:
            faults.append("its Result section does not name the proof")
    rules = re.search(r"\*\*Step rules\.\*\*(.*)", flat(text))
    rules = rules.group(1) if rules else ""
    for rule in ("verdict first", "safe to re-run", "config wins", "never decides what runs next"):
        if rule not in rules:
            faults.append("its step rules lack %r" % rule)
    if "subagent" not in rules:
        faults.append("its step rules do not say which subagents it may start")
    if len(serves) > 1:
        for contract, _ in serves:
            line = re.search(r"`%s` → \*\*read `\$\{CLAUDE_PLUGIN_ROOT\}/(skills/%s/references/[a-z-]+\.md)` in full" % (re.escape(contract), name), flat(text))
            if not line:
                faults.append("no dispatch line for %s" % contract)
        if "Any other contract, or none → no verdict line" not in flat(text):
            faults.append("no answer for a contract it does not carry")
    check("step skill %s keeps the step-skill shape, its contract's verdict and result keys" % name, faults == [], faults)
    # every reference it or its own references cite is a contract with a Cited by list, and its own are reachable
    own = sorted(os.path.join("skills", name, "references", f) for f in os.listdir(os.path.join(root, "skills", name, "references"))) \
        if os.path.isdir(os.path.join(root, "skills", name, "references")) else []
    cited = set(re.findall(r"\$\{CLAUDE_PLUGIN_ROOT\}/(skills/[a-z-]+/references/[a-z0-9-]+\.md)", text))
    for ref in own:
        cited |= set(re.findall(r"\$\{CLAUDE_PLUGIN_ROOT\}/(skills/[a-z-]+/references/[a-z0-9-]+\.md)", open(os.path.join(root, ref), encoding="utf-8").read()))
    bad_refs = []
    for ref in sorted(cited):
        body = open(os.path.join(root, ref), encoding="utf-8").read() if os.path.isfile(os.path.join(root, ref)) else ""
        if not body.startswith("---\nload: contract\n---\n") or re.findall(r"^## .*$", body, re.M)[-1:] != ["## Cited by"]:
            bad_refs.append(ref)
    unreached = [ref for ref in own if "${CLAUDE_PLUGIN_ROOT}/" + ref not in text]
    check("%s: every reference it cites is a contract ending with Cited by, and its own are reachable" % name,
          (bad_refs, unreached) == ([], []), (bad_refs, unreached))
rule = flat(open(os.path.join(root, "skills/release/references/step-skills.md"), encoding="utf-8").read())
check("the step-skill rule carries the one-skill-many-steps clause",
      "A step skill may carry several steps of ONE workflow, one per invocation, chosen by the payload's reserved `contract` key (never the step id)" in rule
      and '"One seam, nothing else" is read per invocation' in rule)

# the step-skill check itself, on a throwaway plugin: one skill that conforms, three that do not
def write(name, body, described="Step: do the thing and print one verdict."):
    os.makedirs(os.path.join(work, "skills", name))
    with open(os.path.join(work, "skills", name, "SKILL.md"), "w", encoding="utf-8") as out:
        out.write('---\nname: %s\ndescription: "%s"\n---\n\n%s\n\n%s' % (name, described, POINTER, body))

grouped = [contracts["start@1"], contracts["complete@1"]]
lines = "`START: MOVED [<status>] | UNCHANGED | FAILED [<reason>]` and `COMPLETE: DONE | LANDED | FAILED [<reason>]`"
write("good", "## Verdict\n\n%s\n\n## Steps\n\nDo it.\n" % lines)
write("stale", "## Verdict\n\n`START: MOVED | STAYED`\n")
write("silent", "Do it.\n")
write("wordy", "## Verdict\n\n%s\n" % lines, "Step: " + "word " * 30)
check("a grouped skill carries one verdict line per contract it serves", skill_faults(work, "good", grouped, 15, 1200) == [], skill_faults(work, "good", grouped, 15, 1200))
check("a verdict that differs from the catalog is caught", any("Verdict" in f for f in skill_faults(work, "stale", grouped, 15, 1200)))
check("a missing Verdict section is caught", any("Verdict" in f for f in skill_faults(work, "silent", grouped, 15, 1200)))
check("a description that is too long is caught", any("description" in f for f in skill_faults(work, "wordy", grouped, 15, 1200)))
check("a skill that is not there is caught", skill_faults(work, "absent", grouped, 15, 1200) == ["missing"])
PY
OUT="$(python3 -B "$WORK/cases.py" "$ROOT" "$WORK/plugin" $PENDING_SKILLS 2>&1)"; RC=$?
printf '%s\n' "$OUT" | sed 's/^/  /'
N="$(printf '%s\n' "$OUT" | grep -c '^ok')"
if [ $RC -ne 0 ] || printf '%s\n' "$OUT" | grep -q '^FAIL'; then bad "a case failed or the script did not finish (exit $RC)"
elif [ "$N" -lt 80 ]; then bad "only $N cases ran, expected at least 80"
else ok "(all $N cases passed)"; fi

# the ten seam steps of scripts/tests/step-skills.sh are a separate list: no Build step has a seam
if grep -q '^STEPS="update-docs sync-knowledge-base write-release-notes pre-ship post-deploy local-environment lease-checkout return-checkout classify-release pre-merge-check"$' "$ROOT/scripts/tests/step-skills.sh"; then
  ok "the ten seam step skills are listed as before"; else bad "scripts/tests/step-skills.sh no longer lists the ten seam steps"; fi
exit $FAIL
