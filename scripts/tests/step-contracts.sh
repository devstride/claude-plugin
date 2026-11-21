#!/bin/bash
# scripts/tests/step-contracts.sh — the step contract catalog (schemas/step-contracts.json) says
# what was published, the run-workflow skill and its reference keep their shape, and every skill
# the catalog names either exists with a verdict that matches its contract or is still pending.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export PYTHONDONTWRITEBYTECODE=1

# Step skills the catalog names that a later release adds. Empty: every Build step skill ships,
# keeps the step-skill shape and carries its contract's verdict line.
PENDING_SKILLS=""

cat > "$WORK/cases.py" <<'PY'
import importlib.util, json, math, os, re, sys

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
}
check("the catalog holds exactly the twelve published contracts, in order", list(contracts) == list(PUBLISHED), list(contracts))
for name, entry in contracts.items():
    said = (entry["builtinSkill"], "%s: %s" % (entry["verdict"]["label"], " | ".join("%s=%s" % (v["value"], v["class"]) for v in entry["verdict"]["values"])),
            entry["proof"]["binding"], entry["requires"], entry["claimPhase"], entry["shipIntentStage"])
    check("%s is as published: skill, verdicts and classes, binding, requirements, phase, stage" % name, said == PUBLISHED.get(name), said)
needs = dict((name, [v["value"] for v in entry["verdict"]["values"] if v["detail"] == "required"]) for name, entry in contracts.items())
check("the values that must carry a detail: a held claim's holder and the two questions",
      dict((k, v) for k, v in needs.items() if v) == {"claim@1": ["HELD"], "build@1": ["NEEDS DECISION"], "risk-check@1": ["NEEDS DECISION"]}, needs)
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
}
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
}
for name, entry in contracts.items():
    check("%s: its result keys and their types are as published" % name, (entry["result"]["required"], entry["result"]["types"]) == RESULTS.get(name), entry["result"])
# Every contract's payload, key by key: a key is only ever added, never renamed or dropped.
PAYLOADS = {
    "risk-check@1": {"item": "context.item", "profile": "context.profile.name", "reviewMoment": "context.reviewMoment",
                     "workingBase": "context.workingBase", "build": "result:build@1", "answer": "step.answer?",
                     "previousProof": "step.passedProof?", "previousResult": "step.passedResult?",
                     "baselineUnreadable": "step.passedUnreadable?"},
    "review@1": {"item": "context.item", "profile": "context.profile.name", "reviewMoment": "context.reviewMoment",
                 "workingBase": "context.workingBase", "route": "context.route", "riskCheck": "result:risk-check@1",
                 "build": "result:build@1", "localChecks": "result:local-checks@1", "localChecksProof": "proof:local-checks@1"},
    "local-checks@1": {"item": "context.item", "profile": "context.profile.name", "workingBase": "context.workingBase", "route": "context.route",
                       "oneOff": "context.oneOff", "branch": "result:branch@1.branch", "previousProof": "step.proof?", "reviewMoment": "context.reviewMoment"},
    "merge@1": {"item": "context.item", "profile": "context.profile.name", "workingBase": "context.workingBase", "route": "context.route",
                "branch": "result:branch@1.branch", "review": "result:review@1", "build": "result:build@1", "riskCheck": "result:risk-check@1",
                "commit": "step.head?", "reviewProof": "proof:review@1", "localChecks": "result:local-checks@1"},
    "complete@1": {"item": "context.item", "profile": "context.profile.name", "workingBase": "context.workingBase", "oneOff": "context.oneOff",
                   "releaseUnit": "context.releaseUnit", "route": "context.route", "profileSource": "context.profile.source", "merge": "result:merge@1",
                   "build": "result:build@1", "riskCheck": "result:risk-check@1", "review": "result:review@1"},
}
for name, payload in PAYLOADS.items():
    check("%s: its payload is as published" % name, contracts[name]["payload"] == payload, contracts[name]["payload"])
check("the two skills that take text keep their argument templates",
      dict((n, e["argument"]) for n, e in contracts.items() if e["argument"]) ==
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
check("no shipped contract carries satisfiedBy", not any("satisfiedBy" in e for e in contracts.values()))

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
SECTIONS = {reference: ["## Commands", "## A step's answer", "## Stops", "## Reporting", "## Heartbeat and ship intent", "## Resuming", "## Cited by"],
            authoring: ["## What `start` refuses", "## What is reported", "## Payloads", "## Proofs",
                        "## satisfiedBy — one step standing in for another's proof", "## Cited by"]}
check("every section of the reference before the split is in exactly one half",
      re.findall(r"^## .*$", text, re.M) == SECTIONS[reference] and re.findall(r"^## .*$", rules, re.M) == SECTIONS[authoring],
      (re.findall(r"^## .*$", text, re.M), re.findall(r"^## .*$", rules, re.M)))
check("the skill names the five commands' loop and the reference names all five",
      all("`%s`" % c in text for c in runner.COMMANDS) and all("`%s`" % c in skill for c in ("start", "done", "status", "resume")))
codes = ["bad-schema", "duplicate-step-id", "unknown-contract", "unknown-contract-major", "requires-missing", "requires-not-earlier",
         "required-not-always", "required-not-stop", "required-off", "skill-missing", "plugin-too-old", "repository-required",
         "unsupported-gate", "unsupported-when", "unsupported-source", "unsupported-on-fail", "credential-in-definition"]
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
check("nothing is pending: every skill the catalog names ships", pending == [], pending)
flat = lambda s: re.sub(r"\s+", " ", s)
PLAN_SKILLS = ["plan-steps", "comprehend-plan", "rationalize-gantt", "insert-story"]
BUILD_STEPS = ["claim-story", "story-lifecycle", "risk-check", "local-checks", "review-story", "merge-story", "capture-findings", "sync-base"]
check("the eight Build step skills are the catalog's own skills, less the two engines", sorted(BUILD_STEPS) == sorted(set(named) - {"branch-feature", "ultracode-build"} - set(PLAN_SKILLS)), named)
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
    if name == "plan-steps":
        # the grouped Plan and Rebalance step skill: each mode's verdict and result keys live in its reference
        faults = skill_faults(root, name, None, 15, 1200)
        if flat(text).count(STEP_POINTER) != 1 or "disable-model-invocation" in text or "$ARGUMENTS" not in text or "one JSON object" not in text:
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
            if "`%s` → read `${CLAUDE_PLUGIN_ROOT}/%s`" % (contract, ref) not in flat(text):
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
            if "Workflow" in re.sub(r"\(`delegates: true`\)[^.]*\.", "", body.replace("no subagent and no Workflow", "")) and not entry.get("delegates"):
                faults.append("%s: a non-delegating step tells the model to start a Workflow" % ref)
        if "Any other contract, or none → no verdict line" not in flat(text):
            faults.append("no answer for a contract it does not carry")
        check("step skill plan-steps keeps the grouped shape: a reference per mode with the catalog's verdict and result keys", faults == [], faults)
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
