#!/usr/bin/env python3
"""Which status a leaf item moves to, and what it is told, as a build starts and lands.

The single implementation of the status moves in `skills/build-item/SKILL.md` (steps 1 and 6),
`references/next-unblocked.md` ("At the merge") and `references/release-train.md` (the train's
completion ritual). Claude follows those documents; any other agent or tool (a repository's own
CLI, Codex, a script) runs this file and gets the same answer. Deterministic: no
network, no clock, no DevStride call. The caller reads the item and the workspace, runs this, then
does the `update_item` / `add_comment` itself and reads the item back.

  decide  stdin {"event": "start"|"landed",
                 "item": {"number", "statusId", "statusCollectionId"?},
                 "workspace": {"statuses": [{"id", "name", "type"}…],
                               "statusCollections": [{"id", "statusIds": […]}…]},
                 "target"?: {"kind": "epic"|"plan"|"train"|"base", "branch",
                             "sha"?, "pullRequest"?, "releaseUnit"?, "releaseTarget"?},
                 "mergedStatusName"?: str|null, "startStatusName"?: str}
          stdout {"statusId"?, "statusName"?, "comment"?, "message"}

No `statusId` in the answer means: leave the status as it is. A `comment` is posted whatever the
status does — on an epic, plan or train landing it is the landed record recovery reads.

Rules:
- An item in a done-type status never moves and gets no comment.
- start  -> `startStatusName` (absent: "In Progress").
- landed on an epic or plan integration branch, or on the release train -> the merged status,
  `mergedStatusName` (absent: "Review"; null: none), plus the landed comment. `target` is required.
- landed on the base branch (`kind: base`, its own pull request) -> the done-type status ("Done"
  by name, else the collection's only done-type status). No comment: the pull request links itself.
- A status resolves BY NAME, exactly, and only inside the item's status collection: the one
  `statusCollectionId` names when given (pass it whenever the work type's collection is known);
  else any collection that holds the item's current status (the DevStride tools do not say which
  collection a work type uses, and a status name is unique in an organization). Missing, ambiguous
  or already current -> no move, with the reason in `message`.

Exit 0 with a decision (a move or none), 2 with one `item-status: <reason>` line on stderr for a
bad request, 1 for anything else. A caller never moves the item on a non-zero exit.
"""
import json
import sys

KINDS = ("epic", "plan", "train", "base")


class Refuse(Exception):
    pass


def need(cond, reason):
    if not cond:
        raise Refuse(reason)


def text(value):
    return isinstance(value, str) and value.strip() != ""


def parse(request):
    need(isinstance(request, dict), "the request must be a JSON object")
    event = request.get("event")
    need(event in ("start", "landed"), 'event must be "start" or "landed"')
    item = request.get("item")
    need(isinstance(item, dict) and text(item.get("number")) and text(item.get("statusId")),
         "item needs a number and a statusId")
    workspace = request.get("workspace")
    need(isinstance(workspace, dict), "workspace is required")
    statuses, collections = workspace.get("statuses"), workspace.get("statusCollections")
    need(isinstance(statuses, list) and all(isinstance(s, dict) and text(s.get("id")) and text(s.get("name"))
                                            and text(s.get("type")) for s in statuses),
         "workspace.statuses needs an id, a name and a type on each")
    need(isinstance(collections, list) and all(isinstance(c, dict) and text(c.get("id")) and isinstance(c.get("statusIds"), list)
                                               for c in collections), "workspace.statusCollections needs an id and statusIds on each")
    target = request.get("target")
    if event == "landed":
        need(isinstance(target, dict) and target.get("kind") in KINDS,
             "a landing needs target.kind: one of " + ", ".join(KINDS))
        need(text(target.get("branch")), "target.branch is required")
    if "mergedStatusName" in request:
        need(request["mergedStatusName"] is None or text(request["mergedStatusName"]), "mergedStatusName must be a name or null")
    if "startStatusName" in request:
        need(text(request["startStatusName"]), "startStatusName must be a name")
    return event, item, statuses, collections, target


def landed_comment(target):
    kind, branch = target["kind"], target["branch"]
    sha, pr = target.get("sha"), target.get("pullRequest")
    if kind == "train":
        need(text(pr) or text(sha), "a train landing needs target.pullRequest or target.sha")
        return "merged to the release train %s (%s); ships with the next release" % (branch, pr if text(pr) else sha)
    need(text(sha), "an %s landing needs target.sha" % kind)
    need(text(target.get("releaseUnit")) and text(target.get("releaseTarget")),
         "an %s landing needs target.releaseUnit and target.releaseTarget" % kind)
    return "merged onto %s at %s%s; Done when the %s release pull request reaches %s" % (
        branch, sha, " (%s)" % pr if text(pr) else "", target["releaseUnit"], target["releaseTarget"])


def decide(request):
    event, item, statuses, collections, target = parse(request)
    by_id = {s["id"]: s for s in statuses}
    current = by_id.get(item["statusId"])
    current_name = current["name"] if current else "an unknown status"
    if current and current.get("type") == "done":
        return {"message": "%s is already %s, a done status: left as it is" % (item["number"], current_name)}

    comment = None
    if event == "landed" and target["kind"] != "base":
        comment = landed_comment(target)

    wanted_done = False
    if event == "start":
        wanted = request.get("startStatusName", "In Progress")
    elif target["kind"] == "base":
        wanted, wanted_done = "Done", True
    else:
        wanted = request.get("mergedStatusName", "Review")

    def answer(message, status=None):
        out = {"message": message}
        if status:
            out["statusId"], out["statusName"] = status["id"], status["name"]
        if comment:
            out["comment"] = comment
        return out

    if wanted is None:
        return answer("no merged status is configured: %s keeps %s" % (item["number"], current_name))

    given = item.get("statusCollectionId")
    if given is not None:
        need(text(given), "item.statusCollectionId must be an id")
        scope = [c for c in collections if c["id"] == given]
        need(scope, "item.statusCollectionId %s is not in workspace.statusCollections" % given)
    else:
        scope = [c for c in collections if item["statusId"] in c["statusIds"]]
        if not scope:
            return answer("%s's status collection is unknown (no collection holds its current status): left as it is"
                          % item["number"])
    allowed = set()
    for c in scope:
        allowed |= set(c["statusIds"])
    inside = [by_id[i] for i in sorted(allowed) if i in by_id]

    found = [s for s in inside if s["name"] == wanted]
    if not found and wanted_done:
        found = [s for s in inside if s.get("type") == "done"]
    if len(found) != 1:
        why = "no status named %s" % wanted if not found else "%d statuses named %s" % (len(found), wanted)
        return answer("%s in %s's status collection: left as %s" % (why, item["number"], current_name))
    status = found[0]
    if status["id"] == item["statusId"]:
        return answer("%s is already %s" % (item["number"], status["name"]))
    return answer("move %s from %s to %s" % (item["number"], current_name, status["name"]), status)


def main(argv):
    if len(argv) != 2 or argv[1] != "decide":
        sys.stderr.write("item-status: usage: item-status.py decide < request.json\n")
        return 2
    try:
        request = json.loads(sys.stdin.read())
    except ValueError as err:
        sys.stderr.write("item-status: the request is not JSON: %s\n" % err)
        return 2
    try:
        result = decide(request)
    except Refuse as err:
        sys.stderr.write("item-status: %s\n" % err)
        return 2
    sys.stdout.write(json.dumps(result, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as err:  # never a traceback on the caller's screen
        sys.stderr.write("item-status: internal error: %s\n" % err)
        sys.exit(1)
