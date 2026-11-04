#!/usr/bin/env python3
"""Which item is a plan's deferred container, and what sits under it — deterministic, dependency-free.

The single implementation of the identity and membership rules in
`skills/build-item/references/deferred-container.md`. Claude follows that document; any caller
runs this file instead of deciding by eye.

Every subcommand reads one JSON object on stdin and writes one JSON line on stdout:

  match    {"title", "legacyTitles"?: […], "children": [{"number", "title"}…]}
           -> {"container", "all": […], "duplicates": […], "matchedBy": "title"|"legacy"|null,
               "create": bool}
  members  {"containers": […], "nodes": [{"number", "parentNumber"}…]}
           -> {"members": […]}

`children` are the plan root's DIRECT children only (archived items left out by the caller). A
title matches when, trimmed, inner whitespace collapsed and case ignored, it equals `title` or a
legacy title; the legacy set is the built-in "Deferred defects" plus `legacyTitles` (an empty entry
is skipped), so a configured list can only add to it. The lowest item number is the container; the rest are
`duplicates`. `members` is every node whose parent chain reaches a listed container, the
containers included, cycle-safe. Exit 0 on a decision; 2 on bad input with one
`{"error": …}` line.
"""
import json
import re
import sys

BUILT_IN_LEGACY = "Deferred defects"


def fail(message):
    print(json.dumps({"error": message}))
    sys.exit(2)


def norm(title):
    return re.sub(r"\s+", " ", title).strip().casefold()


def number_key(number):
    number = str(number)
    digits = re.sub(r"\D", "", number)
    return (int(digits) if digits else 0, number)


def text(value, what):
    if not isinstance(value, str) or not value.strip():
        fail("%s must be a non-empty string" % what)
    return value


def match(request):
    title = norm(text(request.get("title"), "title"))
    legacy = request.get("legacyTitles", [])
    if not isinstance(legacy, list):
        fail("legacyTitles must be an array of strings")
    if not all(isinstance(t, str) for t in legacy):
        fail("legacyTitles must be an array of strings")
    # an empty entry matches nothing and is skipped (doctor warns about it), never a refusal
    legacy_set = {norm(BUILT_IN_LEGACY)} | {norm(t) for t in legacy if t.strip()}
    children = request.get("children")
    if not isinstance(children, list):
        fail("children must be an array")
    hits = []
    for child in children:
        if not isinstance(child, dict):
            fail("every child must be an object")
        number = text(child.get("number"), "a child's number")
        if not isinstance(child.get("title"), str):
            fail("every child needs a title")
        name = norm(child["title"])
        if name == title:
            hits.append((number, "title"))
        elif name in legacy_set:
            hits.append((number, "legacy"))
    hits.sort(key=lambda hit: number_key(hit[0]))
    numbers = [number for number, _ in hits]
    return {
        "container": numbers[0] if numbers else None,
        "all": numbers,
        "duplicates": numbers[1:],
        "matchedBy": hits[0][1] if hits else None,
        "create": not numbers,
    }


def members(request):
    containers = request.get("containers")
    nodes = request.get("nodes")
    if not isinstance(containers, list) or not all(isinstance(c, str) and c for c in containers):
        fail("containers must be an array of item numbers")
    if not isinstance(nodes, list):
        fail("nodes must be an array")
    parent = {}
    for node in nodes:
        if not isinstance(node, dict) or "parentNumber" not in node:
            fail("every node must be an object with a parentNumber (null at the top)")
        parent[text(node.get("number"), "a node's number")] = node.get("parentNumber")
    roots = set(containers)
    found = []
    for number in sorted(parent, key=number_key):
        seen, cursor = set(), number
        while isinstance(cursor, str) and cursor not in seen:
            if cursor in roots:
                found.append(number)
                break
            seen.add(cursor)
            cursor = parent.get(cursor)
    for container in containers:
        if container not in parent:
            found.append(container)
    return {"members": sorted(set(found), key=number_key)}


def main():
    commands = {"match": match, "members": members}
    if len(sys.argv) != 2 or sys.argv[1] not in commands:
        fail("usage: deferred-container.py match|members < request.json")
    try:
        request = json.load(sys.stdin)
    except ValueError as error:
        fail("stdin is not JSON: %s" % error)
    if not isinstance(request, dict):
        fail("stdin must be one JSON object")
    print(json.dumps(commands[sys.argv[1]](request)))


if __name__ == "__main__":
    main()
