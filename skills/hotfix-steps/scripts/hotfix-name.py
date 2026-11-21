#!/usr/bin/env python3
"""The hotfix branch name, as code, so the shape the merge guard and the release checks recognise
never drifts from the rule in `skills/hotfix-steps/references/hotfix-branch.md`.

One JSON object in on stdin: {"config", "userName", "branchArgument", "today"} (`today` an ISO
date, so the answer is deterministic). One JSON object out on stdout:
{"branch", "prefix", "date", "slug", "matches", "pattern"}.

The prefix and the slug come from `skills/build-item/scripts/routing.py` (`prefix`, `slug`) and the
hotfix-pattern test from its `match`, so there is one implementation of each. The date renders
`branchNaming.dateFormat` (tokens YYYY, YY, MM, DD joined by hyphens), shipped default MM-DD-YY;
the repository's file wins. Exit 0 an answer, 2 a refusal (one `hotfix-name: <reason>` line on
stderr), 1 anything else. It touches neither git history nor the network.
"""
import datetime
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROUTING = os.path.join(os.path.dirname(os.path.dirname(HERE)), "build-item/scripts/routing.py")  # the skill beside this one
DEFAULT_FORMAT = "MM-DD-YY"
DEFAULT_HOTFIX_PATTERN = "*/hotfix/**"
TOKENS = {"YYYY": "%Y", "YY": "%y", "MM": "%m", "DD": "%d"}


class Refusal(Exception):
    pass


def routing(command, request):
    done = subprocess.run([sys.executable, "-B", ROUTING, command], input=json.dumps(request),
                          capture_output=True, text=True)
    if done.returncode == 2:
        raise Refusal(done.stderr.strip().split("\n")[-1].replace("routing: ", "", 1))
    if done.returncode != 0:
        raise RuntimeError("routing.py %s failed: %s" % (command, done.stderr.strip()))
    return json.loads(done.stdout)


def section(config, name):
    value = config.get(name) if isinstance(config, dict) else None
    return value if isinstance(value, dict) else {}


def render_date(fmt, today):
    parts = fmt.split("-")
    if not parts or any(p not in TOKENS for p in parts):
        raise Refusal("branchNaming.dateFormat %r uses a token other than YYYY, YY, MM and DD" % fmt)
    return "-".join(today.strftime(TOKENS[p]) for p in parts)


def answer(request):
    config = request.get("config") or {}
    if not isinstance(config, dict):
        raise Refusal("config must be an object")
    try:
        today = datetime.date.fromisoformat(request.get("today") or "")
    except (TypeError, ValueError):
        raise Refusal("today must be an ISO date")
    words = (request.get("userName") or "").strip().split()
    if not words:
        raise Refusal("git config user.name is empty; set it, it names your branches")
    if not re.match(r"^[A-Za-z0-9-]+$", words[0]):
        raise Refusal("the first word of the user name %r cannot be a branch prefix; ask for one" % words[0])
    prefix = routing("prefix", {"userName": words[0]})["prefix"]
    argument = (request.get("branchArgument") or "").strip()
    # A branch argument that already carries the infix keeps only its last segment as the slug.
    if "/hotfix/" in "/" + argument:
        argument = argument.rstrip("/").split("/")[-1]
    if not argument:
        raise Refusal("no branch name was given; ask for one")
    slug = routing("slug", {"title": argument, "words": 8})["slug"]
    date = render_date(section(config, "branchNaming").get("dateFormat") or DEFAULT_FORMAT, today)
    branch = "%s/hotfix/%s/%s" % (prefix, date, slug)
    if subprocess.run(["git", "check-ref-format", "--branch", branch], capture_output=True).returncode != 0:
        raise Refusal("%s is not a valid branch name" % branch)
    hotfix_pattern = section(config, "releaseTower").get("hotfixPattern") or DEFAULT_HOTFIX_PATTERN
    matched = routing("match", {"name": branch, "patterns": [hotfix_pattern]})
    if not matched["matches"]:
        raise Refusal("%s does not match the hotfix pattern %s, so it would not be recognised as a hotfix" % (branch, hotfix_pattern))
    release_patterns = section(config, "release").get("releaseBranchPattern")
    if isinstance(release_patterns, str):
        release_patterns = [release_patterns]
    if release_patterns and routing("match", {"name": branch, "patterns": release_patterns})["matches"]:
        raise Refusal("%s matches the release branch pattern; a hotfix is never a release branch" % branch)
    return {"branch": branch, "prefix": prefix, "date": date, "slug": slug,
            "matches": True, "pattern": matched["pattern"]}


def main():
    try:
        request = json.load(sys.stdin)
        if not isinstance(request, dict):
            raise Refusal("stdin must be one JSON object")
        out = answer(request)
    except Refusal as refusal:
        sys.stderr.write("hotfix-name: %s\n" % refusal)
        return 2
    except ValueError as error:
        sys.stderr.write("hotfix-name: stdin is not JSON (%s)\n" % error)
        return 2
    except Exception as error:  # noqa: BLE001 — one line, exit 1, never a traceback
        sys.stderr.write("hotfix-name: %s\n" % error)
        return 1
    sys.stdout.write(json.dumps(out, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
