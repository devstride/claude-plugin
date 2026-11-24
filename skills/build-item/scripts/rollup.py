#!/usr/bin/env python3
"""Does an item roll up, and are all of a rollup's children complete?

A rollup is a parent item whose own workflow starts once all of its children are complete and
ends by shipping (`ship`) or by handing up to the rollup above it (`hand-up`). Which items are
rollups is the server's answer (DevStride's `get_item_rollup_chain`); this file never invents a
default. Whether a rollup is ready is decided here, from facts the caller gathers: the
descendants DevStride returns (`get_item_rollup`), the landed set the caller reads from git, the
deferred container's members (`deferred-container.py members`) and the holds
(`release-holds.py decide`). Deterministic: no git, no network, no DevStride call, no clock.

  chain  stdin {"item": "<the number asked for>",
                "chain": {"chain": [{"number", "title", "workType",
                                     "rollup": {"state", "source"?, "endsBy"?, "candidates"?,
                                                "workflow"?: {"endsBy"?}}}...],
                          "leafParents": [...]}}
         stdout {"chain": [{"number", "title", "workType", "rollup": "hand-up"|"ship"|null}...],
                 "leafParents": [...]}

  ready  stdin {"config": {"epicIntegrationBranches": {"autoRelease": true|false|"ask"},
                           "hierarchyRoles": {"leaf": [...]}, "defects"?: {...}},
                "item": {"number", "title", "workType", "rollup": "hand-up"|"ship"},
                "descendants": [{"number", "parentNumber", "title", "workTypeName", "done",
                                 "isRollup"}...],
                "truncated": false, "countsReadableChildrenOnly": false,
                "landed": [numbers], "excluded": [numbers],
                "holds": {"held": bool, "reason"}}
         stdout {"verdict", "reason", "complete": [numbers],
                 "remaining": [{"number", "title", "why"}...]}

A work type is read as DevStride answers it and as a plain name alike: a chain entry's `workType`
and each of `leafParents` is `{"id", "name"}` (or the name, or null for a workstream), and a
descendant carries `workTypeName` (or `workType`, in either form). What is printed is the name.

chain: the entries run from the asked-for item up to the root. `state: "rollup"` maps to its
`endsBy`; `"not-rollup"` (resolved: this node does not roll up) maps to null. An `undetermined`
entry is refused with the sentence that names what to do, never guessed past.

ready counts the item's DIRECT children; whether each counts is decided over its descendants:
- a rollup child (`isRollup`) counts when it is done or in `landed` (its number enters `landed`
  when its own release merge is in this item's branch history), never merely because its own
  children are complete: it still has its own workflow to run;
- a child with counted children under it, not a rollup, is a grouping: it counts when every
  counted child under it counts (the same rules, recursively), and when its own work type is a
  leaf type it must itself be done or landed too;
- a child with nothing counted under it is a leaf when its work type is in `hierarchyRoles.leaf`
  (it counts when done or in `landed`); otherwise it is an empty grouping, never counted;
- `excluded` (the deferred container and its members) and everything under it is never counted.
  DevStride's own `excluded` flags on descendants are ignored, so this decision never depends on
  the platform's guess at the container's title; `config.defects` (the container's titles) is
  applied by the caller through `deferred-container.py members`, never read here.

`autoRelease` is the caller's resolved value: a profile default is resolved before the call.
Verdicts, in order: WAITING (`countsReadableChildrenOnly` is true: DevStride hid some of the items
under it from the caller, so they cannot all be counted, whatever the visible ones say; or a
counted child is not complete: `remaining` names each), HELD (all
complete, `holds.held`; its reason is quoted), MANUAL (all complete, autoRelease false: report
release-ready and stop), ASK (all complete, autoRelease "ask": ask the owner once for this unit),
READY (all complete, autoRelease true). An item with nothing counted under it is WAITING.

Exit 0 with an answer, 2 with one `rollup: <reason>` line on stderr for a refusal (a request that
is not what is described here, an undetermined chain, a truncated descendants list, a request that
does not say whether children were hidden, missing holds, an item that is not a rollup), 1 for
anything else. A caller never starts a rollup on a non-zero
exit.
"""
import json
import sys

ENDS = ("hand-up", "ship")
STATES = ("rollup", "not-rollup", "undetermined")


class Refuse(Exception):
    pass


def need(cond, reason):
    if not cond:
        raise Refuse(reason)


def text(value):
    return isinstance(value, str) and value.strip() != ""


def numbers(value, field):
    need(isinstance(value, list) and all(text(n) for n in value), "%s must be a list of item numbers" % field)
    return {n.strip() for n in value}


NO_TYPE = object()


def type_name(value):
    """A work type's name from either form it is answered in: the name itself, or {"id", "name"}.
    None for null (a workstream). NO_TYPE for anything else: never guessed."""
    if value is None:
        return None
    if isinstance(value, dict):
        value = value.get("name")
    return value.strip() if text(value) else NO_TYPE


def label(number, title):
    return "%s (%s)" % (number, title) if text(title) else number


def joined(names):
    names = [n for n in names if text(n)]
    if len(names) < 2:
        return "".join(names)
    return ", ".join(names[:-1]) + " and " + names[-1]


# ---- chain ---------------------------------------------------------------------------------

def undetermined(asked, entry, candidates):
    where = asked if entry["number"].strip() == asked else "%s, above %s" % (label(entry["number"], entry.get("title")), asked)
    both = "both" if len(candidates) == 2 else "each"
    who = joined(candidates) if candidates else "More than one work type"
    return ("cannot route %s: %s can %s hold stories directly and no rollup workflow says "
            "which one releases: ask a person with the workflow edit permission to publish the organization's "
            "rollup workflow for the right type in the Agents module" % (where, who, both))


def ends_by(entry):
    rollup = entry["rollup"]
    own = rollup.get("endsBy")
    workflow = rollup.get("workflow")
    inner = workflow.get("endsBy") if isinstance(workflow, dict) else None
    need(own is None or inner is None or own == inner,
         "%s: its rollup says endsBy %s but its workflow says %s" % (entry["number"], json.dumps(own), json.dumps(inner)))
    value = own if own is not None else inner
    need(value in ENDS, "%s rolls up but ends by %s, not one of %s" % (entry["number"], json.dumps(value), ", ".join(ENDS)))
    return value


def chain(request):
    asked = request.get("item")
    need(text(asked), "chain: item must be the number of the item asked about")
    asked = asked.strip()
    answer = request.get("chain")
    need(isinstance(answer, dict) and isinstance(answer.get("chain"), list) and answer["chain"],
         "chain: the answer for %s is not an object with a non-empty chain" % asked)
    leaf_parents = answer.get("leafParents")
    need(isinstance(leaf_parents, list), "chain: the answer for %s has no leafParents list" % asked)
    leaf_parents = [type_name(t) for t in leaf_parents]
    need(all(t is not None and t is not NO_TYPE for t in leaf_parents),
         "chain: the answer for %s has no leafParents list" % asked)
    entries = answer["chain"]
    for entry in entries:
        need(isinstance(entry, dict) and text(entry.get("number")) and isinstance(entry.get("rollup"), dict)
             and entry["rollup"].get("state") in STATES,
             "chain: every entry needs a number and a rollup state (one of %s)" % ", ".join(STATES))
        need(type_name(entry.get("workType")) is not NO_TYPE,
             "chain: %s has a workType that is neither a name nor null" % entry["number"])
    first = entries[0]["number"].strip()
    need(first == asked, "chain: the chain starts at %s, not at the item asked about, %s" % (first, asked))
    seen = set()
    for entry in entries:
        need(entry["number"].strip() not in seen, "chain: %s appears twice" % entry["number"])
        seen.add(entry["number"].strip())
    out = []
    for entry in entries:
        state = entry["rollup"]["state"]
        if state == "undetermined":
            candidates = entry["rollup"].get("candidates")
            names = candidates if isinstance(candidates, list) and all(text(c) for c in candidates) else leaf_parents
            raise Refuse(undetermined(asked, entry, names))
        out.append({"number": entry["number"].strip(), "title": entry.get("title"), "workType": type_name(entry.get("workType")),
                    "rollup": ends_by(entry) if state == "rollup" else None})
    return {"chain": out, "leafParents": leaf_parents}


# ---- ready ---------------------------------------------------------------------------------

def tree(root, descendants):
    need(isinstance(descendants, list), "ready: descendants must be the flat list from get_item_rollup")
    nodes = {}
    for d in descendants:
        need(isinstance(d, dict) and text(d.get("number")), "ready: every descendant needs a number")
        number = d["number"].strip()
        need(number != root and number not in nodes, "ready: %s appears twice in the descendants" % number)
        need(text(d.get("parentNumber")), "ready: %s has no parentNumber" % number)
        need(isinstance(d.get("done"), bool) and isinstance(d.get("isRollup"), bool),
             "ready: %s needs done and isRollup as true or false" % number)
        kind = type_name(d["workType"] if d.get("workType") is not None else d.get("workTypeName"))
        need(kind is not NO_TYPE, "ready: %s has a workType that is neither a name nor null" % number)
        nodes[number] = dict(d, number=number, parentNumber=d["parentNumber"].strip(), workType=kind)
    children = {}
    for number, node in nodes.items():
        parent = node["parentNumber"]
        need(parent == root or parent in nodes,
             "ready: %s's parent %s is not in the descendants of %s (unreadable, or a cut list)" % (number, parent, root))
        children.setdefault(parent, []).append(number)
    for number in nodes:  # every chain must reach the root: a loop never does
        walk, seen = number, set()
        while walk != root:
            need(walk not in seen, "ready: the descendants of %s loop through %s" % (root, walk))
            seen.add(walk)
            walk = nodes[walk]["parentNumber"]
    return nodes, children


def judge(number, nodes, children, facts, memo):
    """None: not counted. Otherwise (complete, outstanding leaf-level numbers, counted under, complete under)."""
    if number in memo:
        return memo[number]
    node = nodes[number]
    if number in facts["excluded"]:
        memo[number] = None
        return None
    own = node["done"] or number in facts["landed"]
    if node["isRollup"]:
        memo[number] = (own, [] if own else [number], 0, 0)
        return memo[number]
    under = sorted(children.get(number, []), key=sort_key)
    counted = [(c, r) for c, r in ((c, judge(c, nodes, children, facts, memo)) for c in under) if r is not None]
    is_leaf_type = node.get("workType") in facts["leaf"]
    if not counted:
        if not is_leaf_type:
            memo[number] = None  # an empty grouping: it cannot block and is not progress
            return None
        memo[number] = (own, [] if own else [number], 0, 0)
        return memo[number]
    outstanding = [n for _, r in counted for n in r[1]]
    if is_leaf_type and not own:
        outstanding = [number] + outstanding
    done_under = sum(1 for _, r in counted if r[0])
    memo[number] = (not outstanding, outstanding, len(counted), done_under)
    return memo[number]


def sort_key(number):
    digits = "".join(ch for ch in number if ch.isdigit())
    return (int(digits) if digits else 0, number)


def why(node, result):
    if node["isRollup"]:
        return "a rollup: neither handed up nor done"
    _, outstanding, counted, done_under = result
    if counted:
        waiting = [n for n in outstanding if n != node["number"]]
        parts = []
        if node["number"] in outstanding:
            parts.append("not done or landed itself")
        if waiting:
            parts.append("%d of %d under it complete; waiting on %s" % (done_under, counted, ", ".join(waiting)))
        return "; ".join(parts)
    return "not done or landed"


def ready(request):
    config = request.get("config")
    need(isinstance(config, dict), "ready: config is required")
    epic = config.get("epicIntegrationBranches")
    auto = epic.get("autoRelease") if isinstance(epic, dict) else None
    need(auto is True or auto is False or auto == "ask",
         "ready: config.epicIntegrationBranches.autoRelease must be true, false or \"ask\" "
         "(the caller resolves a profile default before the call)")
    roles = config.get("hierarchyRoles")
    leaf = roles.get("leaf") if isinstance(roles, dict) else None
    need(isinstance(leaf, list) and leaf and all(text(t) for t in leaf), "ready: config.hierarchyRoles.leaf must list the leaf work types")
    item = request.get("item")
    need(isinstance(item, dict) and text(item.get("number")), "ready: item needs a number")
    root = item["number"].strip()
    need(item.get("rollup") in ENDS, "ready: %s is not a rollup (its rollup is %s, not one of %s): there is nothing to start"
         % (label(root, item.get("title")), json.dumps(item.get("rollup")), ", ".join(ENDS)))
    need(isinstance(request.get("truncated"), bool),
         "ready: truncated must say whether DevStride cut the descendants list")
    need(request["truncated"] is False,
         "ready: DevStride cut the descendants of %s short (truncated): a rollup is never started from part of its tree" % root)
    hidden = request.get("countsReadableChildrenOnly")
    need(isinstance(hidden, bool),
         "ready: countsReadableChildrenOnly must say whether DevStride hid some items under %s from the caller "
         "(pass get_item_rollup's own value)" % root)
    holds = request.get("holds")
    need(isinstance(holds, dict) and isinstance(holds.get("held"), bool),
         "ready: holds is required: the release-holds.py decide answer over %s, its ancestors and every carried leaf" % root)
    need(not holds["held"] or text(holds.get("reason")), "ready: a hold needs its reason")
    facts = {"landed": numbers(request.get("landed"), "ready: landed"),
             "excluded": numbers(request.get("excluded"), "ready: excluded"),
             "leaf": {t.strip() for t in leaf}}
    nodes, children = tree(root, request.get("descendants"))

    memo, complete, remaining = {}, [], []
    for number in sorted(children.get(root, []), key=sort_key):
        result = judge(number, nodes, children, facts, memo)
        if result is None:
            continue
        if result[0]:
            complete.append(number)
        else:
            remaining.append({"number": number, "title": nodes[number].get("title"), "why": why(nodes[number], result)})
    total = len(complete) + len(remaining)
    name = label(root, item.get("title"))

    def answer(verdict, reason):
        return {"verdict": verdict, "reason": reason, "complete": complete, "remaining": remaining}

    if hidden:
        # Whatever the visible children say: work the caller cannot see may still be open.
        seen = "; of those it can see, waiting on %s" % ", ".join(r["number"] for r in remaining) if remaining else ""
        return answer("WAITING", "some items under %s are hidden from this account, so its children cannot all be counted%s: "
                      "a rollup is never started over work it cannot see; a person who can see them all decides" % (name, seen))
    if total == 0:
        return answer("WAITING", "nothing under %s counts (no children, or only deferred or empty ones): nothing to release" % name)
    if remaining:
        return answer("WAITING", "%d of %d children of %s complete; waiting on %s"
                      % (len(complete), total, name, ", ".join(r["number"] for r in remaining)))
    done = "all %d children of %s complete" % (total, name)
    if holds["held"]:
        return answer("HELD", "%s, but it is held: \"%s\"" % (done, holds["reason"].strip()))
    if auto is False:
        return answer("MANUAL", "%s; automatic release is off: report it release-ready and stop" % done)
    if auto == "ask":
        return answer("ASK", "%s; ask the owner once whether to release it" % done)
    return answer("READY", "%s: ready to %s" % (done, "ship" if item["rollup"] == "ship" else "hand up"))


def main(argv):
    commands = {"chain": chain, "ready": ready}
    if len(argv) != 2 or argv[1] not in commands:
        sys.stderr.write("rollup: usage: rollup.py chain|ready < request.json\n")
        return 2
    try:
        request = json.loads(sys.stdin.read())
    except ValueError as err:
        sys.stderr.write("rollup: the request is not JSON: %s\n" % err)
        return 2
    try:
        need(isinstance(request, dict), "the request must be a JSON object")
        result = commands[argv[1]](request)
    except Refuse as err:
        sys.stderr.write("rollup: %s\n" % str(err).replace("\n", " "))
        return 2
    sys.stdout.write(json.dumps(result, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as err:  # never a traceback on the caller's screen
        sys.stderr.write("rollup: internal error: %s\n" % err)
        sys.exit(1)
