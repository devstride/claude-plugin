#!/usr/bin/env python3
"""Has this pull request head had its independent review? Starts it if not, and waits for the answer.

`review.independentReview` names a workflow that runs from the production branch and posts its
result under an identity the builder cannot use. This script only starts it and reads the result;
it can never produce a pass itself.

  independent-review.py <pr-number> <head-sha (40 hex)> [--repo <owner>/<name>] [--config <path>]

  OFF      review.independentReview is not set: nothing to do                        exit 0
  PASS <head> <title>                                                                exit 0
  WITHHELD <head> <title>, then the findings as text                                 exit 2
  ERROR <reason>   no result: the reviewer did not answer, so nothing is known       exit 1

A result already recorded on this exact commit is the answer: a pass is not bought twice, and a
withheld result stands until a new commit exists. Only the configured reviewer App's result counts,
and a pass only when its record names this pull request, this head and the base it targets now.
"""
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from urllib.parse import quote

SHA = re.compile(r"^[0-9a-f]{40}$")
REPO = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
PR = re.compile(r"^[1-9][0-9]*$")
POLL_SECONDS = float(os.environ.get("INDEPENDENT_REVIEW_POLL_SECONDS", "20"))
# A run listing lags the dispatch: no run yet is not "the run ended without an answer".
GRACE_SECONDS = float(os.environ.get("INDEPENDENT_REVIEW_GRACE_SECONDS", "60"))
MAX_READ_FAILURES = 5


class Stop(Exception):
    pass


def gh(*args):
    done = subprocess.run(("gh",) + args, capture_output=True, text=True)
    if done.returncode != 0:
        raise Stop("gh %s failed: %s" % (" ".join(args[:3]), (done.stderr or done.stdout).strip()[:300]))
    return done.stdout


def gh_json(*args):
    try:
        return json.loads(gh(*args))
    except ValueError:
        raise Stop("gh %s did not answer JSON" % " ".join(args[:3]))


def load(path):
    try:
        with open(path) as handle:
            section = (json.load(handle).get("review") or {}).get("independentReview")
    except FileNotFoundError:
        return None
    except ValueError:
        raise Stop("%s is not JSON" % path)
    if section is None:
        return None
    if not isinstance(section, dict) or any(
        not isinstance(section.get(key), str) or not section[key] for key in ("workflow", "ref", "check", "reviewerApp")
    ):
        raise Stop("review.independentReview needs workflow, ref, check and reviewerApp")
    return section


def names(run, pr, head, base):
    """Does a pass's record name this pull request, this head and the base it targets now?"""
    try:
        record = json.loads((run.get("output") or {}).get("text") or "")
    except ValueError:
        return False
    return isinstance(record, dict) and record.get("head") == head and str(record.get("pr")) == str(pr) \
        and record.get("base_ref") == base


def result_on(repo, pr, head, base, config):
    """The reviewer App's newest finished result on this commit, or None. A pass recorded for
    another pull request or another base is no result here: that review read a different change."""
    out = gh_json("api", "repos/%s/commits/%s/check-runs?check_name=%s&filter=all&per_page=100"
                  % (repo, head, quote(config["check"], safe="")))
    own = [r for r in out.get("check_runs") or [] if (r.get("app") or {}).get("slug") == config["reviewerApp"] and r.get("name") == config["check"]]
    own.sort(key=lambda r: r.get("id") or 0, reverse=True)
    if not own or own[0].get("status") != "completed":
        return None
    if own[0].get("conclusion") == "success" and not names(own[0], pr, head, base):
        return None
    return own[0]


def report(head, run):
    output = run.get("output") or {}
    if run.get("conclusion") == "success":
        print("PASS %s %s" % (head, output.get("title") or ""))
        return 0
    print("WITHHELD %s %s" % (head, output.get("title") or run.get("conclusion")))
    print(output.get("text") or "")
    return 2


def runs_since(repo, config, started):
    out = gh_json("api", "repos/%s/actions/workflows/%s/runs?event=workflow_dispatch&per_page=20" % (repo, config["workflow"]))
    fresh = []
    for run in out.get("workflow_runs") or []:
        created = datetime.strptime(run["created_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
        if created >= started - 5:
            fresh.append(run)
    return fresh


def review(pr, head, repo, config):
    base = gh_json("pr", "view", pr, "--repo", repo, "--json", "baseRefName").get("baseRefName")
    if not isinstance(base, str) or not base:
        raise Stop("the base of #%s could not be read" % pr)
    existing = result_on(repo, pr, head, base, config)
    if existing:
        return report(head, existing)
    started = time.time()
    gh("workflow", "run", config["workflow"], "--repo", repo, "--ref", config["ref"], "-f", "pr_number=%s" % pr)
    deadline = started + 60 * float(config.get("timeoutMinutes") or 45)
    misses = 0
    while time.time() < deadline:
        time.sleep(POLL_SECONDS)
        # One failed read is GitHub having a moment, not the end of a review that is still running.
        try:
            found = result_on(repo, pr, head, base, config)
            fresh = None if found else runs_since(repo, config, started)
            misses = 0
        except Stop:
            misses += 1
            if misses >= MAX_READ_FAILURES:
                raise
            continue
        if found:
            return report(head, found)
        if time.time() - started > GRACE_SECONDS and fresh and all(r.get("status") == "completed" for r in fresh):
            # One last look: the result is posted before the run ends, so this is not a race.
            found = result_on(repo, pr, head, base, config)
            if found:
                return report(head, found)
            raise Stop("the review run ended with no result for %s: %s" % (head[:12], fresh[0].get("html_url")))
    raise Stop("no result for %s after %s minutes" % (head[:12], config.get("timeoutMinutes") or 45))


def main(argv):
    args, repo, path = [], None, ".claude/ds-config.json"
    it = iter(argv[1:])
    for a in it:
        if a == "--repo":
            repo = next(it, None)
        elif a == "--config":
            path = next(it, None)
        else:
            args.append(a)
    if len(args) != 2 or not PR.match(args[0]) or not SHA.match(args[1]) or (repo is not None and not REPO.match(repo)):
        raise Stop("usage: independent-review.py <pr-number> <head-sha (40 hex)> [--repo <owner>/<name>] [--config <path>]")
    config = load(path)
    if config is None:
        print("OFF")
        return 0
    repo = repo or gh("repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner").strip()
    return review(args[0], args[1], repo, config)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Stop as stop:
        print("ERROR %s" % stop)
        sys.exit(1)
