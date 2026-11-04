#!/usr/bin/env python3
"""A fake `gh` for scripts/tests/previous-release-gate.sh and post-deploy-status.sh, served from
FAKE_GH_STATE: prs.json (merged pull requests), status-<sha>.json (a list of statuses, the first
of each context the latest; `pending-then-<state>` in a file `flip-<sha>` turns the second read
into <state>), gh-down (every call fails). Every call is appended to calls.log."""
import json, os, sys

STATE = os.environ["FAKE_GH_STATE"]
args = sys.argv[1:]
with open(os.path.join(STATE, "calls.log"), "a") as handle:
    handle.write(json.dumps(args) + "\n")
if os.path.exists(os.path.join(STATE, "gh-down")):
    sys.stderr.write("gh: error connecting to api.github.com\n"); sys.exit(1)
if args[:2] == ["pr", "list"]:
    path = os.path.join(STATE, "prs.json")
    print(open(path).read() if os.path.exists(path) else "[]"); sys.exit(0)
if args[:2] == ["api", "--method"]:
    print("{}"); sys.exit(0)
if args[0] == "api" and args[1].endswith("/status"):
    sha = args[1].split("/")[-2]
    flip = os.path.join(STATE, "flip-" + sha)
    if os.path.exists(flip):
        reads = os.path.join(STATE, "reads-" + sha)
        count = int(open(reads).read()) if os.path.exists(reads) else 0
        open(reads, "w").write(str(count + 1))
        state = "pending" if count == 0 else open(flip).read().strip()
        print(json.dumps({"statuses": [{"context": "release/post-deploy", "state": state, "description": "release/26-11-03 by m5 / wt1-ab"}]}))
        sys.exit(0)
    path = os.path.join(STATE, "status-%s.json" % sha)
    print(json.dumps({"statuses": json.load(open(path)) if os.path.exists(path) else []})); sys.exit(0)
sys.stderr.write("fake gh: unexpected call %s\n" % args); sys.exit(1)
