#!/usr/bin/env python3
"""Generates the six built-in release workflow definitions from one hand-edited source, so the
three clearance-scope orderings and the three partial entries never drift apart. Standard
library only.

Usage: build-release-workflows.py --write | --check [--root <dir>]
  --write     write workflows/<id>.json for every definition in scripts/release-workflow-source.json
  --check     generate in memory; exit 1 naming each file that differs from its committed copy

The source (scripts/release-workflow-source.json) holds every step once (name, summary, contract,
skill) and each definition's phase list and order. A hand edit of a generated file fails --check.
Exit 0 written or clean, 1 a generated file differs, 2 unreadable or invalid source.
"""
import json
import os
import sys

SOURCE = os.path.join("scripts", "release-workflow-source.json")
# The fixed key order of a generated definition and of each of its steps (workflows/build.json's).
DEFINITION_KEYS = ("schema", "id", "version", "name", "startsWhen", "endsBy", "appliesTo", "minPluginVersion", "phases")
STEP_KEYS = ("id", "name", "summary", "contract", "kind", "run", "when", "onFail")


class SourceError(Exception):
    pass


def load_source(root):
    with open(os.path.join(root, SOURCE), encoding="utf-8") as handle:
        return json.load(handle)


def build_step(step_id, step):
    for key in ("name", "summary", "contract", "skill"):
        if not isinstance(step.get(key), str) or not step[key]:
            raise SourceError("step %s: %s must be text" % (step_id, key))
    built = {
        "id": step_id,
        "name": step["name"],
        "summary": step["summary"],
        "contract": step["contract"],
        "kind": "step",
        "run": {"source": "builtin", "ref": step["skill"], "version": None},
        "when": {"mode": "always", "condition": None},
        "onFail": "stop",
    }
    return dict((key, built[key]) for key in STEP_KEYS)


def build_definitions(source):
    """Every generated definition, as {file name: canonical text}."""
    steps, names = source.get("steps"), source.get("phaseNames")
    definitions = source.get("definitions")
    if not isinstance(steps, dict) or not isinstance(names, dict) or not isinstance(definitions, dict) or not definitions:
        raise SourceError("the source needs steps, phaseNames and definitions objects")
    version, minimum = source.get("version"), source.get("minPluginVersion")
    out, used = {}, set()
    for ident, definition in definitions.items():
        phases = []
        for phase in definition.get("phases", []):
            if phase.get("id") not in names:
                raise SourceError("%s: the phase %s has no name in phaseNames" % (ident, phase.get("id")))
            listed = phase.get("steps")
            if not isinstance(listed, list) or not listed:
                raise SourceError("%s: the phase %s lists no steps" % (ident, phase["id"]))
            for step_id in listed:
                if step_id not in steps:
                    raise SourceError("%s: the step %s is not in the source's steps" % (ident, step_id))
                used.add(step_id)
            phases.append({"id": phase["id"], "name": names[phase["id"]],
                           "steps": [build_step(step_id, steps[step_id]) for step_id in listed]})
        if not phases:
            raise SourceError("%s: a definition needs at least one phase" % ident)
        document = {
            "schema": 1,
            "id": ident,
            "version": version,
            "name": definition.get("name"),
            "startsWhen": "on-demand",
            "endsBy": None,
            "appliesTo": {"workTypes": [], "tags": [], "repositories": []},
            "minPluginVersion": minimum,
            "phases": phases,
        }
        document = dict((key, document[key]) for key in DEFINITION_KEYS)
        out[os.path.join("workflows", ident + ".json")] = json.dumps(document, indent=2, ensure_ascii=False) + "\n"
    unused = sorted(set(steps) - used)
    if unused:
        raise SourceError("steps no definition lists: %s" % ", ".join(unused))
    return out


def main(argv):
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    args = list(argv)
    if "--root" in args:
        at = args.index("--root")
        if at + 1 >= len(args):
            print("build-release-workflows: --root needs a directory", file=sys.stderr)
            return 2
        root = args[at + 1]
        del args[at:at + 2]
    if args not in (["--write"], ["--check"]):
        print(__doc__.strip().splitlines()[4], file=sys.stderr)
        return 2
    try:
        generated = build_definitions(load_source(root))
    except (OSError, ValueError, SourceError) as error:
        print("build-release-workflows: %s" % error, file=sys.stderr)
        return 2
    if args == ["--write"]:
        for rel, text in sorted(generated.items()):
            with open(os.path.join(root, rel), "w", encoding="utf-8") as handle:
                handle.write(text)
        print("RELEASE WORKFLOWS: written (%d files)" % len(generated))
        return 0
    differ = []
    for rel, text in sorted(generated.items()):
        try:
            with open(os.path.join(root, rel), encoding="utf-8") as handle:
                committed = handle.read()
        except OSError:
            committed = None
        if committed != text:
            differ.append(rel)
    if differ:
        for rel in differ:
            print("DIFFERS %s: run python3 scripts/build-release-workflows.py --write" % rel)
        return 1
    print("RELEASE WORKFLOWS: clean (%d files)" % len(generated))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
