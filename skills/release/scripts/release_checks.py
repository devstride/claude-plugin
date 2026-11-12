#!/usr/bin/env python3
"""The check stamp: proof that a release's pre-claim checks still describe the code it will merge.

Scope `merge-and-deploy` (references/clearance.md, § Scope `merge-and-deploy`) runs the release's
pre-ship checks, the dev-deploy wait and the pre-merge check BEFORE it claims the tower, at the
commit the release branch will be cut from. The stamp records what they tested: the head commit,
its tree, the production tip at that moment, and the release class. Every later (re-)claim and the
moment before the merge verify it: a tested tree is the merged tree only while both the head's
tree and the production tip are unchanged (the merge result is a function of the two).

  stamp --head <sha> --class <LIGHT|FULL>
      CHECKS STAMP head <h> tree <t> master <m> class <c> at <iso>                 exit 0
  verify --stamp '<stamp line>' --head <sha>
      UNCHANGED head <h> tree <t> master <m>                                       exit 0
      CHANGED tree <old>..<new> | CHANGED master <old>..<new> (both when both)     exit 3
  Any error (a stamp that cannot be parsed, an unknown commit, a failed fetch)  → ERROR <why>, exit 1;
  never UNCHANGED.

`master` in the line is the production branch's tip (`release.productionBranch`, default master),
read from origin after a fetch. Git only; no gh, no network beyond `git fetch origin`. Test seam:
RELEASE_CHECKS_NO_FETCH=1 skips the fetch (the caller fetched), RELEASE_CHECKS_NOW replaces the clock.
"""
import datetime
import json
import os
import re
import subprocess
import sys

SHA = r"[0-9a-f]{40}"
STAMP = re.compile(r"^CHECKS STAMP head (%s) tree (%s) master (%s) class (LIGHT|FULL)(?: at (\S+))?$" % (SHA, SHA, SHA))


class Error(Exception):
    pass


def git(*args):
    done = subprocess.run(["git"] + list(args), capture_output=True, text=True)
    if done.returncode != 0:
        last = (done.stderr or "").strip().splitlines()
        raise Error("git %s failed: %s" % (" ".join(args), last[-1] if last else "exit %d" % done.returncode))
    return done.stdout.strip()


def production_branch():
    here = os.path.abspath(os.getcwd())
    while True:
        path = os.path.join(here, ".claude", "ds-config.json")
        if os.path.isfile(path):
            try:
                with open(path) as handle:
                    config = json.load(handle)
            except (OSError, ValueError) as error:
                raise Error("%s cannot be read as JSON (%s)" % (path, error))
            release = config.get("release") if isinstance(config, dict) else None
            value = release.get("productionBranch") if isinstance(release, dict) else None
            return value if isinstance(value, str) and value else "master"
        parent = os.path.dirname(here)
        if parent == here:
            return "master"
        here = parent


def facts(head):
    production = production_branch()
    if os.environ.get("RELEASE_CHECKS_NO_FETCH") != "1":
        git("fetch", "-q", "origin", "+refs/heads/%s:refs/remotes/origin/%s" % (production, production))
    commit = git("rev-parse", "--verify", "%s^{commit}" % head)
    tree = git("rev-parse", "--verify", "%s^{tree}" % commit)
    tip = git("rev-parse", "--verify", "refs/remotes/origin/%s^{commit}" % production)
    return commit, tree, tip


def option(args, name):
    if name in args:
        i = args.index(name)
        if i + 1 < len(args):
            return args[i + 1]
    return None


def cmd_stamp(args):
    head, klass = option(args, "--head"), (option(args, "--class") or "").upper()
    if not head or klass not in ("LIGHT", "FULL"):
        raise Error("usage: release_checks.py stamp --head <sha> --class <LIGHT|FULL>")
    commit, tree, tip = facts(head)
    at = os.environ.get("RELEASE_CHECKS_NOW") or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print("CHECKS STAMP head %s tree %s master %s class %s at %s" % (commit, tree, tip, klass, at))
    return 0


def cmd_verify(args):
    line, head = option(args, "--stamp"), option(args, "--head")
    if not line or not head:
        raise Error("usage: release_checks.py verify --stamp '<stamp line>' --head <sha>")
    match = STAMP.match(line.strip())
    if not match:
        raise Error("the stamp cannot be parsed: %r" % line.strip()[:200])
    _, old_tree, old_tip = match.group(1), match.group(2), match.group(3)
    commit, tree, tip = facts(head)
    changed = []
    if tree != old_tree:
        changed.append("CHANGED tree %s..%s" % (old_tree[:12], tree[:12]))
    if tip != old_tip:
        changed.append("CHANGED master %s..%s" % (old_tip[:12], tip[:12]))
    if changed:
        print("\n".join(changed))
        return 3
    print("UNCHANGED head %s tree %s master %s" % (commit, tree, tip))
    return 0


def main(argv):
    commands = {"stamp": cmd_stamp, "verify": cmd_verify}
    if not argv or argv[0] not in commands:
        print("usage: release_checks.py stamp --head <sha> --class <LIGHT|FULL> | verify --stamp '<line>' --head <sha>")
        return 2
    try:
        return commands[argv[0]](argv[1:])
    except Error as error:
        print("ERROR %s" % error)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
