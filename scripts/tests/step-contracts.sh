#!/bin/bash
# scripts/tests/step-contracts.sh — the step contract catalog (schemas/step-contracts.json) says
# what was published, the run-workflow skill and its reference keep their shape, and every skill
# the catalog names either exists with a verdict that matches its contract or is still pending.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export PYTHONDONTWRITEBYTECODE=1

# The step skills a later release adds. That release empties this list; from then on each must
# exist, keep the step-skill shape and carry its contract's verdict line.
PENDING_SKILLS="claim-story story-lifecycle risk-check local-checks review-story merge-story capture-findings sync-base"

cat > "$WORK/cases.py" <<'PY'
import importlib.util, json, math, os, re, sys

root, work, pending = sys.argv[1], sys.argv[2], sys.argv[3:]
POINTER = "**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message."


def check(label, good, detail=""):
    print(("ok   " if good else "FAIL ") + label + ("" if good else " -> %s" % (detail,)))


def tokens(raw):
    return math.ceil(len(raw) / 3)  # the plugin's own measure (scripts/measure-cost.sh)


def frontmatter(text):
    match = re.match(r"---\n(.*?)\n---\n", text, re.S)
    return dict(re.findall(r"^(\w[\w-]*):\s*(.*)$", match.group(1), re.M)) if match else None


def verdict_line(entry):
    """A contract's verdict as one line: the label, then each value with <detail> where it must
    carry one and [<detail>] where it may."""
    marks = {"none": "", "required": " <detail>", "optional": " [<detail>]"}
    return "%s: %s" % (entry["verdict"]["label"], " | ".join(v["value"] + marks[v["detail"]] for v in entry["verdict"]["values"]))


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

# What was published, value by value: a change here is a change to the contract.
PUBLISHED = {
    "claim@1": ("claim-story", "CLAIM: WON=continue | RENEWED=continue | TOOK OVER=continue | HELD=end:held | NOT CONFIGURED=skipped | DEGRADED=skipped", "none", [], None, None),
    "start@1": ("story-lifecycle", "START: MOVED=continue | UNCHANGED=continue | FAILED=stop", "none", [], "Mark In Progress", None),
    "branch@1": ("branch-feature", "BRANCH: CREATED=continue | EXISTS=continue | REFUSED=stop", "none", [], "Branch", None),
    "build@1": ("ultracode-build", "BUILD: READY=continue | NEEDS DECISION=ask | BLOCKED=stop", "none", ["branch@1"], "Build", "building"),
    "risk-check@1": ("risk-check", "RISK CHECK: CLEAR=continue | FIXED=continue | NEEDS DECISION=ask | BLOCKED=stop", "none", ["build@1"], "STORY RISK CHECK", None),
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
check("the two skills that take text keep their argument templates",
      dict((n, e["argument"]) for n, e in contracts.items() if e["argument"]) ==
      {"branch@1": "{branchSlug} base: {workingBase}", "build@1": "{item} {goal} profile: {profile} review-moment: {reviewMoment}"})
check("the three proofs name their fields",
      dict((n, e["proof"].get("required")) for n, e in contracts.items() if "required" in e["proof"]) ==
      {"risk-check@1": ["base", "head", "triggers", "verifiers", "lenses"], "local-checks@1": ["kind", "tree", "head", "receipt"], "review@1": ["path", "head", "base", "patchId"]})
check("no shipped contract carries satisfiedBy", not any("satisfiedBy" in e for e in contracts.values()))

# run-workflow: the entry skill and its reference
faults = skill_faults(root, "run-workflow", None, 15, 1200)
check("run-workflow: name, a description of at most 15 words, a body of at most 1,200 tokens, the pointer once", faults == [], faults)
skill = open(os.path.join(root, "skills/run-workflow/SKILL.md"), encoding="utf-8").read()
check("run-workflow can be invoked by the loop (no disable-model-invocation)", "disable-model-invocation" not in skill)
reference = "skills/run-workflow/references/workflow-runner.md"
text = open(os.path.join(root, reference), encoding="utf-8").read()
check("the reference opens with load: contract", text.startswith("---\nload: contract\n---\n"))
last = re.findall(r"^## .*$", text, re.M)[-1]
cited = text[text.rindex("\n## Cited by"):]
check("the reference ends with ## Cited by, naming the skill", last == "## Cited by" and "`skills/run-workflow/SKILL.md`" in cited, last)
check("the reference is reachable from the skill", "${CLAUDE_PLUGIN_ROOT}/" + reference in skill)
check("the skill names the five commands' loop and the reference names all five",
      all("`%s`" % c in text for c in runner.COMMANDS) and all("`%s`" % c in skill for c in ("start", "done", "status", "resume")))
codes = ["bad-schema", "duplicate-step-id", "unknown-contract", "unknown-contract-major", "requires-missing", "requires-not-earlier",
         "required-not-always", "required-not-stop", "required-off", "skill-missing", "plugin-too-old", "repository-required",
         "unsupported-gate", "unsupported-when", "unsupported-source", "unsupported-on-fail"]
source = open(os.path.join(root, "skills/run-workflow/scripts/workflow.py"), encoding="utf-8").read()
check("every validation code is in the runner and in the reference", all('"%s"' % c in source and "`%s`" % c in text for c in codes),
      [c for c in codes if '"%s"' % c not in source or "`%s`" % c not in text])
kinds = ["failed", "needs-person", "attempts-exhausted", "no-verdict", "proof"]
check("every stop kind is in the reference's table", all("| `%s` |" % k in text for k in kinds))
check("both named proof rules are in the runner and the reference", all(r in source and "`%s`" % r in text for r in ("risk-triggers-need-verifiers", "none-configured-needs-pull-request-route")))

# the skills the catalog names
present = sorted(n for n in os.listdir(os.path.join(root, "skills")) if os.path.isfile(os.path.join(root, "skills", n, "SKILL.md")))
named = sorted(set(e["builtinSkill"] for e in contracts.values() if e["builtinSkill"]))
check("every skill the catalog names exists or is pending", all(n in present or n in pending for n in named), [n for n in named if n not in present and n not in pending])
check("a pending skill is not shipped yet (when it ships, take it off PENDING_SKILLS)", not [n for n in pending if n in present], [n for n in pending if n in present])
check("the pending list names only skills the catalog names", all(n in named for n in pending), pending)
existing = ("branch-feature", "ultracode-build")  # shipped before the catalog, with their own verdict text
for name in named:
    if name in pending or name in existing:
        continue
    serves = [e for e in contracts.values() if e["builtinSkill"] == name]
    faults = skill_faults(root, name, serves, 25, 1200)
    check("step skill %s keeps its shape and its contract's verdict" % name, faults == [], faults)

# the step-skill check itself, on a throwaway plugin: one skill that conforms, three that do not
def write(name, body, described="Step: do the thing and print one verdict."):
    os.makedirs(os.path.join(work, "skills", name))
    with open(os.path.join(work, "skills", name, "SKILL.md"), "w", encoding="utf-8") as out:
        out.write('---\nname: %s\ndescription: "%s"\n---\n\n%s\n\n%s' % (name, described, POINTER, body))

grouped = [contracts["start@1"], contracts["complete@1"]]
lines = "`START: MOVED [<detail>] | UNCHANGED | FAILED [<detail>]` and `COMPLETE: DONE | LANDED | FAILED [<detail>]`"
write("good", "## Verdict\n\n%s\n\n## Steps\n\nDo it.\n" % lines)
write("stale", "## Verdict\n\n`START: MOVED | STAYED`\n")
write("silent", "Do it.\n")
write("wordy", "## Verdict\n\n%s\n" % lines, "Step: " + "word " * 30)
check("a grouped skill carries one verdict line per contract it serves", skill_faults(work, "good", grouped, 25, 1200) == [], skill_faults(work, "good", grouped, 25, 1200))
check("a verdict that differs from the catalog is caught", any("Verdict" in f for f in skill_faults(work, "stale", grouped, 25, 1200)))
check("a missing Verdict section is caught", any("Verdict" in f for f in skill_faults(work, "silent", grouped, 25, 1200)))
check("a description that is too long is caught", any("description" in f for f in skill_faults(work, "wordy", grouped, 25, 1200)))
check("a skill that is not there is caught", skill_faults(work, "absent", grouped, 25, 1200) == ["missing"])
PY
OUT="$(python3 -B "$WORK/cases.py" "$ROOT" "$WORK/plugin" $PENDING_SKILLS 2>&1)"; RC=$?
printf '%s\n' "$OUT" | sed 's/^/  /'
N="$(printf '%s\n' "$OUT" | grep -c '^ok')"
if [ $RC -ne 0 ] || printf '%s\n' "$OUT" | grep -q '^FAIL'; then bad "a case failed or the script did not finish (exit $RC)"
elif [ "$N" -lt 35 ]; then bad "only $N cases ran, expected at least 35"
else ok "(all $N cases passed)"; fi

# the ten seam steps of scripts/tests/step-skills.sh are a separate list: no Build step has a seam
if grep -q '^STEPS="update-docs sync-knowledge-base write-release-notes pre-ship post-deploy local-environment lease-checkout return-checkout classify-release pre-merge-check"$' "$ROOT/scripts/tests/step-skills.sh"; then
  ok "the ten seam step skills are listed as before"; else bad "scripts/tests/step-skills.sh no longer lists the ten seam steps"; fi
exit $FAIL
