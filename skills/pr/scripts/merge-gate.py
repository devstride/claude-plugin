#!/usr/bin/env python3
"""May this pull request merge now, and with which command? The one gate before every merge.

Every place the plugin merges (`release`, `build-item`, a departure's merge) runs this file and
then runs exactly the command it prints, never its own `gh pr merge`. It reads GitHub only.

  merge-gate.py <pr-number> <expected-head-sha> [--delete-branch] [--subject <text>] [--repo <owner>/<name>]

  MERGE gh pr merge <n> --repo <owner>/<name> --merge --match-head-commit <sha> [--admin]
        [--delete-branch] [--subject '<text>']   exit 0: the repository it inspected is named, and
        the subject is shell-quoted, so the line runs as printed from any directory
        then one line naming the required checks that are green at <sha>
  REFUSE <reason>                                                                        exit 2
  ERROR <reason>   GitHub could not be read: nothing is known, so nothing merges          exit 1

The rule (an approver's admin merge exactly when every required check is green, never otherwise):
- Only through a pull request: the number must name an OPEN, non-draft pull request.
- Pinned to the head: the pull request's head must be the expected SHA, and the command carries
  `--match-head-commit <sha>`, so GitHub refuses it if the head moves in between.
- Every required check green there: the required checks are the union of the base branch's
  rulesets (`rules/branches/<base>`), its classic protection (`protection/required_status_checks`;
  unreadable is a REFUSE, because a required check that never ran would then go unseen) and every
  check GitHub marks required on this pull request, each with the app it must come from when the
  rule names one (`integration_id`, `app_id`). A check is one (name, app, workflow) or one commit
  status: a re-run of the same check supersedes the run before it, but a same-name check from
  another workflow or app, or a same-name commit status, is another check and must pass too. Every
  check that can satisfy a requirement must have completed with SUCCESS at the expected head.
  Pending, failed, cancelled, skipped, neutral or missing is a REFUSE naming it.
- No open conversation: a CHANGES_REQUESTED decision or any unresolved review thread is a REFUSE.
- `--admin` only when GitHub reads the pull request BLOCKED with all of the above true and at least
  one required check: the base's rules let only an admin's merge through. CLEAN, HAS_HOOKS or
  UNSTABLE (a failing check that is not required) merges without it. DIRTY, BEHIND, UNKNOWN and
  any other state is a REFUSE: an admin merge never bypasses a conflict, an out-of-date branch or
  a state GitHub has not finished computing.
"""
import json
import re
import shlex
import subprocess
import sys
from urllib.parse import quote

SHA = re.compile(r"^[0-9a-f]{40}$")
REPO = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
GREEN = "SUCCESS"
PLAIN = ("CLEAN", "HAS_HOOKS", "UNSTABLE")

PR_QUERY = """query($owner: String!, $name: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      number state isDraft headRefOid baseRefName mergeStateStatus reviewDecision
      commits(last: 1) { nodes { commit { oid statusCheckRollup {
        contexts(first: 100, after: $after) {
          pageInfo { hasNextPage endCursor }
          nodes {
            __typename
            ... on CheckRun { name status conclusion startedAt completedAt databaseId isRequired(pullRequestNumber: $number)
                              checkSuite { app { databaseId } workflowRun { workflow { databaseId } } } }
            ... on StatusContext { context state createdAt isRequired(pullRequestNumber: $number) }
          }
        }
      } } } }
    }
  }
}"""

THREADS_QUERY = """query($owner: String!, $name: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { isResolved } }
    }
  }
}"""


class Refuse(Exception):
    pass


class Unreadable(Exception):
    pass


def gh(*args):
    try:
        done = subprocess.run(["gh"] + list(args), capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as err:
        raise Unreadable("gh could not run: %s" % err)
    return done.returncode, done.stdout, done.stderr


def gh_json(*args):
    code, out, err = gh(*args)
    if code != 0:
        raise Unreadable("gh %s failed: %s" % (" ".join(args[:2]), (err or out).strip()[:200]))
    try:
        return json.loads(out)
    except ValueError:
        raise Unreadable("gh %s returned something that is not JSON" % " ".join(args[:2]))


def graphql(query, owner, name, number, after, missing_pr_ok=False):
    args = ["api", "graphql", "-f", "query=" + query, "-f", "owner=" + owner, "-f", "name=" + name,
            "-F", "number=%d" % number]
    if after:
        args += ["-f", "after=" + after]
    code, out, err = gh(*args)
    try:
        data = json.loads(out)
    except ValueError:
        raise Unreadable("gh api graphql failed: %s" % (err or out).strip()[:200])
    if not isinstance(data, dict):
        raise Unreadable("the GraphQL answer is not an object")
    errors = data.get("errors")
    repo = (data.get("data") or {}).get("repository") if isinstance(data.get("data"), dict) else None
    if errors:
        # The one tolerated error: the number names no pull request ("Could not resolve to a
        # PullRequest"), with the repository read and the pull request null. Anything else,
        # partial data included, is unreadable.
        missing = (missing_pr_ok and isinstance(repo, dict) and repo.get("pullRequest") is None
                   and all(isinstance(e, dict) and e.get("type") == "NOT_FOUND"
                           and e.get("path") == ["repository", "pullRequest"] for e in errors))
        if not missing:
            raise Unreadable("the GraphQL answer carried errors: %s" % json.dumps(errors)[:200])
    elif code != 0:
        raise Unreadable("gh api graphql failed: %s" % (err or out).strip()[:200])
    if not isinstance(repo, dict):
        raise Unreadable("the GraphQL answer has no repository %s/%s" % (owner, name))
    return repo


def pull_request(owner, name, number):
    after, contexts, pr = None, [], None
    while True:
        repo = graphql(PR_QUERY, owner, name, number, after, missing_pr_ok=after is None)
        page = repo.get("pullRequest")
        if page is None:
            raise Refuse("#%d is not a pull request in %s/%s: merges go only through a pull request" % (number, owner, name))
        pr = pr or page
        nodes = (page.get("commits") or {}).get("nodes") or []
        commit = nodes[0]["commit"] if nodes else {}
        if after is None:
            pr["_oid"] = commit.get("oid")
        elif commit.get("oid") != pr["_oid"]:
            raise Unreadable("the head moved while its checks were being read: ask again")
        rollup = (commit.get("statusCheckRollup") or {}).get("contexts") or {"nodes": [], "pageInfo": {}}
        contexts += rollup.get("nodes") or []
        info = rollup.get("pageInfo") or {}
        if not info.get("hasNextPage"):
            break
        after = info.get("endCursor")
    pr["_contexts"] = contexts
    return pr


def unresolved_threads(owner, name, number):
    after, count = None, 0
    while True:
        repo = graphql(THREADS_QUERY, owner, name, number, after)
        threads = (repo.get("pullRequest") or {}).get("reviewThreads")
        if not isinstance(threads, dict) or not isinstance(threads.get("nodes"), list):
            raise Unreadable("the review threads of #%d could not be read" % number)
        count += sum(1 for t in threads.get("nodes") or [] if not t.get("isResolved"))
        info = threads.get("pageInfo") or {}
        if not info.get("hasNextPage"):
            return count
        after = info.get("endCursor")


def app_of(value):
    """A rule's app restriction: an app id, or None for any source (absent, null or negative)."""
    return value if isinstance(value, int) and not isinstance(value, bool) and value > 0 else None


def ruleset_checks(owner, name, base):
    required, page = set(), 1
    while True:
        rules = gh_json("api", "repos/%s/%s/rules/branches/%s?per_page=100&page=%d" % (owner, name, quote(base, safe=""), page))
        if not isinstance(rules, list):
            raise Unreadable("the rules of %s did not come back as a list" % base)
        for rule in rules:
            if isinstance(rule, dict) and rule.get("type") == "required_status_checks":
                for check in (rule.get("parameters") or {}).get("required_status_checks") or []:
                    if isinstance(check, dict) and check.get("context"):
                        required.add((check["context"], app_of(check.get("integration_id"))))
        if len(rules) < 100:
            return required
        page += 1


def protection_checks(owner, name, base):
    code, out, err = gh("api", "repos/%s/%s/branches/%s/protection/required_status_checks" % (owner, name, quote(base, safe="")))
    if code != 0:
        said = (err or "") + (out or "")
        if "HTTP 404" in said:
            return set()      # no classic protection, or none requiring checks
        if "HTTP 403" in said:
            raise Refuse("the classic branch protection of %s cannot be read with this login, so a required check "
                         "that never ran would go unseen: merge as an admin of the repository" % base)
        raise Unreadable("reading the branch protection of %s failed: %s" % (base, said.strip()[:200]))
    try:
        data = json.loads(out)
    except ValueError:
        raise Unreadable("the branch protection of %s is not JSON" % base)
    if not isinstance(data, dict) or not isinstance(data.get("contexts"), list):
        raise Unreadable("the branch protection of %s is not a required-status-checks answer" % base)
    required = {(c, None) for c in data["contexts"] if isinstance(c, str) and c}
    for c in data.get("checks") or []:
        if isinstance(c, dict) and c.get("context"):
            required.discard((c["context"], None))
            required.add((c["context"], app_of(c.get("app_id"))))
    return required


def runs_at_head(contexts):
    """Every distinct check at this head with its newest run. A check run is one (name, app,
    workflow): a re-run of it supersedes the run before (ids rise with creation, and a queued
    re-run has no start time yet). A commit status is one context. Same-name checks from another
    workflow or app, and a same-name status, stay separate: each must pass."""
    best = {}
    for c in contexts:
        if not isinstance(c, dict):
            continue
        if c.get("__typename") == "CheckRun":
            suite = c.get("checkSuite") or {}
            app = (suite.get("app") or {}).get("databaseId")
            workflow = ((suite.get("workflowRun") or {}).get("workflow") or {}).get("databaseId")
            key, order = ("check", c.get("name"), app, workflow), (c.get("databaseId") or 0, "")
            state = c.get("conclusion") if c.get("status") == "COMPLETED" else "PENDING"
        elif c.get("__typename") == "StatusContext":
            key, order = ("status", c.get("context"), None, None), (0, c.get("createdAt") or "")
            state = {"PENDING": "PENDING", "EXPECTED": "PENDING"}.get(c.get("state"), c.get("state"))
        else:
            continue
        if not key[1]:
            continue
        if key not in best or order > best[key][0]:
            best[key] = (order, state or "PENDING", bool(c.get("isRequired")))
    return best


def problems_with(required, runs):
    problems = []
    for check, app in sorted(required, key=lambda r: (r[0], r[1] or 0)):
        source = " from app %d" % app if app else ""
        matching = [(k, v) for k, v in runs.items() if k[1] == check and (app is None or (k[0] == "check" and k[2] == app))]
        if not matching:
            problems.append("%s%s never ran at this head" % (check, source))
            continue
        for key, (_, state, _) in sorted(matching, key=lambda kv: (kv[0][0], kv[0][2] or 0, kv[0][3] or 0)):
            if state != GREEN:
                kind = "" if len(matching) == 1 else (" (commit status)" if key[0] == "status" else " (app %s, workflow %s)" % (key[2], key[3]))
                problems.append("%s%s is %s" % (check, kind, str(state).lower()))
    return problems


def decide(number, expected, owner, name, delete_branch, subject=None):
    pr = pull_request(owner, name, number)
    if pr.get("state") != "OPEN":
        raise Refuse("#%d is %s, not open" % (number, str(pr.get("state")).lower()))
    if pr.get("isDraft"):
        raise Refuse("#%d is a draft: CI has not run on its final head" % number)
    head = pr.get("headRefOid")
    if head != expected or pr.get("_oid") != expected:
        raise Refuse("the head moved: expected %s, #%d is at %s; review and check the new head first"
                     % (expected[:12], number, (head or "?")[:12]))
    state = pr.get("mergeStateStatus")
    if state == "DIRTY":
        raise Refuse("#%d has conflicts with %s" % (number, pr.get("baseRefName")))
    if state == "BEHIND":
        raise Refuse("#%d is behind %s, which requires it to be up to date: update it, then check the new head" % (number, pr.get("baseRefName")))
    if state not in PLAIN and state != "BLOCKED":
        raise Refuse("GitHub reads #%d as %s: ask again once it has finished computing" % (number, state))
    if pr.get("reviewDecision") == "CHANGES_REQUESTED":
        raise Refuse("#%d has a review requesting changes" % number)
    open_threads = unresolved_threads(owner, name, number)
    if open_threads:
        raise Refuse("#%d has %d unresolved review thread(s): resolve them first" % (number, open_threads))
    base = pr.get("baseRefName")
    if not isinstance(base, str) or not base:
        raise Unreadable("#%d names no base branch" % number)
    runs = runs_at_head(pr["_contexts"])
    required = ruleset_checks(owner, name, base) | protection_checks(owner, name, base)
    required |= {(k[1], None) for k, (_, _, req) in runs.items() if req}
    problems = problems_with(required, runs)
    if problems:
        raise Refuse("not every required check is green at %s: %s" % (expected[:12], "; ".join(problems)))
    admin = state == "BLOCKED"
    if admin and not required:
        raise Refuse("#%d is blocked and %s requires no check, so nothing proves this head green: "
                     "an admin merge would bypass a block it cannot name" % (number, base))
    command = "gh pr merge %d --repo %s/%s --merge --match-head-commit %s%s%s%s" % (
        number, owner, name, expected, " --admin" if admin else "", " --delete-branch" if delete_branch else "",
        " --subject " + shlex.quote(subject) if subject else "")
    why = ("required checks green at %s: %s" % (expected[:12], ", ".join(sorted({r[0] for r in required})))) if required \
        else "%s requires no check; GitHub reads #%d as %s" % (base, number, state)
    return command, why


def main(argv):
    args, delete_branch, repo, subject = [], False, None, None
    it = iter(argv[1:])
    for a in it:
        if a == "--delete-branch":
            delete_branch = True
        elif a == "--repo":
            repo = next(it, None)
        elif a == "--subject":
            subject = next(it, "")
            if not subject.strip() or "\n" in subject:
                sys.stderr.write("usage: --subject takes one non-empty line\n")
                return 2
        else:
            args.append(a)
    if len(args) != 2 or not args[0].isdigit() or int(args[0]) < 1 or not SHA.match(args[1]) \
            or (repo is not None and not REPO.match(repo)):
        sys.stderr.write("usage: merge-gate.py <pr-number> <expected-head-sha (40 hex)> [--delete-branch] [--subject <text>] [--repo <owner>/<name>]\n")
        return 2
    number, expected = int(args[0]), args[1]
    try:
        if repo is None:
            code, out, err = gh("repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner")
            repo = out.strip()
            if code != 0 or not REPO.match(repo):
                raise Unreadable("the repository could not be resolved: %s" % (err or out).strip()[:200])
        owner, name = repo.split("/")
        command, why = decide(number, expected, owner, name, delete_branch, subject)
    except Refuse as err:
        print("REFUSE %s" % str(err).replace("\n", " "))
        return 2
    except Unreadable as err:
        print("ERROR %s" % str(err).replace("\n", " "))
        return 1
    print("MERGE %s" % command)
    print(why)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as err:  # never a traceback, never a merge
        print("ERROR internal error: %s" % err)
        sys.exit(1)
