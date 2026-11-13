#!/usr/bin/env python3
"""May this pull request merge now, and with which command? The one gate before every merge.

Every place the plugin merges (`release`, `build-item`, a departure's merge) runs this file and
then runs exactly the command it prints, never its own `gh pr merge`. It reads GitHub, and the
consuming repository's `.claude/ds-config.json` for the one rule that needs it (the train proof below).

  merge-gate.py <pr-number> <expected-head-sha> [--all-green] [--delete-branch] [--subject <text>]
                [--repo <owner>/<name>] [--config <ds-config.json>]

  --config defaults to `.claude/ds-config.json` at the top of the git checkout the gate runs in,
  which must be a checkout of the repository inspected. Only a confirmed checkout of it without
  that file (a repository without the loop's config) leaves the train proof rule inert; no
  checkout, a checkout of another repository, or a file that cannot be read or parsed is an ERROR.

  MERGE gh pr merge <n> --repo <owner>/<name> --merge --match-head-commit <sha> [--admin]
        [--delete-branch] [--subject '<text>']   exit 0: the repository it inspected is named, and
        the subject is shell-quoted, so the line runs as printed from any directory
        then one line naming the required checks that are green at <sha>
  REFUSE <reason>                                                                        exit 2
  ERROR <reason>   GitHub could not be read: nothing is known, so nothing merges          exit 1

The rule (an approver's admin merge exactly when every required check is green, never otherwise):
- Only through a pull request: the number must name an OPEN, non-draft pull request.
- A release unit merges onto the train only with its review proof: when the base is the
  configured release train (`releaseTrain.branch`) and the head is a release unit (its name matches
  `epicIntegrationBranches.pattern` or `planIntegrationBranches.pattern`, as `train_exclusions.py`
  matches it), the head must carry the settled review's proof for THIS pull request into THIS base
  (`reviewed-status.py verify <head> --pr <n> --base <base>`, its admin-trust rules unchanged),
  whatever paths it changes. No proof is a REFUSE naming the `post` command, pinned to the
  repository with `GH_REPO`, which still works because the pull request is open; a proof GitHub
  cannot read is an ERROR. Without it the release checks the unit file by file, and refuses its
  migrations and deploy configuration, hours later, when a merged pull request can no longer take a
  proof, so the gate asks for it while it still can. A head that is NOT a release unit and changes a
  file, by new or old name (the pull request's file list, every page, its count checked against
  GitHub's), matching `release.releaseBranchFixExclusions` (the one anchored matcher, `routing.py`'s
  `first_match`) is a REFUSE, since a proof would not save it. No train configured, another base,
  or a head that is not a release unit and changes no excluded path: the rule does nothing.
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
  event any job still pending refuses, and so does a run of that workflow still going that has
  not created the check yet, or a newer run that ended red without reporting it (the Actions API
  lists every run at the commit); an older run that is red counts when it was re-run after the run
  the verdict rests on began (a re-run keeps its old number; job times cannot order runs).
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
  So is any new workflow run, attempt, status or conclusion between the run listings read just
  before and just after a commit's checks (a re-run finishing between the reads).
- The checks are read last. The pull request's other facts (its state, threads, rulesets,
  classic protection, the base compare and the classic rule) are read and judged first; then the
  head's run listing, the pull request again with its check rollup, and the run listing again;
  then, when GitHub holds a test merge commit, its run listing, checks and run listing again; and
  the verdict follows with no further read. The second reading of the pull request must agree
  with the first (state, draft, head, base, merge state, review decision, test merge commit), or
  the gate reads everything afresh.
- Known limit: the verdict is one reading. GitHub does not re-check required checks at an
  `--admin` merge, so a check or status that turns red after it was read (during the reads that
  follow it: one run listing for the head's checks, plus the test merge commit's three reads when
  there is one; or before the printed command runs) is not seen. Reading the checks last narrows
  that window; only GitHub enforcing the checks at merge time (auto-merge or a merge queue
  instead of `--admin`) closes it. The other facts are read first, so a protection rule an admin
  changes during the check reads is not seen either. Run the command at once.
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
import importlib.util
import json
import os
import re
import shlex
import subprocess
import sys
from urllib.parse import quote

HERE = os.path.dirname(os.path.abspath(__file__))
SKILLS = os.path.dirname(os.path.dirname(HERE))
ROUTING = os.path.join(SKILLS, "build-item/scripts/routing.py")
REVIEWED = os.path.join(SKILLS, "review/scripts/reviewed-status.py")
FILES_LIMIT = 3000   # GitHub's pull-request files listing stops here

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
      number state isDraft headRefOid headRefName baseRefName mergeStateStatus reviewDecision changedFiles
      latestOpinionatedReviews(first: 100) { pageInfo { hasNextPage } nodes { state author { login } } }
      potentialMergeCommit { oid }
      commits(last: 1) { nodes { commit { oid statusCheckRollup {
        contexts(first: 100, after: $after) {
          pageInfo { hasNextPage endCursor }
          nodes {
            __typename
            ... on CheckRun { name status conclusion startedAt completedAt databaseId isRequired(pullRequestNumber: $number)
                              checkSuite { app { databaseId } workflowRun { databaseId runNumber event workflow { databaseId } } } }
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
                              checkSuite { app { databaseId } workflowRun { databaseId runNumber event workflow { databaseId } } } }
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


def gh(*args, env=None):
    try:
        done = subprocess.run(["gh"] + list(args), capture_output=True, text=True, timeout=60, env=env)
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


def stream_verdict(byRun, began):
    """One event's runs of one check: (verdict, earned). Any job of any run still pending is
    PENDING. The verdict rests on the newest run by number or, when that run is quiet, on the
    newest run that executed. An older run that is red still counts when its latest attempt is a
    re-run that began after that run's (a re-run keeps its old number; a first attempt began no
    later than any higher-numbered run), read through began(n) -> (attempt, start) only then.
    A quiet result with no executed run is unearned."""
    numbers = sorted(byRun)
    if any("PENDING" in states for states in byRun.values()):
        return "PENDING", False, numbers[-1]
    verdict = {n: worst(byRun[n]) for n in byRun}
    relied = numbers[-1]
    state = verdict[relied]
    if state in QUIET:
        executed = [n for n in numbers if verdict[n] not in QUIET]
        if not executed:
            return state, False, relied
        relied = executed[-1]
        if verdict[relied] != "SUCCESS":
            return verdict[relied], True, relied
    elif state not in PASSED:
        return state, True, relied
    for n in numbers:
        if n < relied and verdict[n] not in PASSED and began(n)[0] > 1 and began(n)[1] > began(relied)[1]:
            return verdict[n], True, relied
    return state, True, relied


def _later(a, b):
    """Workflow run a supersedes run b: a re-run that began after b did, or a higher number that b
    was not re-run past (a re-run keeps its number; a first attempt began when it was created)."""
    if a["run_attempt"] > 1 and a["run_started_at"] > b["run_started_at"]:
        return True
    return a["run_number"] > b["run_number"] and not (b["run_attempt"] > 1 and b["run_started_at"] > a["run_started_at"])


def _unreadable(message):
    raise Unreadable(message)


def runs_at_head(contexts, workflow_runs):
    """Every distinct check at this head and its verdict. A check run belongs to one (name, app,
    workflow), and a commit status is one context (GitHub reports only its latest state). Same-name
    checks from another workflow or app, and a same-name status, stay separate: each must pass. A
    check run from a workflow event GitHub does not count (ELIGIBLE) is left out: it neither
    satisfies a check nor stands in front of an older one. Each counted event (push,
    pull_request, ...) is its own stream, judged by stream_verdict, and no stream may be failing or
    pending: a later push run never hides a failed pull_request run. Same-name jobs in one run are
    siblings that must all pass. workflow_runs() lists every workflow run at this commit from the
    Actions API, jobs or not: a run of the check's workflow and event still going holds the check
    PENDING (a newer run may not have created it yet), a newer run that ended red without
    reporting it refuses, and each run's run_started_at (its latest attempt; job times cannot
    order runs) orders a red run against the one the verdict rests on. A skipped or neutral verdict is earned when a
    stream executed, or when another job of that same workflow run succeeded (a job skipped
    because its run found nothing to test); a check where nothing ever ran (a draft's held CI,
    read before the ready run starts) or a quiet check from outside a workflow is UNEARNED."""
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
            key, number, stream = ("check", c.get("name"), app, workflow), run.get("runNumber") or 0, run.get("event")
            state = c.get("conclusion") if c.get("status") == "COMPLETED" else "PENDING"
            if workflow and state == "SUCCESS":
                ran.add((app, workflow, number))
        elif c.get("__typename") == "StatusContext":
            key, number, stream = ("status", c.get("context"), None, None), 0, None
            state = {"PENDING": "PENDING", "EXPECTED": "PENDING"}.get(c.get("state"), c.get("state"))
        else:
            continue
        if key[1]:
            entry = runs.setdefault(key, {"required": False, "streams": {}})
            entry["required"] = entry["required"] or bool(c.get("isRequired"))
            entry["streams"].setdefault(stream, {}).setdefault(number, []).append(state or "PENDING")
    listed = workflow_runs() if any(key[0] == "check" and key[3] for key in runs) else []
    verdicts = {}
    for key, entry in runs.items():
        judged = {}
        events = set(entry["streams"]) | {r["event"] for r in listed if key[3] and r["workflow_id"] == key[3]
                                           and r["event"] in ELIGIBLE}
        for event in events:
            byRun = entry["streams"].get(event, {})
            mine = [r for r in listed if key[3] and r["workflow_id"] == key[3] and r["event"] == event]
            going = sorted(r["run_number"] for r in mine if r["status"] != "completed")
            done = [r for r in mine if r["status"] == "completed"]
            passed = [r for r in done if r.get("conclusion") in ("success", "skipped", "neutral")]
            green = [r for r in passed if (key[2], key[3], r["run_number"]) in ran]
            # a red run that never reported the check counts unless a later run of this workflow and
            # event passed with a job that executed (a cancel the next run replaced; a run where every
            # job skipped proves nothing); later: a higher number it was not re-run past, or a re-run
            # that began after it
            red_runs = [r for r in done if r not in passed and r["run_number"] not in byRun
                        and not any(_later(g, r) for g in green)]
            if not byRun:
                # runs of this workflow and event that never reported the check: one still going or
                # ended red (a matrix that failed before creating it) holds it; a green one says nothing
                if going:
                    judged[event] = ("PENDING", False)
                elif red_runs:
                    r = max(red_runs, key=lambda r: r["run_number"])
                    judged[event] = ("%s (workflow run #%d ended so without reporting it)"
                                     % (str(r.get("conclusion")).upper(), r["run_number"]), True)
                continue
            began = lambda n, mine=mine: next(((r["run_attempt"], r["run_started_at"]) for r in mine if r["run_number"] == n), None) \
                or _unreadable("workflow run #%s of workflow %s is not in the run list" % (n, key[3]))
            state, earned, relied = stream_verdict(byRun, began)
            anchor = None if not key[3] else next((r for r in mine if r["run_number"] == relied), None) \
                or _unreadable("workflow run #%s of workflow %s is not in the run list" % (relied, key[3]))
            ended = sorted((r["run_number"], r.get("conclusion")) for r in red_runs if anchor and _later(r, anchor))
            if going and state in PASSED + ("PENDING",):
                state, earned = "PENDING", False
            elif ended and state in PASSED:
                state, earned = "%s (workflow run #%d ended so without reporting it)" % (str(ended[-1][1]).upper(), ended[-1][0]), True
            judged[event] = (state, earned)
        red = [v for v, _ in judged.values() if v not in PASSED]
        if red:
            state = next((v for v in red if v != "PENDING"), "PENDING")
        elif any(v == "SUCCESS" for v, _ in judged.values()):
            state = "SUCCESS"
        else:
            state = next(iter(judged.values()))[0]
            bare = not any(earned for _, earned in judged.values())
            newest = [max(byRun) for byRun in entry["streams"].values()]
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


def workflow_runs(owner, name, sha):
    """Every workflow run at one commit (the Actions API), jobs or not, paged."""
    found, page = [], 1
    while True:
        got = gh_json("api", "repos/%s/%s/actions/runs?head_sha=%s&per_page=100&page=%d" % (owner, name, sha, page))
        batch = got.get("workflow_runs") if isinstance(got, dict) else None
        if not isinstance(batch, list) or not isinstance(got.get("total_count"), int):
            raise Unreadable("the workflow runs at %s could not be listed" % sha[:12])
        for r in batch:
            if not (isinstance(r, dict) and isinstance(r.get("id"), int) and isinstance(r.get("workflow_id"), int)
                    and isinstance(r.get("run_number"), int) and isinstance(r.get("status"), str)
                    and isinstance(r.get("run_started_at"), str) and isinstance(r.get("run_attempt"), int)):
                raise Unreadable("a workflow run at %s could not be read" % sha[:12])
        found += batch
        if len(found) >= got["total_count"] or not batch:
            return found
        if page >= 10:
            raise Unreadable("more than 1,000 workflow runs at %s" % sha[:12])
        page += 1


def settled(owner, name, sha, before):
    """The workflow runs at a commit read again after its checks were: any new run, attempt, status
    or conclusion since the read before them means the checks may be stale (a re-run finishing
    between the two reads), so the gate reads everything afresh."""
    after = workflow_runs(owner, name, sha)
    mark = lambda runs: sorted((r["id"], r["run_attempt"], r["status"], r.get("conclusion")) for r in runs
                               if r.get("event") in ELIGIBLE)   # a comment-triggered run never decides a check
    if mark(after) != mark(before):
        raise Retry("the workflow runs at %s changed while its checks were being read" % sha[:12])
    return after


def admissible(pr, number, expected):
    """The pull request's own state, from one reading of it: open, not a draft, at the expected
    head, mergeable, and no review asking for changes. Refuses, or returns its merge state."""
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
    return state


# What the static reading decided on; the pull request read again with its checks must agree, or
# a decision rests on facts that changed in between.
SAME = ("state", "isDraft", "headRefOid", "_oid", "baseRefName", "mergeStateStatus", "reviewDecision")


def load(module_name, path):
    """The one glob matcher lives in routing.py and the one review proof in reviewed-status.py:
    reuse them, never a second copy. Loaded only when the train rule applies."""
    try:
        spec = importlib.util.spec_from_file_location(module_name, path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    except (OSError, SyntaxError, AttributeError, ImportError) as err:
        raise Unreadable("%s could not be loaded: %s" % (os.path.basename(path), err))
    return module


def read_config(path, owner, name):
    """(train, exclusions, unit patterns) from the consuming repository's config; (None, [], [])
    only when a confirmed checkout of the inspected repository has no config."""
    if path is None:
        code, out, _ = git_out("rev-parse", "--show-toplevel")
        if code != 0 or not out.strip():
            raise Unreadable("not in a git checkout, so the repository's config cannot be found: run from a "
                             "checkout of %s/%s or pass --config" % (owner, name))
        top = out.strip()
        # The checkout's own repository: GH_REPO would make gh report whatever it names instead.
        code, here, err = gh("repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner",
                             env={k: v for k, v in os.environ.items() if k != "GH_REPO"})
        if code != 0 or here.strip().lower() != ("%s/%s" % (owner, name)).lower():
            raise Unreadable("this checkout is not %s/%s (%s), so its config is not that repository's: run "
                             "from a checkout of it or pass --config" % (owner, name, (here or err).strip()[:80] or "unknown"))
        path = os.path.join(top, ".claude", "ds-config.json")
        if not os.path.exists(path):
            return None, [], []
    try:
        with open(path) as f:
            config = json.load(f)
    except (OSError, ValueError) as err:
        raise Unreadable("the config %s cannot be read: %s" % (path, err))
    if not isinstance(config, dict):
        raise Unreadable("the config %s is not a JSON object" % path)
    routing = load("merge_gate_routing", ROUTING)
    try:
        train = routing.train_section(config).get("branch")
    except SystemExit:
        raise Unreadable("the config %s names the train under both releaseTrain and supportTrain" % path)
    release = config.get("release") if isinstance(config.get("release"), dict) else {}
    exclusions = release.get("releaseBranchFixExclusions") or []
    if not isinstance(exclusions, list) or not all(isinstance(x, str) for x in exclusions):
        raise Unreadable("config: release.releaseBranchFixExclusions must be a list of patterns")
    if train is not None and (not isinstance(train, str) or not train):
        raise Unreadable("config: releaseTrain.branch must be a non-empty string when set")
    units = []
    for key in ("epicIntegrationBranches", "planIntegrationBranches"):
        pattern = (config.get(key) or {}).get("pattern") if isinstance(config.get(key), dict) else None
        if isinstance(pattern, str) and pattern:
            try:
                units.append(routing.template_regex(pattern, {}))
            except SystemExit:
                raise Unreadable("config: %s.pattern cannot be read" % key)
    return (train if exclusions else None), exclusions, units


def git_out(*args):
    try:
        done = subprocess.run(["git"] + list(args), capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return 1, "", ""
    return done.returncode, done.stdout, done.stderr


def changed_paths(owner, name, number, expected_count):
    """Every changed file of the pull request, new and old names, every page; the count must match."""
    if not isinstance(expected_count, int):
        raise Unreadable("#%d's changed-file count could not be read" % number)
    if expected_count > FILES_LIMIT:
        raise Refuse("#%d changes %d files, more than GitHub lists (%d), so this gate cannot see whether it "
                     "carries a migration or deploy configuration onto the train" % (number, expected_count, FILES_LIMIT))
    files, page = [], 1
    while True:
        batch = gh_json("api", "repos/%s/%s/pulls/%d/files?per_page=100&page=%d" % (owner, name, number, page))
        if not isinstance(batch, list):
            raise Unreadable("the files of #%d could not be read" % number)
        files += batch
        if len(batch) < 100:
            break
        page += 1
    if len(files) != expected_count:
        raise Unreadable("#%d lists %d changed files but GitHub counts %d" % (number, len(files), expected_count))
    paths = []
    for f in files:
        if not isinstance(f, dict) or not isinstance(f.get("filename"), str):
            raise Unreadable("a changed file of #%d could not be read" % number)
        paths.append(f["filename"])
        if isinstance(f.get("previous_filename"), str):
            paths.append(f["previous_filename"])
    return paths


def train_proof(pr, number, expected, owner, name, base, config_path):
    """REFUSE a release unit onto the train without its review proof, and a non-unit carrying excluded paths."""
    train, exclusions, units = read_config(config_path, owner, name)
    if not train or base != train:
        return
    routing = load("merge_gate_routing", ROUTING)
    try:
        hit = next((p for p in changed_paths(owner, name, number, pr.get("changedFiles"))
                    if routing.first_match(p, exclusions) is not None), None)
    except SystemExit:
        raise Unreadable("a release.releaseBranchFixExclusions pattern cannot be read")
    head = pr.get("headRefName")
    unit = isinstance(head, str) and any(u.match(head) for u in units)
    if not unit and hit is None:
        return
    if not unit:
        raise Refuse("#%d carries %s onto the train %s (it matches release.releaseBranchFixExclusions), but its head %s "
                     "is not an epic or plan integration branch, so the release refuses it even with a review proof: "
                     "merge it to the release source through its own pull request" % (number, hit, base, head))
    reviewed = load("merge_gate_reviewed_status", REVIEWED)
    previous = os.environ.get("GH_REPO")
    os.environ["GH_REPO"] = "%s/%s" % (owner, name)   # its `{owner}/{repo}` reads name this repository
    try:
        ok, why = reviewed.verify(expected, None, str(number), base)
    except reviewed.Unreadable as err:
        raise Unreadable("the review proof on %s could not be read: %s" % (expected[:12], err))
    finally:
        if previous is None:
            os.environ.pop("GH_REPO", None)
        else:
            os.environ["GH_REPO"] = previous
    if not ok:
        what = ("carries %s onto the train %s (it matches release.releaseBranchFixExclusions)" % (hit, base) if hit
                else "merges the release unit %s onto the train %s" % (head, base))
        raise Refuse("#%d %s and its head has no review proof (%s); once its review has settled, post it while the "
                     "pull request is open: GH_REPO=%s python3 %s post %s --pr %d --base %s"
                     % (number, what, why, shlex.quote("%s/%s" % (owner, name)), shlex.quote(REVIEWED), expected,
                        number, shlex.quote(base)))


def decide(number, expected, owner, name, delete_branch, subject=None, all_green=False, config_path=None):
    # The static facts first: the pull request's state, threads, rules, protection, the base
    # compare and the classic rule. None of them is a check, so the reads that are (the run
    # listings and the check rollup) come last, right before the verdict.
    pr = pull_request(owner, name, number)
    state = admissible(pr, number, expected)
    open_threads = unresolved_threads(owner, name, number)
    if open_threads:
        raise Refuse("#%d has %d unresolved review thread(s): resolve them first" % (number, open_threads))
    base = pr.get("baseRefName")
    if not isinstance(base, str) or not base:
        raise Unreadable("#%d names no base branch" % number)
    train_proof(pr, number, expected, owner, name, base, config_path)
    ruled, ruled_strict, types, approvals = ruleset_checks(owner, name, base)
    protected, protected_strict = protection_checks(owner, name, base)
    if ruled_strict or protected_strict:
        compared = gh_json("api", "repos/%s/%s/compare/%s...%s" % (owner, name, quote(base, safe=""), expected))
        behind = compared.get("behind_by") if isinstance(compared, dict) else None
        if not isinstance(behind, int):
            raise Unreadable("comparing %s with %s gave no behind_by" % (expected[:12], base))
        if behind:
            raise Refuse("#%d is %d commit(s) behind %s, which requires it to be up to date: update it, then check the new head"
                         % (number, behind, base))
    admin = state == "BLOCKED"
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

    # The checks, last: the head's run listing, the pull request read again with its check rollup,
    # and the listing again; then, when GitHub holds a test merge commit (a required check that
    # ran there must pass there too), its listing, checks and listing again. No other read follows
    # either, so every check is read at most one test merge commit's reads before the verdict.
    merge_oid = (pr.get("potentialMergeCommit") or {}).get("oid")
    before = workflow_runs(owner, name, expected)   # read before the checks, compared after them
    fresh = pull_request(owner, name, number)
    after = settled(owner, name, expected, before)
    if any(fresh.get(k) != pr.get(k) for k in SAME) \
            or (fresh.get("potentialMergeCommit") or {}).get("oid") != merge_oid:
        raise Retry("#%d changed while it was being read" % number)
    admissible(fresh, number, expected)   # a review asking for changes since the first reading
    on_merge = None
    if merge_oid:
        first = workflow_runs(owner, name, merge_oid)
        contexts = merge_commit_contexts(owner, name, number, merge_oid)
        listed = settled(owner, name, merge_oid, first)
        on_merge = runs_at_head(contexts, lambda: listed)
    runs = runs_at_head(fresh["_contexts"], lambda: after)
    required = ruled | protected | {(k[1], None) for k, (_, req) in runs.items() if req}
    problems = problems_with(required, runs)
    if problems:
        raise Refuse("not every required check is green at %s: %s" % (expected[:12], "; ".join(problems)))
    if on_merge is not None:
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
    args, delete_branch, repo, subject, all_green, config_path = [], False, None, None, False, None
    it = iter(argv[1:])
    for a in it:
        if a == "--delete-branch":
            delete_branch = True
        elif a == "--all-green":
            all_green = True
        elif a == "--repo":
            repo = next(it, None)
        elif a == "--config":
            config_path = next(it, None)
            if not config_path:
                sys.stderr.write("usage: --config takes a path\n")
                return 2
        elif a == "--subject":
            subject = next(it, "")
            if not subject.strip() or "\n" in subject:
                sys.stderr.write("usage: --subject takes one non-empty line\n")
                return 2
        else:
            args.append(a)
    if len(args) != 2 or not args[0].isdigit() or int(args[0]) < 1 or not SHA.match(args[1]) \
            or (repo is not None and not REPO.match(repo)):
        sys.stderr.write("usage: merge-gate.py <pr-number> <expected-head-sha (40 hex)> [--all-green] [--delete-branch] [--subject <text>] [--repo <owner>/<name>] [--config <ds-config.json>]\n")
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
            command, why = decide(number, expected, owner, name, delete_branch, subject, all_green, config_path)
        except Retry:
            try:
                command, why = decide(number, expected, owner, name, delete_branch, subject, all_green, config_path)
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
