#!/usr/bin/env python3
"""Synthetic dates for a plan's deferred items — after the plan's last value leaf. Dependency-free.

Implements the dating pass of `skills/rationalize-gantt/SKILL.md` for the items under the plan's
deferred container (`skills/build-item/references/deferred-container.md`). Reads one JSON object
on stdin, writes one JSON line on stdout:

  {"today": "YYYY-MM-DD",
   "valueLeaves": [{"number", "dueDate"}…],
   "deferred": [{"number", "done", "startDate", "dueDate"}…]}
  -> {"boundary", "assignments": [{"number", "startDate", "dueDate", "reason": "scheduled"|"kept"}…],
      "untouchedDone": […], "containerSpan": {"startDate", "dueDate"} | null}

`valueLeaves` carry the dates the cascade just computed for every non-deferred leaf (plus the
existing dates of Done leaves in not-done-only mode). The boundary is their latest `dueDate`, or
the day before `today` when there is none. An open item starting after the boundary keeps both
dates ("kept") and uses up no day; every other open item gets start = due = boundary + 1, + 2, …
in ascending item-number order ("scheduled"). Done items are never assigned. Weekends are not
special-cased. Re-running on its own output changes nothing. Exit 0 on a decision; 2 on bad
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
    leaves, deferred = request.get("valueLeaves", []), request.get("deferred")
    if not isinstance(leaves, list) or not isinstance(deferred, list):
        fail("valueLeaves and deferred must be arrays")
    dues = [day(leaf.get("dueDate"), "a value leaf's dueDate", optional=True) for leaf in leaves if isinstance(leaf, dict)]
    dues = [d for d in dues if d]
    boundary = max(dues) if dues else today - datetime.timedelta(days=1)

    assignments, done, cursor = [], [], boundary
    for item in sorted(deferred, key=lambda i: number_key(i.get("number", "")) if isinstance(i, dict) else (0, "")):
        if not isinstance(item, dict) or not isinstance(item.get("number"), str) or not item["number"]:
            fail("every deferred item needs a number")
        if item.get("done"):
            done.append(item["number"])
            continue
        start = day(item.get("startDate"), "a deferred startDate", optional=True)
        due = day(item.get("dueDate"), "a deferred dueDate", optional=True)
        if start and start > boundary:
            assignments.append({"number": item["number"], "startDate": start.isoformat(),
                                "dueDate": (due or start).isoformat(), "reason": "kept"})
            continue
        cursor += datetime.timedelta(days=1)
        assignments.append({"number": item["number"], "startDate": cursor.isoformat(),
                            "dueDate": cursor.isoformat(), "reason": "scheduled"})

    span = None
    if assignments:
        span = {"startDate": min(a["startDate"] for a in assignments),
                "dueDate": max(a["dueDate"] for a in assignments)}
    print(json.dumps({"boundary": boundary.isoformat(), "assignments": assignments,
                      "untouchedDone": done, "containerSpan": span}))


if __name__ == "__main__":
    main()
