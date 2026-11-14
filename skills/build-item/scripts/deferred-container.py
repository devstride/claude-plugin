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
  settle   {"root": {"number", "done"}, "containers": […],
            "nodes": [{"number", "parentNumber", "leaf", "done"}…]}
           -> {"close": […], "reopen": […], "openDeferred": […], "openValue": […],
               "root": "close"|"reopen"|"keep-open"|"done"}

`children` are the plan root's DIRECT children only (archived items left out by the caller). A
title matches when, trimmed, inner whitespace collapsed and case ignored, it equals `title` or a
legacy title; the legacy set is the built-in "Deferred defects" plus `legacyTitles` (an empty entry
is skipped), so a configured list can only add to it. The lowest item number is the container; the rest are
`duplicates`. `members` is every node whose parent chain reaches a listed container, the
containers included, cycle-safe.

`settle` decides what closes (the reference's "Closing"). `nodes` are every non-archived
descendant of the plan root, the root itself left out; `containers` is `match`'s `all` (duplicates
included, so their contents count as deferred too; empty when there is none); `done` means a done-type status, a set
`completedAt` or a set `endedOutcome`; `leaf` means a `hierarchyRoles.leaf` work type. Inside the
container (the container included), a node that is not a leaf closes when everything under it is
done; outside it, one that has children closes the same way (an epic whose stories are all Done,
which no release closes when stories merge straight to the base). `close` is deepest first, so
each node follows what is under it; a container node already done with something open under it
reopens (`reopen`, the container first). `openDeferred` and `openValue` are the open leaves inside
and outside the container, and `openValue` also names any open childless node outside it. The plan
root closes only when nothing outside the container is open AND nothing inside it will still be
open after `close`; a done root with anything open reopens. Unbuilt deferred work keeps the plan
open: `settle` never closes a leaf. Exit 0 on a decision; 2 on bad input with one
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


def settle(request):
    root = request.get("root")
    if not isinstance(root, dict) or not isinstance(root.get("done"), bool):
        fail("root must be an object with a number and a boolean done")
    root_number = text(root.get("number"), "root.number")
    containers = request.get("containers")
    if not isinstance(containers, list):
        fail("containers must be an array of item numbers (empty when there is none)")
    containers = [text(c, "a container") for c in containers]
    nodes = request.get("nodes")
    if not isinstance(nodes, list):
        fail("nodes must be an array")
    info, children = {}, {}
    for node in nodes:
        if not isinstance(node, dict) or "parentNumber" not in node:
            fail("every node must be an object with a parentNumber")
        number = text(node.get("number"), "a node's number")
        if number == root_number:
            fail("nodes must leave the plan root out")
        if not isinstance(node.get("leaf"), bool) or not isinstance(node.get("done"), bool):
            fail("node %s needs boolean leaf and done" % number)
        info[number] = node
        children.setdefault(node.get("parentNumber"), []).append(number)
    if any(c not in info for c in containers):
        fail("every container must be one of the nodes")
    inside = set(members({"containers": containers, "nodes": [
        {"number": n, "parentNumber": info[n].get("parentNumber")} for n in info]})["members"]) if containers else set()

    # finished(n): n is done, or n is a container node inside the deferred container that will
    # close because everything under it is finished; computed bottom-up, cycle-safe.
    memo = {}

    def finished(number, seen=frozenset()):
        if number in memo:
            return memo[number]
        if number in seen:
            return info[number]["done"]
        node = info[number]
        kids = children.get(number, [])
        if node["leaf"] or (number not in inside and not kids):
            result = node["done"]
        else:
            result = all(finished(c, seen | {number}) for c in kids)
        memo[number] = result
        return result

    def open_under(number, seen):
        for child in children.get(number, []):
            if child in seen:
                continue
            seen.add(child)
            if not finished(child) or open_under(child, seen):
                return True
        return False

    def depth(number):
        seen, cursor, d = set(), number, 0
        while cursor in info and cursor not in seen:
            seen.add(cursor)
            cursor, d = info[cursor].get("parentNumber"), d + 1
        return d

    close, reopen, open_deferred, open_value = [], [], [], []
    for number in sorted(info, key=number_key):
        node = info[number]
        pending = open_under(number, {number})
        if number in inside:
            if node["leaf"]:
                if not node["done"]:
                    open_deferred.append(number)
            elif not node["done"] and not pending:
                close.append(number)
            elif node["done"] and pending:
                reopen.append(number)
        elif node["done"]:
            continue
        elif node["leaf"] or not children.get(number):
            open_value.append(number)
        elif not pending:
            close.append(number)
    close.sort(key=lambda n: (-depth(n), number_key(n)))
    reopen.sort(key=lambda n: (depth(n), number_key(n)))
    still_open = bool(open_value or open_deferred)
    if root["done"]:
        verdict = "reopen" if still_open else "done"
    else:
        verdict = "keep-open" if still_open else "close"
    return {"close": close, "reopen": reopen, "openDeferred": open_deferred,
            "openValue": open_value, "root": verdict}


def main():
    commands = {"match": match, "members": members, "settle": settle}
    if len(sys.argv) != 2 or sys.argv[1] not in commands:
        fail("usage: deferred-container.py match|members|settle < request.json")
    try:
        request = json.load(sys.stdin)
    except ValueError as error:
        fail("stdin is not JSON: %s" % error)
    if not isinstance(request, dict):
        fail("stdin must be one JSON object")
    print(json.dumps(commands[sys.argv[1]](request)))


if __name__ == "__main__":
    main()
