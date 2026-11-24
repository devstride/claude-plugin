#!/usr/bin/env python3
"""scripts/stamp-unreleased.py — name the release in everything written as `unreleased`.

A registry key, a step contract or a built-in workflow that is new since the last release is
written with the literal `unreleased` where its first version belongs. Preparing a release runs
this script once, with the release's version, and nothing else does the stamping:

  schemas/seam-registry.json     every  "since": "unreleased"
  schemas/step-contracts.json    every  "since": "unreleased"             (when the file exists:
                                 its new contracts and its `features`)
  workflows/*.json               every  "minPluginVersion": "unreleased"

Only those values change. The files are edited as text, so every other byte (order, spacing,
line ends) stays exactly as it was, and a second run with nothing left to stamp changes nothing.
Every file is read and parsed before any is written: a file that is not valid JSON, or one where
the text and the parsed document disagree about how many values to stamp, stops the run with
nothing changed.

Output: one `STAMPED <file>: <n> <field>` line per changed file, then
`STAMP: <n> value(s) set to <version> in <m> file(s)` or `STAMP: nothing to stamp`.
Run `python3 scripts/build-config-schema.py --write` afterwards: the generated schema and key
table repeat the registry's versions. In workflows/registry.json (the version record of the
built-in workflows) this script names only `minPluginVersion`; its rows' release, date and note
are named by `scripts/workflow-registry.py stamp`, which prepare runs next.

Usage: stamp-unreleased.py <version> [--root <plugin dir>]
Exit codes: 0 ok, 1 a malformed file (nothing written), 2 usage or a missing registry.
"""
import glob
import json
import os
import re
import sys

MARK = "unreleased"
VERSION = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")


def usage(message):
    print("stamp-unreleased: {} (usage: stamp-unreleased.py <version> [--root <plugin dir>])".format(message),
          file=sys.stderr)
    sys.exit(2)


def count_marked(node, field):
    """How many objects in the parsed document carry `field` equal to the mark."""
    if isinstance(node, dict):
        own = 1 if node.get(field) == MARK else 0
        return own + sum(count_marked(v, field) for v in node.values())
    if isinstance(node, list):
        return sum(count_marked(v, field) for v in node)
    return 0


def plan(path, field, version):
    """Return (new text, count) for one file, or raise ValueError with a plain reason."""
    try:
        with open(path, "r", encoding="utf-8", newline="") as handle:
            text = handle.read()
    except (OSError, UnicodeDecodeError) as error:
        raise ValueError("cannot read it: {}".format(error))
    try:
        document = json.loads(text)
    except ValueError as error:
        raise ValueError("not valid JSON: {}".format(error))
    pattern = re.compile(r'("{}"\s*:\s*)"{}"'.format(re.escape(field), MARK))
    stamped, found = pattern.subn(lambda m: '{}"{}"'.format(m.group(1), version), text)
    expected = count_marked(document, field)
    if found != expected:
        raise ValueError('the text holds {} "{}": "{}" but the document holds {}; stamp it by hand'
                         .format(found, field, MARK, expected))
    return stamped, found


def main(argv):
    version, root = None, os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    args = list(argv)
    while args:
        arg = args.pop(0)
        if arg in ("-h", "--help"):
            print(__doc__.strip())
            return 0
        if arg == "--root":
            if not args:
                usage("--root needs a directory")
            root = args.pop(0)
        elif arg.startswith("-"):
            usage("unknown argument: {}".format(arg))
        elif version is None:
            version = arg
        else:
            usage("too many arguments")
    if version is None:
        usage("a version is required")
    if not VERSION.match(version):
        usage("not a version (expected <major>.<minor>.<patch>): {}".format(version))
    if not os.path.isdir(root):
        usage("no such directory: {}".format(root))

    registry = os.path.join(root, "schemas", "seam-registry.json")
    if not os.path.isfile(registry):
        usage("no schemas/seam-registry.json under {}".format(root))
    targets = [(registry, "since")]
    contracts = os.path.join(root, "schemas", "step-contracts.json")
    if os.path.isfile(contracts):
        targets.append((contracts, "since"))
    targets += [(p, "minPluginVersion") for p in sorted(glob.glob(os.path.join(root, "workflows", "*.json")))]

    planned, faults = [], []
    for path, field in targets:
        name = os.path.relpath(path, root).replace(os.sep, "/")
        try:
            text, count = plan(path, field, version)
        except ValueError as error:
            faults.append("stamp-unreleased: {}: {}".format(name, error))
            continue
        if count:
            planned.append((path, name, field, text, count))
    if faults:
        for fault in faults:
            print(fault, file=sys.stderr)
        print("stamp-unreleased: nothing was changed", file=sys.stderr)
        return 1

    for path, name, field, text, count in planned:
        with open(path, "w", encoding="utf-8", newline="") as handle:
            handle.write(text)
        print("STAMPED {}: {} {}".format(name, count, field))
    if planned:
        print("STAMP: {} value(s) set to {} in {} file(s)".format(sum(p[4] for p in planned), version, len(planned)))
    else:
        print("STAMP: nothing to stamp")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
