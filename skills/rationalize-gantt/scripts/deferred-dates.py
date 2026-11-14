#!/usr/bin/env python3
"""Synthetic dates for a plan's deferred items — after the plan's last value leaf. Dependency-free.

Implements the dating pass of `skills/rationalize-gantt/SKILL.md` for the items under the plan's
deferred container (`skills/build-item/references/deferred-container.md`). Reads one JSON object
on stdin, writes one JSON line on stdout:

  {"today": "YYYY-MM-DD", "start"?: "YYYY-MM-DD", "itemDays"?: <whole days, 1 or more>,
   "valueLeaves": [{"number", "dueDate"}…],
   "deferred": [{"number", "done", "startDate", "dueDate", "groups"?: […]}…]}
  -> {"boundary", "assignments": [{"number", "startDate", "dueDate", "reason": "scheduled"|"kept"}…],
      "untouchedDone": […], "containerSpan": {"startDate", "dueDate"} | null,
      "groupSpans": {"<number>": {"startDate", "dueDate"}}}

`valueLeaves` carry the dates the cascade just computed for every non-deferred leaf (plus the
existing dates of Done leaves in not-done-only mode). The boundary is their latest `dueDate`, but
never earlier than the day before `start` (the plan's start date; absent, the day after `today`),
so a deferred item is never dated before the plan starts, nor today or earlier by default. Items
are taken in ascending item-number order. An open item that starts after the boundary and after
every item scheduled before it, and whose due date is present and not before its start, keeps both
dates ("kept"); every other open item gets the next free day after the boundary, stepping past
the days a kept item before it holds
("scheduled"): with no kept item in the way and `itemDays` 1 (the default) start = due = boundary + 1, + 2, …; with more, each
item spans `itemDays` calendar days and the next starts the day after it is due. Done items are never assigned. `groups` names the container and intermediate nodes
above an item; `groupSpans` gives each its span over the assignments of its own items. Weekends
are not special-cased. Re-running on its own output changes nothing. Exit 0 on a decision; 2 on bad
input with one `{"error": …}` line.
"""
import datetime
import json
import re
import sys


def fail(message):
    print(json.dumps({"error": message}))
    sys.exit(2)


def day(value, what, optional=False):
    if value is None and optional:
        return None
    try:
        return datetime.date.fromisoformat(value[:10]) if isinstance(value, str) else fail("%s must be YYYY-MM-DD" % what)
    except ValueError:
        fail("%s must be YYYY-MM-DD" % what)


def number_key(number):
    number = str(number)
    digits = re.sub(r"\D", "", number)
    return (int(digits) if digits else 0, number)


def main():
    try:
        request = json.load(sys.stdin)
    except ValueError as error:
        fail("stdin is not JSON: %s" % error)
    if not isinstance(request, dict):
        fail("stdin must be one JSON object")
    today = day(request.get("today"), "today")
    start = day(request.get("start"), "start", optional=True) or today + datetime.timedelta(days=1)
    item_days = request.get("itemDays", 1)
    if isinstance(item_days, bool) or not isinstance(item_days, int) or item_days < 1:
        fail("itemDays must be a whole number of days, 1 or more")
    leaves, deferred = request.get("valueLeaves", []), request.get("deferred")
    if not isinstance(leaves, list) or not isinstance(deferred, list):
        fail("valueLeaves and deferred must be arrays")
    dues = [day(leaf.get("dueDate"), "a value leaf's dueDate", optional=True) for leaf in leaves if isinstance(leaf, dict)]
    dues = [d for d in dues if d]
    boundary = max(dues + [start - datetime.timedelta(days=1)])

    for item in deferred:
        if not isinstance(item, dict) or not isinstance(item.get("number"), str) or not item["number"]:
            fail("every deferred item needs a number")
        groups = item.get("groups", [])
        if not isinstance(groups, list) or not all(isinstance(g, str) and g for g in groups):
            fail("groups must be an array of item numbers")
    assignments, done, cursor, held = [], [], boundary, []
    for item in sorted(deferred, key=lambda i: number_key(i["number"])):
        if item.get("done"):
            done.append(item["number"])
            continue
        start = day(item.get("startDate"), "a deferred startDate", optional=True)
        due = day(item.get("dueDate"), "a deferred dueDate", optional=True)
        if start and due and start > cursor and due >= start:
            assignments.append({"number": item["number"], "startDate": start.isoformat(),
                                "dueDate": due.isoformat(), "reason": "kept"})
            held.append((start, due))
            continue
        begins = cursor + datetime.timedelta(days=1)
        for first, last in sorted(held):
            if begins <= last and begins + datetime.timedelta(days=item_days - 1) >= first:
                begins = last + datetime.timedelta(days=1)
        cursor = begins + datetime.timedelta(days=item_days - 1)
        assignments.append({"number": item["number"], "startDate": begins.isoformat(),
                            "dueDate": cursor.isoformat(), "reason": "scheduled"})

    span = None
    if assignments:
        span = {"startDate": min(a["startDate"] for a in assignments),
                "dueDate": max(a["dueDate"] for a in assignments)}
    groups_of = {i["number"]: i.get("groups", []) for i in deferred}
    group_spans = {}
    for a in assignments:
        for g in groups_of.get(a["number"], []):
            cur = group_spans.setdefault(g, {"startDate": a["startDate"], "dueDate": a["dueDate"]})
            cur["startDate"] = min(cur["startDate"], a["startDate"])
            cur["dueDate"] = max(cur["dueDate"], a["dueDate"])
    print(json.dumps({"boundary": boundary.isoformat(), "assignments": assignments,
                      "untouchedDone": done, "containerSpan": span, "groupSpans": group_spans}))


if __name__ == "__main__":
    try:
        main()
    except OverflowError:
        fail("these dates run past the end of the calendar")
