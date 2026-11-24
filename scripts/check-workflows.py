#!/usr/bin/env python3
"""Checks every built-in workflow definition (workflows/*.json but registry.json): the rules a JSON Schema cannot
say, and that schemas/workflow.schema.json lists the same values this script does. Standard
library only. Run by scripts/validate.sh.

  python3 scripts/check-workflows.py [--root <dir>]

First line `WORKFLOWS: ok (<n> files, <m> steps)`, or one `INVALID <file>: <path>: <reason>` line
per fault. Exit 0 ok, 1 invalid, 2 unreadable input.
"""
import glob
import importlib.util
import json
import os
import re
import sys

STARTS_WHEN = ["item-picked-up", "children-complete", "on-demand"]
ENDS_BY = ["ship", "hand-up", None]
# The pairing: children-complete ends by ship or hand-up; any other trigger ends by null.
PAIRING = ({"properties": {"startsWhen": {"const": "children-complete"}}, "required": ["startsWhen"]},
           {"properties": {"endsBy": {"enum": ["ship", "hand-up"]}}},
           {"properties": {"endsBy": {"const": None}}})
KINDS = ["step", "gate"]
RUN_SOURCES = ["builtin", "library", "repo", "off"]
WHEN_MODES = ["always", "condition", "manual"]
# A built-in workflow's conditions: the closed list. An organization's workflow may use the whole
# grammar (skills/run-workflow/references/conditions.md), which the schema's pattern documents and
# the runner checks; a built-in one never needs more than the review path, never a manual step and
# never a step that carries on after a failure.
CONDITIONS = ["review-path:fast", "review-path:pull-request"]
CONDITION_MAX = 200
ON_FAIL = ["stop", "continue"]
# An approval gate: kind gate, contract approval@1 (and only a gate's), run by the reserved built-in
# reference gate. answerers, only on a gate: at most 20, each one of these kinds.
GATE_CONTRACT, GATE_RUN = "approval@1", ("builtin", "gate")
ANSWERER_KINDS = ["edit-access", "item-owner", "role", "person"]
ANSWERER_FIELDS = {"role": "roleId", "person": "username"}
MAX_ANSWERERS = 20
WORKFLOW_ID = re.compile(r"^[a-z][a-z0-9-]{0,99}$")
SLUG = re.compile(r"^[a-z][a-z0-9-]{0,63}$")
CONTRACT = re.compile(r"^[a-z][a-z0-9-]*@[0-9]+$")
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
MAX_BYTES, MAX_PHASES, MAX_STEPS_PER_PHASE, MAX_STEPS, MAX_VERSION = 65536, 12, 40, 250, 1000000
NAME_MAX, SUMMARY_MAX = 200, 500


def load_helper(root):
    path = os.path.join(root, "skills", "build-item", "scripts", "workflow_report.py")
    spec = importlib.util.spec_from_file_location("workflow_report", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def version_tuple(text):
    return tuple(int(part) for part in text.split("."))


def text(value, limit, allow_empty=False):
    return isinstance(value, str) and len(value) <= limit and (allow_empty or bool(value))


def whole(value):
    return isinstance(value, int) and not isinstance(value, bool)


def check_definition(name, document, plugin_version, helper):
    faults = []

    def fault(path, reason):
        faults.append((path, reason))

    if not isinstance(document, dict):
        return [("$", "a definition is one JSON object")], 0
    try:
        size = len(helper.canonical_json(document))
        if size > MAX_BYTES:
            fault("$", "the canonical form is %d bytes; at most %d" % (size, MAX_BYTES))
    except ValueError as error:
        fault("$", str(error))
    if document.get("schema") != 1 or isinstance(document.get("schema"), bool):
        fault("schema", "must be 1")
    ident = document.get("id")
    if not isinstance(ident, str) or not WORKFLOW_ID.match(ident):
        fault("id", "must be a lower-case slug")
    elif ident + ".json" != name:
        fault("id", "the file name must be the id plus .json (%s.json)" % ident)
    if not whole(document.get("version")) or not 1 <= document["version"] <= MAX_VERSION:
        fault("version", "must be a whole number from 1 to %d" % MAX_VERSION)
    if not text(document.get("name"), NAME_MAX):
        fault("name", "must be text of 1 to %d characters" % NAME_MAX)
    if document.get("startsWhen") not in STARTS_WHEN:
        fault("startsWhen", "must be one of %s" % ", ".join(STARTS_WHEN))
    if "endsBy" not in document or document["endsBy"] not in ENDS_BY:
        fault("endsBy", "must be ship, hand-up or null")
    elif document.get("startsWhen") in STARTS_WHEN and (document["startsWhen"] == "children-complete") != (document["endsBy"] is not None):
        fault("endsBy", "a children-complete workflow ends by ship or hand-up, and any other ends by null")
    applies = document.get("appliesTo")
    if not isinstance(applies, dict) or any(
            not isinstance(applies.get(key), list) or any(not isinstance(v, str) for v in applies[key])
            for key in ("workTypes", "tags", "repositories")):
        fault("appliesTo", "must hold workTypes, tags and repositories, each a list of text")
    minimum = document.get("minPluginVersion")
    if not isinstance(minimum, str) or not SEMVER.match(minimum):
        fault("minPluginVersion", "must be x.y.z")
    elif plugin_version and version_tuple(minimum) > version_tuple(plugin_version):
        fault("minPluginVersion", "%s is newer than this plugin (%s)" % (minimum, plugin_version))
    phases = document.get("phases")
    if not isinstance(phases, list) or not phases:
        fault("phases", "must be a list of at least one phase")
        return faults, 0
    if len(phases) > MAX_PHASES:
        fault("phases", "at most %d phases" % MAX_PHASES)
    seen, total = {}, 0
    for p, phase in enumerate(phases):
        where = "phases[%d]" % p
        if not isinstance(phase, dict):
            fault(where, "a phase is an object")
            continue
        if not isinstance(phase.get("id"), str) or not SLUG.match(phase["id"]):
            fault(where + ".id", "must be a lower-case slug")
        if not text(phase.get("name"), NAME_MAX):
            fault(where + ".name", "must be text of 1 to %d characters" % NAME_MAX)
        steps = phase.get("steps")
        if not isinstance(steps, list) or not steps:
            fault(where + ".steps", "must be a list of at least one step")
            continue
        if len(steps) > MAX_STEPS_PER_PHASE:
            fault(where + ".steps", "at most %d steps in a phase" % MAX_STEPS_PER_PHASE)
        for s, step in enumerate(steps):
            at = "%s.steps[%d]" % (where, s)
            total += 1
            if not isinstance(step, dict):
                fault(at, "a step is an object")
                continue
            ident = step.get("id")
            if not isinstance(ident, str) or not SLUG.match(ident):
                fault(at + ".id", "must match ^[a-z][a-z0-9-]{0,63}$")
            elif ident in seen:
                fault(at + ".id", "duplicate step id %s (also at %s)" % (ident, seen[ident]))
            else:
                seen[ident] = at
            if not text(step.get("name"), NAME_MAX):
                fault(at + ".name", "must be text of 1 to %d characters" % NAME_MAX)
            if not text(step.get("summary"), SUMMARY_MAX, allow_empty=True):
                fault(at + ".summary", "must be text of at most %d characters" % SUMMARY_MAX)
            if not isinstance(step.get("contract"), str) or not CONTRACT.match(step["contract"]):
                fault(at + ".contract", "must be <name>@<major>")
            if step.get("kind") not in KINDS:
                fault(at + ".kind", "must be one of %s" % ", ".join(KINDS))
            run = step.get("run")
            if not isinstance(run, dict) or run.get("source") not in RUN_SOURCES:
                fault(at + ".run.source", "must be one of %s" % ", ".join(RUN_SOURCES))
            else:
                if "ref" not in run or not (run["ref"] is None or isinstance(run["ref"], str)):
                    fault(at + ".run.ref", "must be text or null")
                elif run["source"] != "off" and not run["ref"]:
                    fault(at + ".run.ref", "must name what runs the step unless the source is off")
                if "version" not in run or not (run["version"] is None or isinstance(run["version"], str) or whole(run["version"])):
                    fault(at + ".run.version", "must be a whole number, text or null")
            when = step.get("when")
            if not isinstance(when, dict) or when.get("mode") not in WHEN_MODES:
                fault(at + ".when.mode", "must be one of %s" % ", ".join(WHEN_MODES))
            elif "condition" not in when:
                fault(at + ".when.condition", "must be present (null unless the mode is condition)")
            elif when["mode"] == "condition":
                if when.get("condition") not in CONDITIONS:
                    fault(at + ".when.condition", "must be one of %s when the mode is condition" % ", ".join(CONDITIONS))
            elif when.get("condition") is not None:
                fault(at + ".when.condition", "must be null unless the mode is condition")
            elif when["mode"] == "manual":
                fault(at + ".when.mode", "a built-in workflow has no step a person does by hand")
            if step.get("onFail") not in ON_FAIL:
                fault(at + ".onFail", "must be one of %s" % ", ".join(ON_FAIL))
            elif step["onFail"] != "stop":
                fault(at + ".onFail", "a built-in workflow's steps stop the run when they fail")
            for where, reason in gate_faults(step):
                fault(at + where, reason)
    if total > MAX_STEPS:
        fault("phases", "at most %d steps in all" % MAX_STEPS)
    return faults, total


def gate_faults(step):
    """What breaks the gate rules: a gate is an approval@1 step run by the built-in gate, an approval@1
    step is a gate, and only a gate (or a manual step) names its answerers, a list of at most 20 known kinds."""
    faults = []
    gate = step.get("kind") == "gate"
    if gate and step.get("contract") != GATE_CONTRACT:
        faults.append((".contract", "a gate's contract is %s" % GATE_CONTRACT))
    if not gate and step.get("contract") == GATE_CONTRACT:
        faults.append((".kind", "%s is a gate's contract, so the step's kind is gate" % GATE_CONTRACT))
    run = step.get("run") if isinstance(step.get("run"), dict) else {}
    if gate and (run.get("source"), run.get("ref")) != GATE_RUN:
        faults.append((".run", "a gate runs the reserved built-in reference: source builtin, ref gate"))
    if "answerers" not in step:
        return faults
    answerers = step["answerers"]
    manual = isinstance(step.get("when"), dict) and step["when"].get("mode") == "manual"
    if not gate and not manual:
        faults.append((".answerers", "only a gate or a manual step names who may answer it"))
    elif not isinstance(answerers, list) or len(answerers) > MAX_ANSWERERS:
        faults.append((".answerers", "must be a list of at most %d entries" % MAX_ANSWERERS))
    else:
        for n, entry in enumerate(answerers):
            kind = entry.get("kind") if isinstance(entry, dict) else None
            field = ANSWERER_FIELDS.get(kind)
            if kind not in ANSWERER_KINDS or (field and not text(entry.get(field), NAME_MAX)):
                faults.append((".answerers[%d]" % n, "must be edit-access, item-owner, a role with its roleId or a person with their username"))
    return faults


def check_schema(root):
    """The lists in the published schema must equal this script's, so the two cannot drift."""
    path = os.path.join(root, "schemas", "workflow.schema.json")
    with open(path, encoding="utf-8") as handle:
        schema = json.load(handle)
    props = schema["properties"]
    step = props["phases"]["items"]["properties"]["steps"]["items"]["properties"]
    pairs = [
        ("startsWhen", props["startsWhen"]["enum"], STARTS_WHEN),
        ("endsBy", props["endsBy"]["enum"], ENDS_BY),
        ("kind", step["kind"]["enum"], KINDS),
        ("run.source", step["run"]["properties"]["source"]["enum"], RUN_SOURCES),
        ("when.mode", step["when"]["properties"]["mode"]["enum"], WHEN_MODES),
        ("when.condition.type", step["when"]["properties"]["condition"]["type"], ["string", "null"]),
        ("when.condition.maxLength", step["when"]["properties"]["condition"]["maxLength"], CONDITION_MAX),
        ("onFail", step["onFail"]["enum"], ON_FAIL),
        ("answerers.kind", [one["properties"]["kind"]["const"] for one in step["answerers"]["items"]["oneOf"]], ANSWERER_KINDS),
        ("answerers.maxItems", step["answerers"]["maxItems"], MAX_ANSWERERS),
    ]
    faults = [(name, "the schema lists %s; check-workflows.py lists %s" % (json.dumps(have), json.dumps(want)))
              for name, have, want in pairs if have != want]
    pattern = re.compile(step["when"]["properties"]["condition"]["pattern"])
    with open(os.path.join(root, "schemas", "when-condition-fixtures.json"), encoding="utf-8") as handle:
        valid = [case["text"] for case in json.load(handle)["cases"] if case["valid"]]
    missed = [text for text in CONDITIONS + valid if not pattern.search(text)]
    if missed:
        faults.append(("when.condition.pattern", "the schema's pattern refuses conditions the grammar accepts: %s" % json.dumps(missed[:3])))
    pairing = (schema.get("if"), schema.get("then"), schema.get("else"))
    if pairing != PAIRING:
        faults.append(("startsWhen/endsBy", "the schema's if/then/else is not the pairing this script checks"))
    return faults


def main(argv):
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if argv[:1] == ["--root"] and len(argv) == 2:
        root = argv[1]
    elif argv:
        print("check-workflows: usage: check-workflows.py [--root <dir>]", file=sys.stderr)
        return 2
    try:
        helper = load_helper(root)
        with open(os.path.join(root, ".claude-plugin", "plugin.json"), encoding="utf-8") as handle:
            plugin_version = json.load(handle).get("version")
        lines = ["INVALID schemas/workflow.schema.json: %s: %s" % fault for fault in check_schema(root)]
        # workflows/registry.json is the version record of these definitions, not one of them.
        files = sorted(p for p in glob.glob(os.path.join(root, "workflows", "*.json")) if os.path.basename(p) != "registry.json")
        if not files:
            raise OSError("no workflows/*.json under %s" % root)
        steps = 0
        for path in files:
            name = os.path.basename(path)
            with open(path, encoding="utf-8") as handle:
                document = json.load(handle)
            faults, count = check_definition(name, document, plugin_version, helper)
            steps += count
            lines += ["INVALID workflows/%s: %s: %s" % (name, where, reason) for where, reason in faults]
    except (OSError, ValueError, KeyError, TypeError, AttributeError, RecursionError) as error:
        print("check-workflows: cannot read its input: %s" % error, file=sys.stderr)
        return 2
    if lines:
        print("\n".join(lines))
        return 1
    print("WORKFLOWS: ok (%d files, %d steps)" % (len(files), steps))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
