#!/usr/bin/env python3
"""May this release claim the tower now? The queue rule of scope `merge-and-deploy`.

Under `release.clearance.scope` `"merge-and-deploy"` a release claims the tower only while no OTHER
release pull request is open into the production branch, so a release that stepped aside (its pull
request still open, waiting for the owner or the previous release's post-deploy check) always finds
the tower free when it claims again, and releases merge oldest first, one at a time
(references/clearance.md, § Scope `merge-and-deploy`).

  check [--own-pr <n>]
      CLEAR (<why>)                       no release pull request but <n> is open        exit 0
      WAIT #<n> <head> (<why>)            another release pull request is open           exit 2
      WAIT status unreadable (<why>)      unknown, not derived, or no provider           exit 2
      ERROR <why>                         a config error                                 exit 1

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
        print("WAIT #%s %s (another release pull request is open into production; it merges first)" % (number, pr.get("head") or "?"))
        return 2
    print("CLEAR (%s)" % ("only this release's pull request #%d is open" % own if own is not None and queue else "no other release pull request is open"))
    return 0


def main(argv):
    if not argv or argv[0] != "check":
        print("usage: tower-queue.py check [--own-pr <n>]")
        return 2 if argv else 1
    return check(argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
