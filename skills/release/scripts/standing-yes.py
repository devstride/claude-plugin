#!/usr/bin/env python3
"""May this release merge on the owner's standing yes? `release.lightRelease.standingYes`.

The rules are in `skills/release/references/auto-start.md`. Release step 4 runs this after its
pre-merge check and recap, with the evidence it already gathered; MERGE replaces the in-the-moment
yes, anything else goes to the owner exactly as before.

  standing-yes.py --pr <n> --head <sha> --class "<RELEASE CLASS line>"
                  --checks green|red --unresolved <count> --pre-ship "<PRE-SHIP verdict line>"
                  --pre-merge "<PRE-MERGE verdict line>" --previous-release <gate exit> --dev-deploy <exit>|not-applicable --tower "<status output>"
      MERGE <head sha>          exit 0   (merge only that exact head: `gh pr merge --match-head-commit`)
      ASK <reason>              exit 0   (the first condition that fails, in the order below)
      ERROR <reason>            exit 1   (bad arguments or an unreadable config: treat as ASK)

The configuration is read from the release head itself (`git show <head>:.claude/ds-config.json`),
never from the working folder: the consent has to be part of what was reviewed.

MERGE needs ALL of, in this order:
  1. `release.lightRelease.standingYes` is true in the head's .claude/ds-config.json, and `release.clearance` is
     usable: `provider` `github` or `devstride` alone, or `commands` alone with claim, status,
     heartbeat, release and adopt each a non-empty string (only a live tower says who is On final),
     and `release.classifySkill` is a non-empty string (with no classifier, LIGHT is only a claim);
  2. the class line is exactly `RELEASE CLASS: LIGHT`;
  3. the pull request is OPEN into `release.productionBranch` (default master), --head is its
     CURRENT head (`gh pr view <pr>`, read here), and
     its tree equals the tree of the head the train review approved. That train is found here, never
     passed in: the latest merged release-train pull request into the release source, by the release
     skill's own search (both titles, `Release train:` and `Support train:`, each with its body
     marker), whose merge commit is an ancestor of --head; its `headRefOid` is the reviewed head;
  4. --checks is `green` (every required check on the head succeeded);
  5. --unresolved is 0 (the paginated unresolved-thread count);
  6. the pre-ship line is `PRE-SHIP: PASS (<n> ran, 0 waived)` or `PRE-SHIP: NOTHING TO RUN`, and
     the pre-merge line is `PRE-MERGE: CLEAR`, or `PRE-MERGE: NOT CONFIGURED` only when
     `release.preMergeSkill` is absent or null (HOLD and NOT RUN are the owner's decision);
  7. --previous-release is 0 (the previous-release gate);
  8. --dev-deploy is 0 (the dev-deploy wait, run BEFORE this check); `not-applicable` only when
     `release.devDeployVerification` is absent or null (any other value, an empty string included,
     is configured);
  9. the tower status has exactly one `On final:` line, and it reads `On final: #<pr> <head>` for
     this pull request (digits, then whitespace).
"""
import argparse
import json
import os
import re
import subprocess
import sys


def say(line, code=0):
    print(line)
    sys.exit(code)


def load_config(head):
    """The release head's own .claude/ds-config.json; {} when that commit has none."""
    done = subprocess.run(["git", "show", "%s:.claude/ds-config.json" % head], capture_output=True, text=True)
    if done.returncode != 0:
        return {}
    try:
        loaded = json.loads(done.stdout)
    except ValueError as error:
        say("ERROR .claude/ds-config.json at %s cannot be read as JSON (%s)" % (head[:12], error), 1)
    return loaded if isinstance(loaded, dict) else {}


def pr_view(number):
    """`gh pr view <n>`: the live record of one pull request, or None."""
    try:
        done = subprocess.run(["gh", "pr", "view", str(number), "--json", "state,title,baseRefName,headRefOid"],
                              capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if done.returncode != 0:
        return None
    try:
        found = json.loads(done.stdout or "null")
    except ValueError:
        return None
    return found if isinstance(found, dict) else None


TRAIN_TITLES = (("Release train:", "devstride:release-train"), ("Support train:", "devstride:support-train"))


def latest_train(source):
    """The latest merged release-train pull request into `source`, or None when gh cannot answer."""
    rows = []
    for title, _marker in TRAIN_TITLES:
        try:
            done = subprocess.run(["gh", "pr", "list", "--base", source, "--state", "merged", "--search",
                                   'in:title "%s" sort:created-desc' % title, "--json",
                                   "number,title,body,mergedAt,headRefOid,mergeCommit", "--limit", "50"],
                                  capture_output=True, text=True, timeout=60)
        except (OSError, subprocess.TimeoutExpired):
            return None
        if done.returncode != 0:
            return None
        try:
            found = json.loads(done.stdout or "[]")
        except ValueError:
            return None
        rows += [r for r in found if isinstance(r, dict)]
    trains = [r for r in rows if any(str(r.get("title", "")).startswith(t) and m in str(r.get("body", ""))
                                     for t, m in TRAIN_TITLES) and r.get("mergedAt")]
    return max(trains, key=lambda r: str(r["mergedAt"])) if trains else {}


def is_ancestor(older, newer):
    return subprocess.run(["git", "merge-base", "--is-ancestor", older, newer], capture_output=True).returncode == 0


CLEARANCE_VERBS = ("claim", "status", "heartbeat", "release", "adopt")


def usable_clearance(clearance):
    if not isinstance(clearance, dict):
        return False
    provider, commands = clearance.get("provider"), clearance.get("commands")
    if provider is not None and commands is not None:
        return False
    if provider is not None:
        return provider in ("github", "devstride")
    return isinstance(commands, dict) and all(isinstance(commands.get(v), str) and commands[v].strip()
                                              for v in CLEARANCE_VERBS)


def full_sha(rev):
    done = subprocess.run(["git", "rev-parse", "--verify", "%s^{commit}" % rev], capture_output=True, text=True)
    return done.stdout.strip() if done.returncode == 0 else None


def tree_of(head):
    done = subprocess.run(["git", "rev-parse", "%s^{tree}" % head], capture_output=True, text=True)
    return done.stdout.strip() if done.returncode == 0 else None


class Parser(argparse.ArgumentParser):
    def error(self, message):
        say("ERROR %s" % message, 1)


def main():
    parser = Parser(prog="standing-yes.py")
    parser.add_argument("--pr", type=int, required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--class", dest="klass", required=True)
    parser.add_argument("--checks", choices=["green", "red"], required=True)
    parser.add_argument("--unresolved", type=int, required=True)
    parser.add_argument("--pre-ship", required=True)
    parser.add_argument("--pre-merge", required=True)
    parser.add_argument("--previous-release", type=int, required=True)
    parser.add_argument("--dev-deploy", required=True)
    parser.add_argument("--tower", required=True)
    a = parser.parse_args()

    head = full_sha(a.head)
    if head is None:
        say("ASK the head %s cannot be read" % a.head)
    config = load_config(head)
    release = config.get("release")
    light = release.get("lightRelease") if isinstance(release, dict) else None
    if not (isinstance(light, dict) and light.get("standingYes") is True):
        say("ASK the standing yes is off (release.lightRelease.standingYes is not true)")
    if not usable_clearance(release.get("clearance")):
        say("ASK no usable release.clearance is configured, so no tower can show this release On final")
    classifier = release.get("classifySkill")
    if not (isinstance(classifier, str) and classifier.strip()):
        say("ASK no release.classifySkill is configured, so nothing has shown this release is light")
    if a.klass.strip() != "RELEASE CLASS: LIGHT":
        say("ASK not a light release (%s)" % (a.klass.strip() or "no class line"))
    release_pr = pr_view(a.pr)
    live = str(release_pr.get("headRefOid") or "").strip() if release_pr else ""
    if not live:
        say("ASK the current head of pull request #%d cannot be read" % a.pr)
    production = release.get("productionBranch") or "master"
    if release_pr.get("state") != "OPEN" or release_pr.get("baseRefName") != production:
        say("ASK pull request #%d is not open into %s (%s into %s)" % (a.pr, production, release_pr.get("state"), release_pr.get("baseRefName")))
    if live != head:
        say("ASK pull request #%d is at %s, not the head %s this check was given" % (a.pr, live[:12], head[:12]))
    source = (release.get("releaseSource") if isinstance(release, dict) else None) or "develop"
    train = latest_train(source)
    if train is None:
        say("ASK the merged release-train pull requests into %s cannot be read" % source)
    if not train:
        say("ASK no merged release-train pull request into %s: nothing reviewed to compare with" % source)
    merge = str((train.get("mergeCommit") or {}).get("oid") or "")
    if not merge or not is_ancestor(merge, head):
        say("ASK the latest train #%s is not merged into the head %s" % (train.get("number"), head[:12]))
    reviewed = tree_of(str(train.get("headRefOid") or ""))
    if reviewed is None:
        say("ASK the reviewed train head of #%s cannot be read" % train.get("number"))
    tree = tree_of(head)
    if tree != reviewed:
        say("ASK the head's tree %s differs from the reviewed train tree %s" % (tree[:12], reviewed[:12]))
    if a.checks != "green":
        say("ASK a required check on the head is not green")
    if a.unresolved != 0:
        say("ASK %d review thread(s) unresolved" % a.unresolved)
    pre = a.pre_ship.strip()
    passed = re.match(r"^PRE-SHIP: PASS \((\d+) ran, (\d+) waived\)$", pre)
    if not (pre == "PRE-SHIP: NOTHING TO RUN" or (passed and passed.group(2) == "0")):
        say("ASK the pre-ship checks did not all pass unwaived (%s)" % (pre or "no verdict"))
    merge_check = a.pre_merge.strip()
    hook = release.get("preMergeSkill")
    allowed = ("PRE-MERGE: CLEAR",) if hook is not None else ("PRE-MERGE: CLEAR", "PRE-MERGE: NOT CONFIGURED")
    if merge_check not in allowed:
        say("ASK the pre-merge check did not clear (%s)" % (merge_check or "no verdict"))
    if a.previous_release != 0:
        say("ASK the previous-release gate answered %d, not 0" % a.previous_release)
    dev = a.dev_deploy.strip()
    configured = isinstance(release, dict) and release.get("devDeployVerification") is not None
    if dev == "not-applicable" and configured:
        say("ASK release.devDeployVerification is configured: run the dev-deploy wait and pass its exit")
    if dev not in ("0", "not-applicable"):
        say("ASK the dev-deploy wait answered %s, not 0" % (dev or "nothing"))
    finals = [line for line in a.tower.splitlines() if line.startswith("On final:")]
    parsed = re.match(r"^On final: #(\d+)\s+\S", finals[0]) if len(finals) == 1 else None
    if not parsed or int(parsed.group(1)) != a.pr:
        say("ASK pull request #%d is not the one release On final in the tower status" % a.pr)
    say("MERGE %s" % head)


if __name__ == "__main__":
    main()
