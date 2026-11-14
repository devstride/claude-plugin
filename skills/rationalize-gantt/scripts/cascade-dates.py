#!/usr/bin/env python3
"""Synthetic dates for a plan's leaves: a gapless dependency cascade from a start date. Dependency-free.

Implements step 3 of `skills/rationalize-gantt/SKILL.md`. Reads one JSON object on stdin, writes
one JSON line on stdout:

  {"today": "YYYY-MM-DD", "start"?: "YYYY-MM-DD", "itemDays"?: <whole days, 1 or more>,
   "leaves": [{"number", "blockedBy"?: […], "groups"?: […],
               "fixed"?: true, "startDate"?, "dueDate"?}…]}
  -> {"start", "requestedStart", "startFrom", "heldBy", "itemDays", "itemDaysFrom", "end",
      "assignments": [{"number", "startDate", "dueDate", "depth"}…],
      "distribution": [{"startDate", "count"}…], "groupSpans": {"<number>": {"startDate", "dueDate"}},
      "outsideEdges": [{"number", "blockedBy"}…], "fixed": […]}

A leaf marked `fixed` (Done or landed, when only open items are re-dated) is never assigned and
keeps the dates it carries. Every other leaf is OPEN. What the plan already has is read from its
DATED open leaves: those with both dates in order, leaving out a one-day leaf dated `today`, which
is the placeholder a newly created story arrives as.

`start` is the first day of the earliest leaf this pass dates (`startFrom` "given"). Absent, it is
the earliest start the dated open leaves already have when that is later than the day after
`today` ("existing"), else the day after `today` ("default"): never today or earlier.
`itemDays` is how many calendar days one leaf is assumed to take ("given"). Absent, it is the
length most of the dated open leaves already have, the longer on a tie (`itemDaysFrom`
"existing"), or 1 when there is none ("default").

Depth uses only edges between two open leaves: a leaf no open leaf is blocked by has depth 0, and
any other has 1 + the deepest leaf blocked by it. The deepest leaves start on `start`; each depth
nearer 0 starts `itemDays` later, and a leaf is due `itemDays - 1` days after it starts, so every
blocker is due before the leaves it blocks start (the day before, along the longest chain) and no
slot is empty. A fixed leaf that blocks an open one must be over before that leaf starts: when one
is not, the whole cascade moves later by the fewest days that put every such leaf after its fixed
blockers. `start` is then the day used, `requestedStart` the day asked for and `heldBy` the fixed
leaf that moved it furthest (null when nothing moved). A fixed leaf with no due date counts by its
start date. An edge to anything that is not a leaf in the input (a container, an item outside the
plan) is listed in `outsideEdges` and dates nothing. `groups` names the containers above a leaf;
`groupSpans` gives each its span over every date known below it, fixed leaves' included. Weekends
are not special-cased. The dates do not depend on the order of the input.

Exit 0 with dates; 1 when the leaves hold a dependency cycle, fixed ones included, with one
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
    start = day(request.get("start"), "start", optional=True)
    item_days = request.get("itemDays")
    if item_days is not None and (isinstance(item_days, bool) or not isinstance(item_days, int) or item_days < 1):
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
        if not isinstance(leaf.get("fixed", False), bool):
            fail("fixed must be true or false")
        seen[leaf["number"]] = {
            "blockedBy": names(leaf.get("blockedBy", []), "blockedBy"),
            "groups": names(leaf.get("groups", []), "groups"),
            "fixed": leaf.get("fixed") is True,
            "startDate": day(leaf.get("startDate"), "a leaf's startDate", optional=True),
            "dueDate": day(leaf.get("dueDate"), "a leaf's dueDate", optional=True),
        }
    return today, start, item_days, seen


def cycles(left, blockers):
    """Strongly connected components of size > 1 (plus self-edges) among the leaves that never
    cleared, each with one path round it. `blockers` maps EVERY leaf to the leaves blocking it; an
    edge leaving `left` leads to a leaf that cleared, so it is on no cycle and is skipped. Iterative Tarjan: a deep plan must not hit the stack."""
    index, low, on_stack, stack, found, counter = {}, {}, set(), [], [], [0]
    for root in sorted(left, key=number_key):
        if root in index:
            continue
        work = [(root, iter([b for b in blockers[root] if b in left]))]
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
                    work.append((nxt, iter([b for b in blockers[nxt] if b in left])))
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
    today, requested, item_days, leaves = read()
    open_leaves = {n for n, leaf in leaves.items() if not leaf["fixed"]}

    # A cycle anywhere among the leaves stops the pass, finished leaves included.
    every = {n: [b for b in dict.fromkeys(leaf["blockedBy"]) if b in leaves] for n, leaf in leaves.items()}
    waiting = {n: len(every[n]) for n in leaves}
    unblocks = {n: [] for n in leaves}
    for number, its_blockers in every.items():
        for blocker in its_blockers:
            unblocks[blocker].append(number)
    ready, cleared = [n for n in leaves if not waiting[n]], set()
    while ready:
        node = ready.pop()
        cleared.add(node)
        for nxt in unblocks[node]:
            waiting[nxt] -= 1
            if not waiting[nxt]:
                ready.append(nxt)
    if len(cleared) < len(leaves):
        print(json.dumps({"cycles": cycles(set(leaves) - cleared, every)}))
        sys.exit(1)

    blockers = {n: [b for b in every[n] if b in open_leaves] for n in open_leaves}
    blocked = {n: [] for n in open_leaves}       # open leaf -> the open leaves blocked by it
    for number, its_blockers in blockers.items():
        for blocker in its_blockers:
            blocked[blocker].append(number)
    outside = [{"number": n, "blockedBy": b} for n in sorted(open_leaves, key=number_key)
               for b in dict.fromkeys(leaves[n]["blockedBy"]) if b not in leaves]

    # Depth from the END of the plan: clear a leaf once every leaf it blocks has a depth.
    waiting = {n: len(blocked[n]) for n in open_leaves}
    ready, depth = [n for n in open_leaves if not waiting[n]], {}
    while ready:
        node = ready.pop()
        depth[node] = 1 + max(depth[d] for d in blocked[node]) if blocked[node] else 0
        for blocker in blockers[node]:
            waiting[blocker] -= 1
            if not waiting[blocker]:
                ready.append(blocker)

    # What the plan already has: its open leaves with both dates in order, placeholders left out.
    dated = [(leaves[n]["startDate"], leaves[n]["dueDate"]) for n in open_leaves
             if leaves[n]["startDate"] and leaves[n]["dueDate"]]
    dated = [(first, due) for first, due in dated if first <= due and not first == due == today]
    start_from, item_days_from = "given", "given"
    if requested is None:
        requested, start_from = today + ONE_DAY, "default"
        if dated and min(first for first, _ in dated) > requested:
            requested, start_from = min(first for first, _ in dated), "existing"
    if item_days is None:
        item_days, item_days_from = 1, "default"
        spans = [(due - first).days + 1 for first, due in dated]
        if spans:
            item_days, item_days_from = max(set(spans), key=lambda s: (spans.count(s), s)), "existing"

    deepest = max(depth.values()) if depth else 0
    begins = {n: requested + datetime.timedelta(days=(deepest - depth[n]) * item_days) for n in open_leaves}
    # Move the whole cascade later by the fewest days that put every open leaf after the fixed
    # leaves blocking it.
    late, held_by = 0, None
    for number in sorted(open_leaves, key=number_key):
        for blocker in sorted(every[number], key=number_key):
            over = leaves[blocker]["dueDate"] or leaves[blocker]["startDate"] if leaves[blocker]["fixed"] else None
            if over and (over - begins[number]).days + 1 > late:
                late, held_by = (over - begins[number]).days + 1, blocker
    start = requested + datetime.timedelta(days=late)
    assignments = []
    for number in open_leaves:
        first = begins[number] + datetime.timedelta(days=late)
        assignments.append({"number": number, "startDate": first.isoformat(),
                            "dueDate": (first + datetime.timedelta(days=item_days - 1)).isoformat(),
                            "depth": depth[number]})
    assignments.sort(key=lambda a: (a["startDate"], number_key(a["number"])))

    counts, spans = {}, {}
    for a in assignments:
        counts[a["startDate"]] = counts.get(a["startDate"], 0) + 1
    known = {a["number"]: (a["startDate"], a["dueDate"]) for a in assignments}
    for number, leaf in leaves.items():
        if leaf["fixed"]:
            known[number] = tuple(d.isoformat() if d else None for d in (leaf["startDate"], leaf["dueDate"]))
    for number in sorted(known, key=number_key):
        for day_ in [d for d in known[number] if d]:
            for group in leaves[number]["groups"]:
                span = spans.setdefault(group, {"startDate": day_, "dueDate": day_})
                span["startDate"], span["dueDate"] = min(span["startDate"], day_), max(span["dueDate"], day_)
    print(json.dumps({
        "start": start.isoformat(), "requestedStart": requested.isoformat(), "startFrom": start_from,
        "heldBy": held_by,
        "itemDays": item_days, "itemDaysFrom": item_days_from,
        "end": max(a["dueDate"] for a in assignments) if assignments else None,
        "assignments": assignments,
        "distribution": [{"startDate": d, "count": counts[d]} for d in sorted(counts)],
        "groupSpans": {g: spans[g] for g in sorted(spans, key=number_key)}, "outsideEdges": outside,
        "fixed": sorted((n for n, leaf in leaves.items() if leaf["fixed"]), key=number_key)}))


if __name__ == "__main__":
    try:
        main()
    except OverflowError:
        fail("these dates run past the end of the calendar")
