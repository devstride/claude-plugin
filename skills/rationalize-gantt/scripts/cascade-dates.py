#!/usr/bin/env python3
"""Synthetic dates for a plan's leaves: a gapless dependency cascade from a start date. Dependency-free.

Implements step 3 of `skills/rationalize-gantt/SKILL.md`. Reads one JSON object on stdin, writes
one JSON line on stdout:

  {"today": "YYYY-MM-DD", "start"?: "YYYY-MM-DD", "itemDays"?: <whole days, 1 or more>,
   "leaves": [{"number", "blockedBy"?: […], "groups"?: […],
               "fixed"?: true, "startDate"?, "dueDate"?}…]}
  -> {"start", "requestedStart", "heldBy", "itemDays", "end",
      "assignments": [{"number", "startDate", "dueDate", "depth"}…],
      "distribution": [{"startDate", "count"}…], "groupSpans": {"<number>": {"startDate", "dueDate"}},
      "outsideEdges": [{"number", "blockedBy"}…], "fixed": […]}

`start` is the first day of the earliest leaf this pass dates; absent, it is the day after `today`.
`itemDays` is how many calendar days one leaf is assumed to take (default 1). A leaf marked `fixed`
(Done or landed, when only open items are re-dated) is never assigned and keeps the dates it
carries. Every other leaf is OPEN.

Depth uses only edges between two open leaves: a leaf no open leaf is blocked by has depth 0, and
any other has 1 + the deepest leaf blocked by it. The deepest leaves start on `start`; each depth
nearer 0 starts `itemDays` later, and a leaf is due `itemDays - 1` days after it starts, so every
blocker is due the day before the leaves it blocks start and no slot is empty. When a fixed leaf
that blocks an open one is due on or after the requested start, the whole cascade starts the day
after it instead: `start` is the day used, `requestedStart` the day asked for and `heldBy` that
fixed leaf (null when the requested day was used). An edge to anything that is not a leaf in the
input (a container, an item outside the plan) is listed in `outsideEdges` and dates nothing.
`groups` names the containers above a leaf; `groupSpans` gives each its span over every dated leaf
below it, fixed ones included. Weekends are not special-cased.

Exit 0 with dates; 1 when the open leaves hold a dependency cycle, with one
`{"cycles": [{"members": […], "path": […]}…]}` line and NO dates (`path` walks blocker to blocked
and ends where it began); 2 on bad input with one `{"error": …}` line.
"""
import datetime
import json
import re
import sys

ONE_DAY = datetime.timedelta(days=1)


def fail(message):
    print(json.dumps({"error": message}))
    sys.exit(2)


def day(value, what, optional=False):
    if value is None and optional:
        return None
    if not isinstance(value, str):
        fail("%s must be YYYY-MM-DD" % what)
    try:
        return datetime.date.fromisoformat(value[:10])
    except ValueError:
        fail("%s must be YYYY-MM-DD" % what)


def number_key(number):
    digits = re.sub(r"\D", "", number)
    return (int(digits) if digits else 0, number)


def names(value, what):
    if not isinstance(value, list) or not all(isinstance(n, str) and n for n in value):
        fail("%s must be an array of item numbers" % what)
    return value


def read():
    try:
        request = json.load(sys.stdin)
    except ValueError as error:
        fail("stdin is not JSON: %s" % error)
    if not isinstance(request, dict):
        fail("stdin must be one JSON object")
    today = day(request.get("today"), "today")
    start = day(request.get("start"), "start", optional=True) or today + ONE_DAY
    item_days = request.get("itemDays", 1)
    if isinstance(item_days, bool) or not isinstance(item_days, int) or item_days < 1:
        fail("itemDays must be a whole number of days, 1 or more")
    leaves = request.get("leaves")
    if not isinstance(leaves, list):
        fail("leaves must be an array")
    seen = {}
    for leaf in leaves:
        if not isinstance(leaf, dict) or not isinstance(leaf.get("number"), str) or not leaf["number"]:
            fail("every leaf needs a number")
        if leaf["number"] in seen:
            fail("leaf %s is listed twice" % leaf["number"])
        seen[leaf["number"]] = {
            "blockedBy": names(leaf.get("blockedBy", []), "blockedBy"),
            "groups": names(leaf.get("groups", []), "groups"),
            "fixed": leaf.get("fixed") is True,
            "startDate": day(leaf.get("startDate"), "a leaf's startDate", optional=True),
            "dueDate": day(leaf.get("dueDate"), "a leaf's dueDate", optional=True),
        }
    return start, item_days, seen


def cycles(left, blockers):
    """Strongly connected components of size > 1 (plus self-edges) among the leaves that never
    cleared, each with one path round it. Iterative Tarjan: a deep plan must not hit the stack."""
    index, low, on_stack, stack, found, counter = {}, {}, set(), [], [], [0]
    for root in sorted(left, key=number_key):
        if root in index:
            continue
        work = [(root, iter(blockers[root]))]
        index[root] = low[root] = counter[0]
        counter[0] += 1
        stack.append(root)
        on_stack.add(root)
        while work:
            node, edges = work[-1]
            for nxt in edges:
                if nxt not in index:
                    index[nxt] = low[nxt] = counter[0]
                    counter[0] += 1
                    stack.append(nxt)
                    on_stack.add(nxt)
                    work.append((nxt, iter(blockers[nxt])))
                    break
                if nxt in on_stack:
                    low[node] = min(low[node], index[nxt])
            else:
                work.pop()
                if work:
                    low[work[-1][0]] = min(low[work[-1][0]], low[node])
                if low[node] == index[node]:
                    members = []
                    while True:
                        member = stack.pop()
                        on_stack.discard(member)
                        members.append(member)
                        if member == node:
                            break
                    if len(members) > 1 or node in blockers[node]:
                        found.append(sorted(members, key=number_key))
    out = []
    for members in sorted(found, key=lambda m: number_key(m[0])):
        inside, first = set(members), members[0]
        # The shortest way from `first` back to itself along blocked-by edges. Walking it backwards
        # gives the path in blocker -> blocked order, ending on `first` again.
        came, queue, path = {first: None}, [first], [first, first]
        while queue:
            node = queue.pop(0)
            nexts = [n for n in blockers[node] if n in inside]
            if first in nexts:
                path = [first, node]
                while came[path[-1]] is not None:
                    path.append(came[path[-1]])
                break
            for nxt in sorted(nexts, key=number_key):
                if nxt not in came:
                    came[nxt] = node
                    queue.append(nxt)
        out.append({"members": members, "path": path})
    return out


def main():
    requested, item_days, leaves = read()
    open_leaves = {n for n, leaf in leaves.items() if not leaf["fixed"]}
    blockers = {n: [] for n in open_leaves}      # open leaf -> the open leaves it is blocked by
    blocked = {n: [] for n in open_leaves}       # open leaf -> the open leaves blocked by it
    outside, floor, held_by = [], None, None
    for number in sorted(open_leaves, key=number_key):
        for blocker in dict.fromkeys(leaves[number]["blockedBy"]):
            if blocker in open_leaves:
                blockers[number].append(blocker)
                blocked[blocker].append(number)
            elif blocker in leaves:
                due = leaves[blocker]["dueDate"]
                if due and (floor is None or due > floor):
                    floor, held_by = due, blocker
            else:
                outside.append({"number": number, "blockedBy": blocker})

    # Depth from the END of the plan: clear a leaf once every leaf it blocks has a depth.
    waiting = {n: len(blocked[n]) for n in open_leaves}
    ready = sorted((n for n in open_leaves if not waiting[n]), key=number_key)
    depth = {}
    while ready:
        node = ready.pop()
        depth[node] = 1 + max(depth[d] for d in blocked[node]) if blocked[node] else 0
        for blocker in blockers[node]:
            waiting[blocker] -= 1
            if not waiting[blocker]:
                ready.append(blocker)
    left = open_leaves - set(depth)
    if left:
        print(json.dumps({"cycles": cycles(left, blockers)}))
        sys.exit(1)

    start = requested
    if floor is not None and floor >= requested:
        start = floor + ONE_DAY
    else:
        held_by = None
    deepest = max(depth.values()) if depth else 0
    assignments = []
    for number in open_leaves:
        begins = start + datetime.timedelta(days=(deepest - depth[number]) * item_days)
        assignments.append({"number": number, "startDate": begins.isoformat(),
                            "dueDate": (begins + datetime.timedelta(days=item_days - 1)).isoformat(),
                            "depth": depth[number]})
    assignments.sort(key=lambda a: (a["startDate"], number_key(a["number"])))

    counts, spans = {}, {}
    for a in assignments:
        counts[a["startDate"]] = counts.get(a["startDate"], 0) + 1
    dated = [(a["number"], a["startDate"], a["dueDate"]) for a in assignments]
    dated += [(n, leaf["startDate"].isoformat(), leaf["dueDate"].isoformat()) for n, leaf in leaves.items()
              if leaf["fixed"] and leaf["startDate"] and leaf["dueDate"]]
    for number, begins, due in dated:
        for group in leaves[number]["groups"]:
            span = spans.setdefault(group, {"startDate": begins, "dueDate": due})
            span["startDate"], span["dueDate"] = min(span["startDate"], begins), max(span["dueDate"], due)
    print(json.dumps({
        "start": start.isoformat(), "requestedStart": requested.isoformat(), "heldBy": held_by,
        "itemDays": item_days, "end": max(a["dueDate"] for a in assignments) if assignments else None,
        "assignments": assignments,
        "distribution": [{"startDate": d, "count": counts[d]} for d in sorted(counts)],
        "groupSpans": spans, "outsideEdges": outside,
        "fixed": sorted((n for n, leaf in leaves.items() if leaf["fixed"]), key=number_key)}))


if __name__ == "__main__":
    main()
