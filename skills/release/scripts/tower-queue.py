#!/usr/bin/env python3
"""May this release be cut now, and later claim the tower? The queue rule of scope `merge-and-deploy`.

Under `release.clearance.scope` `"merge-and-deploy"` a release is cut only while no OTHER release
pull request is open into the production branch (run before the cut, without `--own-pr`), and
claims the tower for its merge and deploy only while that still holds (run at step 4 with
`--own-pr`). So the release ahead has always merged, or closed, before the next is cut: the next is
cut on top of its merge and checked and tested while it deploys, a release waiting for the owner or
the previous release's post-deploy check (its pull request still open, the tower not held) keeps
every later release behind it, and releases merge in the order they were cut, one at a time
(references/clearance.md, § Scope `merge-and-deploy`).

  check [--own-pr <n>] [--waited-minutes <m>]
      CLEAR (<why>)                       no release pull request but <n> is open        exit 0
      WAIT #<n> <head> (<why>)            another release pull request is open           exit 2
      ASK #<n> <head> (<why>)             the same, and this release has waited at least exit 3
                                          staleMinutes behind it (`--waited-minutes`)
      WAIT status unreadable (<why>)      unknown, not derived, or no provider           exit 2
      ERROR <why>                         a config error                                 exit 1

ASK exists because a release that stepped aside holds nothing that heartbeats: if its session ended
while it waited for the owner, nothing would ever say so, and every later release would wait the
whole of `waitMinutes` (default 180) before it could even ask. So once a release has waited
`release.clearance.staleMinutes` (default 20) behind another release pull request, the queue says
ASK once: the caller tells the owner which pull request it waits behind (it may only be waiting for
their go-ahead, or its session may have stopped) and keeps waiting; it adopts that release only on
the owner's yes and their word that its session stopped.

It reads the clearance provider's `status --json` (`release.clearance.commands.status`, or the
built-in `provider`), whose `onFinal` and `waiting` list only release heads (a hotfix pull request is
never one). Unreadable is never clear. It claims nothing and writes nothing.
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def load_config():
    here = os.path.abspath(os.getcwd())
    while True:
        path = os.path.join(here, ".claude", "ds-config.json")
        if os.path.isfile(path):
            with open(path) as handle:
                config = json.load(handle)
            if not isinstance(config, dict):
                raise ValueError("%s is not a JSON object" % path)
            return config, here
        parent = os.path.dirname(here)
        if parent == here:
            return {}, os.getcwd()
        here = parent


def status_argv(block):
    commands = block.get("commands") if isinstance(block.get("commands"), dict) else None
    if commands:
        command = commands.get("status")
        if not isinstance(command, str) or not command.strip():
            return None
        return ["/bin/sh", "-c", command + " --json"]
    if block.get("provider") in ("github", "devstride"):
        return ["bash", os.path.join(HERE, "clearance-%s.sh" % block["provider"]), "status", "--json"]
    return None


def check(args):
    own = None
    if "--own-pr" in args:
        i = args.index("--own-pr")
        if i + 1 >= len(args) or not args[i + 1].lstrip("#").isdigit():
            print("ERROR --own-pr needs a pull request number")
            return 1
        own = int(args[i + 1].lstrip("#"))
    waited = None
    if "--waited-minutes" in args:
        i = args.index("--waited-minutes")
        if i + 1 >= len(args) or not args[i + 1].isdigit():
            print("ERROR --waited-minutes needs a whole number of minutes")
            return 1
        waited = int(args[i + 1])
    try:
        config, root = load_config()
    except (OSError, ValueError) as error:
        print("ERROR the config cannot be read (%s)" % error)
        return 1
    release = config.get("release") if isinstance(config.get("release"), dict) else {}
    block = release.get("clearance")
    if not isinstance(block, dict):
        print("ERROR release.clearance is not set: there is no tower to queue for")
        return 1
    argv = status_argv(block)
    if argv is None:
        print("WAIT status unreadable (release.clearance names no status command or built-in provider)")
        return 2
    try:
        done = subprocess.run(argv, cwd=root, capture_output=True, text=True, timeout=180)
    except (OSError, subprocess.TimeoutExpired) as error:
        print("WAIT status unreadable (%s)" % error)
        return 2
    lines = done.stdout.strip().splitlines()
    try:
        status = json.loads(lines[-1]) if lines else None
    except ValueError:
        status = None
    if done.returncode != 0 or not isinstance(status, dict) or status.get("state") not in ("clear", "held"):
        why = status.get("error") if isinstance(status, dict) and status.get("error") else "exit %d" % done.returncode
        print("WAIT status unreadable (%s)" % why)
        return 2
    if status.get("derived") is not True:
        print("WAIT status unreadable (its release pull requests were not derived)")
        return 2
    queue = []
    if isinstance(status.get("onFinal"), dict):
        queue.append(status["onFinal"])
    queue += [w for w in status.get("waiting") or [] if isinstance(w, dict)]
    for pr in queue:
        number = pr.get("number")
        if number is None or (own is not None and int(number) == own):
            continue
        stale = block.get("staleMinutes")
        stale = stale if isinstance(stale, int) and not isinstance(stale, bool) and stale > 0 else 20
        if waited is not None and waited >= stale:
            print("ASK #%s %s (this release has waited %d min behind it, outside the tower; it may be waiting for the "
                  "owner's go-ahead, or its session may have stopped: tell the owner once, keep waiting, and adopt it "
                  "only on their yes and their word that its session stopped)" % (number, pr.get("head") or "?", waited))
            return 3
        print("WAIT #%s %s (another release pull request is open into production; it merges first)" % (number, pr.get("head") or "?"))
        return 2
    print("CLEAR (%s)" % ("only this release's pull request #%d is open" % own if own is not None and queue else "no other release pull request is open"))
    return 0


def main(argv):
    if not argv or argv[0] != "check":
        print("usage: tower-queue.py check [--own-pr <n>] [--waited-minutes <m>]")
        return 2 if argv else 1
    return check(argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
