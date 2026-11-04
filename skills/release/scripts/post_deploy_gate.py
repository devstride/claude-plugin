#!/usr/bin/env python3
"""The post-deploy outcome a release records, and the gate the next release reads.

Only under `release.clearance.scope: "cut-to-deploy"`: the release hands its clearance back once
the deploy is confirmed, so the post-deploy check runs AFTER the hand-back. Its result is the
commit status `release/post-deploy` on the production merge commit, where every machine can read
it, and the next release refuses to MERGE (never to cut, review or hotfix) until it is success.
Under the default scope (`release`, or absent) both commands do nothing and say so.

  status <sha> <pending|success|failure|error> <description>
      POST-DEPLOY STATUS: POSTED <state> on <sha> | SKIPPED (<why>)         0 · 1 error
  gate [--wait]
      PREVIOUS RELEASE: SUCCESS | NONE | NOT GATED                           0
      PREVIOUS RELEASE: FAILED                                               1
      PREVIOUS RELEASE: PENDING                                              2
      PREVIOUS RELEASE: NO STATUS                                            3
      PREVIOUS RELEASE: UNREADABLE                                           4
    --wait polls a PENDING status every POST_DEPLOY_POLL_SECONDS (60) for at most
    POST_DEPLOY_WAIT_MINUTES (45), then reports what it last read.

The previous release is the newest merged pull request into `release.productionBranch` whose head
matches `release.releaseBranchPattern` under the anchored rule (references/branch-patterns.md), or
whose head IS `release.releaseSource` when no pattern is set. Hotfix merges never count.
Test seams: POST_DEPLOY_REPO (owner/name; else `gh repo view`), the two timing variables above.
"""
import json
import os
import re
import subprocess
import sys
import time

CONTEXT = "release/post-deploy"
STATES = ("pending", "success", "failure", "error")
SCOPES = ("release", "cut-to-deploy")
DESCRIPTION_LIMIT = 140  # GitHub's own limit for a commit status description


def fail(message, code=1):
    sys.stderr.write("post-deploy: %s\n" % message)
    sys.exit(code)


def load_config():
    here = os.path.abspath(os.getcwd())
    while True:
        candidate = os.path.join(here, ".claude", "ds-config.json")
        if os.path.isfile(candidate):
            try:
                with open(candidate) as handle:
                    loaded = json.load(handle)
            except (OSError, ValueError) as error:
                fail("%s cannot be read as JSON (%s)" % (candidate, error))
            return loaded if isinstance(loaded, dict) else {}
        parent = os.path.dirname(here)
        if parent == here:
            return {}
        here = parent


def section(config, key):
    value = config.get(key)
    return value if isinstance(value, dict) else {}


CONFIG = load_config()
RELEASE = section(CONFIG, "release")
CLEARANCE = section(RELEASE, "clearance")


def scope():
    value = CLEARANCE.get("scope")
    if value is None:
        return "release"
    if value not in SCOPES:
        fail("release.clearance.scope is %r; it must be \"release\" or \"cut-to-deploy\"" % (value,))
    return value


def pattern_regex(pattern):
    source, rest = "", pattern
    while rest:
        if rest.startswith("**"):
            source, rest = source + ".+", rest[2:]
        elif rest.startswith("*"):
            source, rest = source + "[^/]+", rest[1:]
        elif rest == "[-n]":
            source, rest = source + "(-[0-9]+)?", ""
        elif re.match(r"^<[A-Z]{2}-[A-Z]{2}-[A-Z]{2}>", rest):
            source, rest = source + "[0-9]{2}-[0-9]{2}-[0-9]{2}", rest[10:]
        else:
            source, rest = source + re.escape(rest[0]), rest[1:]
    return re.compile("^" + source + "$")


class GhError(Exception):
    pass


def gh(args):
    try:
        done = subprocess.run(["gh"] + args, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise GhError(str(error))
    if done.returncode != 0:
        raise GhError((done.stderr or done.stdout).strip()[:300])
    return done.stdout


def repo():
    name = os.environ.get("POST_DEPLOY_REPO") or gh(["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"]).strip()
    if not re.match(r"^[^/\s]+/[^/\s]+$", name):
        raise GhError("could not determine the repository (gh repo view)")
    return name


def cap(text):
    text = " ".join(text.split())
    return text if len(text) <= DESCRIPTION_LIMIT else text[: DESCRIPTION_LIMIT - 1] + "…"


def cmd_status(argv):
    if len(argv) != 3:
        fail("usage: post-deploy-status.sh <sha> <pending|success|failure|error> <description>", 2)
    sha, state, description = argv
    if scope() != "cut-to-deploy":
        print("POST-DEPLOY STATUS: SKIPPED (release.clearance.scope is release; nothing is posted)")
        return 0
    if not re.match(r"^[0-9a-f]{40}$", sha):
        fail("the sha must be the full 40-character merge commit, not %r" % sha, 2)
    if state not in STATES:
        fail("the state must be one of %s, not %r" % (", ".join(STATES), state), 2)
    if not description.strip():
        fail("the description names the release, the machine and the session; it is empty", 2)
    try:
        gh(["api", "--method", "POST", "repos/%s/statuses/%s" % (repo(), sha),
            "-f", "state=" + state, "-f", "context=" + CONTEXT, "-f", "description=" + cap(description)])
    except GhError as error:
        print("POST-DEPLOY STATUS: FAILED %s" % error)
        return 1
    print("POST-DEPLOY STATUS: POSTED %s on %s" % (state, sha[:12]))
    return 0


def previous_release(name):
    production = RELEASE.get("productionBranch") or "main"
    pattern = RELEASE.get("releaseBranchPattern")
    source = RELEASE.get("releaseSource") or CONFIG.get("baseBranch") or "develop"
    is_release = pattern_regex(pattern).match if isinstance(pattern, str) and pattern else (lambda head: head == source)
    merged = json.loads(gh(["pr", "list", "--repo", name, "--base", production, "--state", "merged",
                            "--json", "number,headRefName,mergeCommit,mergedAt", "--limit", "20"]) or "[]")
    merged = [pr for pr in merged if isinstance(pr, dict) and pr.get("mergedAt")]
    merged.sort(key=lambda pr: pr["mergedAt"], reverse=True)
    for pr in merged:
        if is_release(pr.get("headRefName") or "") and (pr.get("mergeCommit") or {}).get("oid"):
            return pr
    return None


def read_status(name, sha):
    combined = json.loads(gh(["api", "repos/%s/commits/%s/status" % (name, sha)]) or "{}")
    for entry in combined.get("statuses") or []:
        if entry.get("context") == CONTEXT:
            return entry.get("state"), entry.get("description") or ""
    return None, ""


def cmd_gate(argv):
    wait = argv == ["--wait"]
    if argv and not wait:
        fail("usage: previous-release-gate.sh [--wait]", 2)
    if scope() != "cut-to-deploy":
        print("PREVIOUS RELEASE: NOT GATED (release.clearance.scope is release)")
        return 0
    poll = int(os.environ.get("POST_DEPLOY_POLL_SECONDS") or 60)
    deadline = time.time() + 60 * float(os.environ.get("POST_DEPLOY_WAIT_MINUTES") or 45)
    try:
        name = repo()
        pr = previous_release(name)
        if pr is None:
            print("PREVIOUS RELEASE: NONE — no earlier release merge into the production branch")
            return 0
        label = "%s (#%s)" % (pr["headRefName"], pr["number"])
        sha = pr["mergeCommit"]["oid"]
        while True:
            state, description = read_status(name, sha)
            if state != "pending" or not wait or time.time() >= deadline:
                break
            print("waiting: %s post-deploy check is running — %s" % (label, description), flush=True)
            time.sleep(poll)
    except (GhError, ValueError) as error:
        print("PREVIOUS RELEASE: UNREADABLE %s" % error)
        return 4
    if state == "success":
        print("PREVIOUS RELEASE: SUCCESS %s — %s" % (label, description))
        return 0
    if state == "pending":
        print("PREVIOUS RELEASE: PENDING %s — %s%s" % (label, description,
              "; still pending after the wait. Finish it with /devstride:release post-deploy only" if wait else ""))
        return 2
    if state in ("failure", "error"):
        print("PREVIOUS RELEASE: FAILED %s — %s" % (label, description))
        return 1
    print("PREVIOUS RELEASE: NO STATUS %s has no %s status (a release from before this scope, or its check never posted)" % (label, CONTEXT))
    return 3


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("status", "gate"):
        fail("usage: post_deploy_gate.py status|gate ...", 2)
    sys.exit(cmd_status(sys.argv[2:]) if sys.argv[1] == "status" else cmd_gate(sys.argv[2:]))


if __name__ == "__main__":
    main()
