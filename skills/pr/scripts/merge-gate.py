#!/usr/bin/env python3
"""May this pull request merge now, and with which command? The one gate before every merge.

Every place the plugin merges (`release`, `build-item`, a departure's merge) runs this file and
then runs exactly the command it prints, never its own `gh pr merge`. It reads GitHub only.

  merge-gate.py <pr-number> <expected-head-sha> [--all-green] [--delete-branch] [--subject <text>]
                [--repo <owner>/<name>]

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
  check that can satisfy a requirement must have passed at the expected head. Passed is GitHub's
  own reading: SUCCESS, or SKIPPED or NEUTRAL (a workflow that skips a job when nothing needed
  it, which GitHub counts as passing), but a quiet required check passes only with evidence that
  CI ran: another job of its own workflow run succeeded, or an older run of that check succeeded.
  A run where every job skipped (a draft's held CI, still the newest just after the ready flip)
  proves nothing and is a REFUSE. `--all-green` reads a check that is not required as GitHub does:
  a workflow that only ever skips (one answering @-mentions, a matrix job's skipped placeholder
  name) is never asked to have run. A workflow run from an event GitHub does not count toward a pull
  request's checks (`workflow_dispatch`, `schedule`, ...) is ignored, as GitHub ignores it. A
  check's runs are judged per trigger event (push, pull_request, ...), and no event's verdict may
  be failing or pending, so a later push run never hides a failed pull_request run. Within one
  event any run still pending refuses, and the newest run is read both by run number and by when
  its latest attempt started (a re-run keeps its number but starts later); the worse counts.
  Same-name jobs in one run are siblings, and every one must pass. A skipped or neutral newest run never hides
  an older run of the same check that executed and is failing or still pending. Pending, failed,
  cancelled, timed out or missing is a REFUSE naming it. A required check that also ran on the
  pull request's test merge commit must pass there too (GitHub requires it). A commit status
  cannot show which app sent it, so a rule bound to an app is met only by that app's check run.
  `--all-green` holds every check at the head to the same rule, not only the required ones
  (`release` uses it for production).
- When the merge would need `--admin`, the classic protection rule that applies (read through
  GraphQL, which resolves its pattern) must require nothing the gate cannot prove: deployments,
  signed commits, linear history or a locked branch refuse, and so do required reviews, code
  owners or last-push approval without an APPROVED decision.
- The test merge commit going null or changing mid-read is a fresh read, never "no checks there".
- Classic protection answering 404 means none only with GitHub's two messages for it ("Branch
  not protected", "Required status checks not enabled"); any other 404 is an ERROR.
- A base that requires branches to be up to date (a ruleset's strict policy, or classic `strict`)
  is checked with the compare API: a head behind its base is a REFUSE, so `--admin` never merges
  an out-of-date head even when GitHub reads the pull request BLOCKED rather than BEHIND.
- No bypassed approval: when the merge would need `--admin`, a REVIEW_REQUIRED decision or an
  unmet approval requirement of the base's pull_request rule (approving count, code owners, last
  push, required reviewers) is a REFUSE: `--admin` would skip the approval. Any other setting of
  that rule (for example `require_extra_approval_for_unattributed_changes`) is judged only through
  GitHub's REVIEW_REQUIRED decision.
- No open conversation: a CHANGES_REQUESTED decision, any reviewer whose latest review requests
  changes (even when reviews are not required and the decision is empty), or any unresolved
  review thread is a REFUSE.
- `--admin` only when GitHub reads the pull request BLOCKED with all of the above true, at least
  one required check, and no rule on the base this gate cannot judge (KNOWN_RULES; a
  `workflows`, `code_scanning`, `required_deployments`, `merge_queue`, `required_signatures` or other rule would be
  bypassed silently, so it refuses): the base's rules let only an admin's merge through. CLEAN, HAS_HOOKS or
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
PASSED = ("SUCCESS", "SKIPPED", "NEUTRAL")
QUIET = ("SKIPPED", "NEUTRAL")
# The workflow events whose job checks GitHub counts toward a pull request's checks; a run from any
# other (workflow_dispatch, schedule, ...) never satisfies a required check, so it is ignored here.
ELIGIBLE = ("push", "pull_request", "pull_request_review", "pull_request_target", "deployment",
            "deployment_status", "merge_group")
UNEARNED = "skipped in a run where nothing ran"
NO_PROTECTION = ("Branch not protected", "Required status checks not enabled")
# Rule types an admin merge may pass knowing what it bypasses: required checks are judged here;
# reviews by the open-thread and change-request checks; the rest guard pushes, not merges.
KNOWN_RULES = ("required_status_checks", "pull_request", "copilot_code_review", "update", "deletion",
               "non_fast_forward", "creation")
# A pull_request rule's approval requirements: an admin merge would bypass any of these unmet.
APPROVALS = ("required_approving_review_count", "require_code_owner_review", "require_last_push_approval",
             "required_reviewers")
PLAIN = ("CLEAN", "HAS_HOOKS", "UNSTABLE")

PR_QUERY = """query($owner: String!, $name: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      number state isDraft headRefOid baseRefName mergeStateStatus reviewDecision
      latestOpinionatedReviews(first: 100) { pageInfo { hasNextPage } nodes { state author { login } } }
      potentialMergeCommit { oid }
      commits(last: 1) { nodes { commit { oid statusCheckRollup {
        contexts(first: 100, after: $after) {
          pageInfo { hasNextPage endCursor }
          nodes {
            __typename
            ... on CheckRun { name status conclusion startedAt completedAt databaseId isRequired(pullRequestNumber: $number)
                              checkSuite { app { databaseId } workflowRun { runNumber event workflow { databaseId } } } }
            ... on StatusContext { context state createdAt isRequired(pullRequestNumber: $number) }
          }
        }
      } } } }
    }
  }
}"""

MERGE_COMMIT_QUERY = """query($owner: String!, $name: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      potentialMergeCommit { oid statusCheckRollup {
        contexts(first: 100, after: $after) {
          pageInfo { hasNextPage endCursor }
          nodes {
            __typename
            ... on CheckRun { name status conclusion startedAt completedAt databaseId
                              checkSuite { app { databaseId } workflowRun { runNumber event workflow { databaseId } } } }
            ... on StatusContext { context state }
          }
        }
      } }
    }
  }
}"""

CLASSIC_QUERY = """query($owner: String!, $name: String!, $ref: String!) {
  repository(owner: $owner, name: $name) {
    ref(qualifiedName: $ref) { branchProtectionRule {
      pattern requiresDeployments requiresCommitSignatures requiresLinearHistory lockBranch
      requiresApprovingReviews requiresCodeOwnerReviews requireLastPushApproval
    } }
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


class Retry(Exception):
    """The base or head moved while the gate was reading: one fresh read, then a REFUSE."""


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
            raise Retry("the head moved while its checks were being read")
        rollup = (commit.get("statusCheckRollup") or {}).get("contexts") or {"nodes": [], "pageInfo": {}}
        contexts += rollup.get("nodes") or []
        info = rollup.get("pageInfo") or {}
        if not info.get("hasNextPage"):
            break
        after = info.get("endCursor")
    pr["_contexts"] = contexts
    return pr


def merge_commit_contexts(owner, name, number, oid):
    """The check contexts on the pull request's test merge commit, all pages; none when there is none."""
    after, contexts = None, []
    while True:
        repo = graphql(MERGE_COMMIT_QUERY, owner, name, number, after)
        commit = (repo.get("pullRequest") or {}).get("potentialMergeCommit")
        if not commit or commit.get("oid") != oid:   # null while GitHub regenerates it: never "no checks"
            raise Retry("the base moved while the test merge commit's checks were being read")
        rollup = (commit.get("statusCheckRollup") or {}).get("contexts") or {"nodes": [], "pageInfo": {}}
        contexts += rollup.get("nodes") or []
        info = rollup.get("pageInfo") or {}
        if not info.get("hasNextPage"):
            return contexts
        after = info.get("endCursor")


def classic_rule(owner, name, base):
    """The classic protection rule that applies to the base (GitHub resolves the pattern), or None."""
    data = gh_json("api", "graphql", "-f", "query=" + CLASSIC_QUERY, "-f", "owner=" + owner, "-f", "name=" + name,
                   "-f", "ref=refs/heads/" + base)
    repo = (data.get("data") or {}).get("repository") if isinstance(data, dict) else None
    if not isinstance(data, dict) or data.get("errors") or not isinstance(repo, dict) or not isinstance(repo.get("ref"), dict):
        raise Unreadable("the classic protection of %s could not be read" % base)
    return repo["ref"].get("branchProtectionRule")


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
    """The base's ruleset requirements: (required checks with their apps, strict?, rule types)."""
    required, strict, types, page = set(), False, set(), 1
    approvals = []
    while True:
        rules = gh_json("api", "repos/%s/%s/rules/branches/%s?per_page=100&page=%d" % (owner, name, quote(base, safe=""), page))
        if not isinstance(rules, list):
            raise Unreadable("the rules of %s did not come back as a list" % base)
        for rule in rules:
            if not isinstance(rule, dict):
                continue
            types.add(rule.get("type"))
            if rule.get("type") == "pull_request":
                params = rule.get("parameters") or {}
                approvals += [k for k in APPROVALS if params.get(k) not in (None, False, 0, [])]
            if rule.get("type") == "required_status_checks":
                params = rule.get("parameters") or {}
                strict = strict or params.get("strict_required_status_checks_policy") is True
                for check in params.get("required_status_checks") or []:
                    if isinstance(check, dict) and check.get("context"):
                        required.add((check["context"], app_of(check.get("integration_id"))))
        if len(rules) < 100:
            return required, strict, types, approvals
        page += 1


def protection_checks(owner, name, base):
    code, out, err = gh("api", "repos/%s/%s/branches/%s/protection/required_status_checks" % (owner, name, quote(base, safe="")))
    if code != 0:
        said = (err or "") + (out or "")
        if "HTTP 404" in said:
            try:
                message = json.loads(out).get("message")
            except (ValueError, AttributeError):
                message = None
            if message in NO_PROTECTION:
                return set(), False
            raise Unreadable("reading the branch protection of %s answered 404 %r, not one of GitHub's "
                             "no-protection answers" % (base, message))
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
    return required, data.get("strict") is True


def worst(states):
    """One workflow run's verdict for a check from its sibling jobs: a failure, else pending, else
    success, else skipped or neutral."""
    for state in states:
        if state not in PASSED and state != "PENDING":
            return state
    if "PENDING" in states:
        return "PENDING"
    return "SUCCESS" if "SUCCESS" in states else states[0]


def stream_verdict(byRun, at):
    """One event's runs of one check: (verdict, earned). Any run still pending is PENDING. The
    newest run is read two ways, by run number and by when its latest attempt started (a re-run
    keeps its old number but starts later), and the worse of the two counts. A quiet newest run
    defers to the newest run that executed; none executed leaves it quiet and unearned."""
    numbers = sorted(byRun)
    verdict = {n: worst(byRun[n]) for n in numbers}
    if "PENDING" in verdict.values():
        return "PENDING", False
    def newest(ns):
        return [verdict[n] for n in {ns[-1], max(ns, key=lambda n: (at.get(n) or "", n))}]
    picked = newest(numbers)
    red = [v for v in picked if v not in PASSED]
    if red:
        return red[0], True
    if "SUCCESS" in picked:
        return "SUCCESS", True
    executed = [n for n in numbers if verdict[n] not in QUIET]
    if executed:
        red = [v for v in newest(executed) if v != "SUCCESS"]
        return (red[0], True) if red else (picked[0], True)
    return picked[0], False


def runs_at_head(contexts):
    """Every distinct check at this head and its verdict. A check run belongs to one (name, app,
    workflow), and a commit status is one context (GitHub reports only its latest state). Same-name
    checks from another workflow or app, and a same-name status, stay separate: each must pass. A
    check run from a workflow event GitHub does not count (ELIGIBLE) is left out: it neither
    satisfies a check nor stands in front of an older one. Each counted event (push,
    pull_request, ...) is its own stream, judged by stream_verdict, and no stream may be failing or
    pending: a later push run never hides a failed pull_request run. Same-name jobs in one run are
    siblings that must all pass. A skipped or neutral verdict is earned when a stream executed, or
    when another job of that same workflow run succeeded (a job skipped because its run found
    nothing to test); a check where nothing ever ran (a draft's held CI, read before the ready run
    starts) or a quiet check from outside a workflow is UNEARNED."""
    runs, ran = {}, set()
    for c in contexts:
        if not isinstance(c, dict):
            continue
        if c.get("__typename") == "CheckRun":
            suite = c.get("checkSuite") or {}
            app = (suite.get("app") or {}).get("databaseId")
            run = suite.get("workflowRun") or {}
            if run and run.get("event") not in ELIGIBLE:
                continue
            workflow = (run.get("workflow") or {}).get("databaseId")
            key, number = ("check", c.get("name"), app, workflow), run.get("runNumber") or 0
            stream, when = run.get("event"), c.get("startedAt") or c.get("completedAt")
            state = c.get("conclusion") if c.get("status") == "COMPLETED" else "PENDING"
            if workflow and state == "SUCCESS":
                ran.add((app, workflow, number))
        elif c.get("__typename") == "StatusContext":
            key, number, stream, when = ("status", c.get("context"), None, None), 0, None, None
            state = {"PENDING": "PENDING", "EXPECTED": "PENDING"}.get(c.get("state"), c.get("state"))
        else:
            continue
        if key[1]:
            entry = runs.setdefault(key, {"required": False, "streams": {}})
            entry["required"] = entry["required"] or bool(c.get("isRequired"))
            byRun, at = entry["streams"].setdefault(stream, ({}, {}))
            byRun.setdefault(number, []).append(state or "PENDING")
            if when and when > (at.get(number) or ""):
                at[number] = when
    verdicts = {}
    for key, entry in runs.items():
        judged = {e: stream_verdict(*pair) for e, pair in entry["streams"].items()}
        red = [v for v, _ in judged.values() if v not in PASSED]
        if red:
            state = next((v for v in red if v != "PENDING"), "PENDING")
        elif any(v == "SUCCESS" for v, _ in judged.values()):
            state = "SUCCESS"
        else:
            state = next(iter(judged.values()))[0]
            bare = not any(earned for _, earned in judged.values())
            newest = [max(pair[0]) for pair in entry["streams"].values()]
            if bare and not (key[3] and any((key[2], key[3], n) in ran for n in newest)):
                state = UNEARNED
        verdicts[key] = (state, entry["required"])
    return verdicts


def problems_with(required, runs):
    problems = []
    for check, app in sorted(required, key=lambda r: (r[0], r[1] or 0)):
        source = " from app %d" % app if app else ""
        matching = [(k, v) for k, v in runs.items() if k[1] == check and (app is None or (k[0] == "check" and k[2] == app))]
        if not matching:
            status_only = app and any(k[1] == check and k[0] == "status" for k in runs)
            problems.append("%s%s never ran at this head%s" % (check, source,
                            " (a commit status of that name cannot show which app sent it)" if status_only else ""))
            continue
        for key, (state, _) in sorted(matching, key=lambda kv: (kv[0][0], kv[0][2] or 0, kv[0][3] or 0)):
            if state not in PASSED:
                kind = "" if len(matching) == 1 else (" (commit status)" if key[0] == "status" else " (app %s, workflow %s)" % (key[2], key[3]))
                problems.append("%s%s is %s" % (check, kind, str(state).lower()))
    return problems


def decide(number, expected, owner, name, delete_branch, subject=None, all_green=False):
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
    opinions = pr.get("latestOpinionatedReviews")
    if not isinstance(opinions, dict) or not isinstance(opinions.get("nodes"), list) \
            or (opinions.get("pageInfo") or {}).get("hasNextPage"):
        raise Unreadable("the reviews of #%d could not be read in full" % number)
    asking = sorted(((r.get("author") or {}).get("login") or "a reviewer") for r in opinions["nodes"]
                    if isinstance(r, dict) and r.get("state") == "CHANGES_REQUESTED")
    if asking:
        raise Refuse("#%d: %s requested changes and has not approved since" % (number, ", ".join(asking)))
    open_threads = unresolved_threads(owner, name, number)
    if open_threads:
        raise Refuse("#%d has %d unresolved review thread(s): resolve them first" % (number, open_threads))
    base = pr.get("baseRefName")
    if not isinstance(base, str) or not base:
        raise Unreadable("#%d names no base branch" % number)
    runs = runs_at_head(pr["_contexts"])
    ruled, ruled_strict, types, approvals = ruleset_checks(owner, name, base)
    protected, protected_strict = protection_checks(owner, name, base)
    required = ruled | protected | {(k[1], None) for k, (_, req) in runs.items() if req}
    problems = problems_with(required, runs)
    if problems:
        raise Refuse("not every required check is green at %s: %s" % (expected[:12], "; ".join(problems)))
    merge_oid = (pr.get("potentialMergeCommit") or {}).get("oid")
    if merge_oid:
        on_merge = runs_at_head(merge_commit_contexts(owner, name, number, merge_oid))
        ran_there = {r for r in required if any(k[1] == r[0] for k in on_merge)}
        red = problems_with(ran_there, on_merge)   # a name there from the wrong app is a problem too
        if red:
            raise Refuse("a required check failed on the test merge commit %s, which GitHub holds above the head: %s"
                         % (merge_oid[:12], "; ".join(red)))
    if all_green:
        names = {r[0] for r in required}
        every = {k: (("SKIPPED" if s == UNEARNED and k[1] not in names else s), r) for k, (s, r) in runs.items()}
        red = problems_with({(k[1], None) for k in every}, every)
        if red:
            raise Refuse("--all-green: not every check is green at %s: %s" % (expected[:12], "; ".join(red)))
    if ruled_strict or protected_strict:
        compared = gh_json("api", "repos/%s/%s/compare/%s...%s" % (owner, name, quote(base, safe=""), expected))
        behind = compared.get("behind_by") if isinstance(compared, dict) else None
        if not isinstance(behind, int):
            raise Unreadable("comparing %s with %s gave no behind_by" % (expected[:12], base))
        if behind:
            raise Refuse("#%d is %d commit(s) behind %s, which requires it to be up to date: update it, then check the new head"
                         % (number, behind, base))
    admin = state == "BLOCKED"
    if admin and not required:
        raise Refuse("#%d is blocked and %s requires no check, so nothing proves this head green: "
                     "an admin merge would bypass a block it cannot name" % (number, base))
    if admin and (pr.get("reviewDecision") == "REVIEW_REQUIRED" or (approvals and pr.get("reviewDecision") != "APPROVED")):
        raise Refuse("#%d still needs an approving review (%s): an admin merge would bypass it"
                     % (number, ", ".join(sorted(set(approvals))) or "GitHub reads REVIEW_REQUIRED"))
    classic = classic_rule(owner, name, base) if admin else None
    if classic:
        cannot = [k for k in ("requiresDeployments", "requiresCommitSignatures", "requiresLinearHistory", "lockBranch") if classic.get(k)]
        if pr.get("reviewDecision") != "APPROVED":
            cannot += [k for k in ("requiresApprovingReviews", "requiresCodeOwnerReviews", "requireLastPushApproval") if classic.get(k)]
        if cannot:
            raise Refuse("#%d is blocked and the classic protection of %s (%s) requires %s, which this gate cannot "
                         "prove met: an admin merge would bypass it" % (number, base, classic.get("pattern"), ", ".join(cannot)))
    unknown = sorted(t for t in types if t not in KNOWN_RULES)
    if admin and unknown:
        raise Refuse("#%d is blocked and %s has rule(s) this gate cannot judge (%s): an admin merge would bypass them"
                     % (number, base, ", ".join(str(t) for t in unknown)))
    command = "gh pr merge %d --repo %s/%s --merge --match-head-commit %s%s%s%s" % (
        number, owner, name, expected, " --admin" if admin else "", " --delete-branch" if delete_branch else "",
        " --subject " + shlex.quote(subject) if subject else "")
    why = ("required checks green at %s: %s" % (expected[:12], ", ".join(sorted({r[0] for r in required})))) if required \
        else "%s requires no check; GitHub reads #%d as %s" % (base, number, state)
    return command, why


def main(argv):
    args, delete_branch, repo, subject, all_green = [], False, None, None, False
    it = iter(argv[1:])
    for a in it:
        if a == "--delete-branch":
            delete_branch = True
        elif a == "--all-green":
            all_green = True
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
        sys.stderr.write("usage: merge-gate.py <pr-number> <expected-head-sha (40 hex)> [--all-green] [--delete-branch] [--subject <text>] [--repo <owner>/<name>]\n")
        return 2
    number, expected = int(args[0]), args[1]
    try:
        if repo is None:
            code, out, err = gh("repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner")
            repo = out.strip()
            if code != 0 or not REPO.match(repo):
                raise Unreadable("the repository could not be resolved: %s" % (err or out).strip()[:200])
        owner, name = repo.split("/")
        try:
            command, why = decide(number, expected, owner, name, delete_branch, subject, all_green)
        except Retry:
            try:
                command, why = decide(number, expected, owner, name, delete_branch, subject, all_green)
            except Retry as again:
                raise Refuse("%s twice: run the gate again once it settles" % again)
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
