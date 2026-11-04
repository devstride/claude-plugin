#!/usr/bin/env python3
"""May this release merge on the owner's standing yes? `release.lightRelease.standingYes`.

The rules are in `skills/release/references/auto-start.md`. Release step 4 runs this after its
pre-merge check and recap, with the evidence it already gathered; MERGE replaces the in-the-moment
yes, anything else goes to the owner exactly as before.

  standing-yes.py --pr <n> --head <sha> --train-pr <n> --class "<RELEASE CLASS line>"
                  --checks green|red --unresolved <count> --pre-ship "<PRE-SHIP verdict line>"
                  --previous-release <gate exit> --dev-deploy <exit>|not-applicable --tower "<status output>"
      MERGE <head sha>          exit 0   (merge only that exact head: `gh pr merge --match-head-commit`)
      ASK <reason>              exit 0   (the first condition that fails, in the order below)
      ERROR <reason>            exit 1   (bad arguments or an unreadable config: treat as ASK)

MERGE needs ALL of, in this order:
  1. `release.lightRelease.standingYes` is true in .claude/ds-config.json;
  2. the class line is exactly `RELEASE CLASS: LIGHT`;
  3. --head is the pull request's CURRENT head (`gh pr view <pr> --json headRefOid`, read here), and
     its tree equals the tree of the head the train review approved: --train-pr is the release-train
     pull request this release merged (a different number, read here: MERGED, title `Release train:`,
     base the release source), and its `headRefOid` is that head; both trees are computed here;
  4. --checks is `green` (every required check on the head succeeded);
  5. --unresolved is 0 (the paginated unresolved-thread count);
  6. the pre-ship line is `PRE-SHIP: PASS (<n> ran, 0 waived)` or `PRE-SHIP: NOTHING TO RUN`;
  7. --previous-release is 0 (the previous-release gate);
  8. --dev-deploy is 0, or `not-applicable` (the dev-deploy wait, run BEFORE this check when it applies);
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


def load_config():
    here = os.path.abspath(os.getcwd())
    while True:
        candidate = os.path.join(here, ".claude", "ds-config.json")
        if os.path.isfile(candidate):
            try:
                with open(candidate) as handle:
                    loaded = json.load(handle)
            except (OSError, ValueError) as error:
                say("ERROR %s cannot be read as JSON (%s)" % (candidate, error), 1)
            return loaded if isinstance(loaded, dict) else {}
        parent = os.path.dirname(here)
        if parent == here:
            return {}
        here = parent


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
    parser.add_argument("--train-pr", type=int, required=True)
    parser.add_argument("--class", dest="klass", required=True)
    parser.add_argument("--checks", choices=["green", "red"], required=True)
    parser.add_argument("--unresolved", type=int, required=True)
    parser.add_argument("--pre-ship", required=True)
    parser.add_argument("--previous-release", type=int, required=True)
    parser.add_argument("--dev-deploy", required=True)
    parser.add_argument("--tower", required=True)
    a = parser.parse_args()

    config = load_config()
    release = config.get("release")
    light = release.get("lightRelease") if isinstance(release, dict) else None
    if not (isinstance(light, dict) and light.get("standingYes") is True):
        say("ASK the standing yes is off (release.lightRelease.standingYes is not true)")
    if a.klass.strip() != "RELEASE CLASS: LIGHT":
        say("ASK not a light release (%s)" % (a.klass.strip() or "no class line"))
    head = full_sha(a.head)
    if head is None:
        say("ASK the head %s cannot be read" % a.head)
    release_pr = pr_view(a.pr)
    live = str(release_pr.get("headRefOid") or "").strip() if release_pr else ""
    if not live:
        say("ASK the current head of pull request #%d cannot be read" % a.pr)
    if live != head:
        say("ASK pull request #%d is at %s, not the head %s this check was given" % (a.pr, live[:12], head[:12]))
    if a.train_pr == a.pr:
        say("ASK --train-pr names the release pull request itself, not the reviewed train")
    train = pr_view(a.train_pr)
    source = (release.get("releaseSource") if isinstance(release, dict) else None) or "develop"
    if train is None:
        say("ASK the train pull request #%d cannot be read" % a.train_pr)
    if train.get("state") != "MERGED" or not str(train.get("title", "")).startswith("Release train:") \
            or train.get("baseRefName") != source:
        say("ASK #%d is not a merged release-train pull request into %s" % (a.train_pr, source))
    reviewed = tree_of(str(train.get("headRefOid") or ""))
    if reviewed is None:
        say("ASK the reviewed train head of #%d cannot be read" % a.train_pr)
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
    if a.previous_release != 0:
        say("ASK the previous-release gate answered %d, not 0" % a.previous_release)
    if a.dev_deploy.strip() not in ("0", "not-applicable"):
        say("ASK the dev-deploy wait answered %s, not 0" % (a.dev_deploy.strip() or "nothing"))
    finals = [line for line in a.tower.splitlines() if line.startswith("On final:")]
    parsed = re.match(r"^On final: #(\d+)\s+\S", finals[0]) if len(finals) == 1 else None
    if not parsed or int(parsed.group(1)) != a.pr:
        say("ASK pull request #%d is not the one release On final in the tower status" % a.pr)
    say("MERGE %s" % head)


if __name__ == "__main__":
    main()
