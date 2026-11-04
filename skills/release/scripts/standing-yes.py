#!/usr/bin/env python3
"""May this release merge on the owner's standing yes? `release.lightRelease.standingYes`.

The rules are in `skills/release/references/auto-start.md`. Release step 4 runs this after its
pre-merge check and recap, with the evidence it already gathered; MERGE replaces the in-the-moment
yes, anything else goes to the owner exactly as before.

  standing-yes.py --pr <n> --head <sha> --reviewed-tree <tree> --class "<RELEASE CLASS line>"
                  --checks green|red --unresolved <count> --pre-ship "<PRE-SHIP verdict line>"
                  --previous-release <gate exit> [--dev-deploy <exit>] --tower "<status output>"
      MERGE                     exit 0
      ASK <reason>              exit 0   (the first condition that fails, in the order below)
      ERROR <reason>            exit 1   (bad arguments or an unreadable config: treat as ASK)

MERGE needs ALL of, in this order:
  1. `release.lightRelease.standingYes` is true in .claude/ds-config.json;
  2. the class line is exactly `RELEASE CLASS: LIGHT`;
  3. `git rev-parse <head>^{tree}` equals --reviewed-tree (the tree the train review approved);
  4. --checks is `green` (every required check on the head succeeded);
  5. --unresolved is 0 (the paginated unresolved-thread count);
  6. the pre-ship line is `PRE-SHIP: PASS (<n> ran, 0 waived)` or `PRE-SHIP: NOTHING TO RUN`;
  7. --previous-release is 0 (the previous-release gate);
  8. --dev-deploy, when given, is 0 (the dev-deploy wait, when it applies);
  9. the tower status has the line `On final: #<pr> ...` for this pull request.
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
    parser.add_argument("--reviewed-tree", required=True)
    parser.add_argument("--class", dest="klass", required=True)
    parser.add_argument("--checks", choices=["green", "red"], required=True)
    parser.add_argument("--unresolved", type=int, required=True)
    parser.add_argument("--pre-ship", required=True)
    parser.add_argument("--previous-release", type=int, required=True)
    parser.add_argument("--dev-deploy", type=int)
    parser.add_argument("--tower", required=True)
    a = parser.parse_args()

    release = load_config().get("release")
    light = release.get("lightRelease") if isinstance(release, dict) else None
    if not (isinstance(light, dict) and light.get("standingYes") is True):
        say("ASK the standing yes is off (release.lightRelease.standingYes is not true)")
    if a.klass.strip() != "RELEASE CLASS: LIGHT":
        say("ASK not a light release (%s)" % (a.klass.strip() or "no class line"))
    tree = tree_of(a.head)
    if tree is None:
        say("ASK the head %s cannot be read" % a.head)
    if tree != a.reviewed_tree.strip():
        say("ASK the head's tree %s differs from the reviewed train tree %s" % (tree[:12], a.reviewed_tree.strip()[:12]))
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
    if a.dev_deploy is not None and a.dev_deploy != 0:
        say("ASK the dev-deploy wait answered %d, not 0" % a.dev_deploy)
    if not re.search(r"^On final: #%d\b" % a.pr, a.tower, re.MULTILINE):
        say("ASK pull request #%d is not On final in the tower status" % a.pr)
    say("MERGE")


if __name__ == "__main__":
    main()
