#!/usr/bin/env python3
"""Was this commit the head of a settled review of THIS pull request into THIS base? The durable,
cross-machine proof a release reads.

A review receipt (`review-gate.py`) lives on the machine that ran the review; a release usually runs
on another. So a settled pull-request review also leaves its proof on GitHub, on the exact commit it
reviewed: a commit status with the context `devstride/reviewed` whose description names the pull
request and the base it was reviewed against (`Settled review of #<n> into <base>`). A review of a
story into an epic branch never proves a later merge of the same commit onto the train. The release
train's exclusion check (`skills/release/scripts/train_exclusions.py`) accepts a release unit as
reviewed only through `verify`, never through its branch name. Run in the repository; `gh`
resolves `{owner}/{repo}`.

  post <sha> --pr <n> --base <branch> [--from <reviewed-sha>]
        Post a `success` status on <sha>, the head of open pull request <n>, whose base must still be
        <branch>, the base the review was done against (GitHub's own head, state and base for <n> are
        read; a pull request retargeted after its review gets no proof). `review` runs it once a pull
        request settles READY, with the final reviewed head; `build-item` 5b runs it with `--from` to carry
        a review to a tree-identical rebase: <sha> and <reviewed-sha> must have the same tree, and
        <reviewed-sha> must itself verify for <n> and its base. Post ONLY there: never to clear a
        release refusal (a refused unit goes back to the owner). After posting it verifies; a post
        that does not count (the poster is not a repository admin) says so.
        POSTED <sha> ... exit 0 | NOT POSTED <reason> exit 2 (the merge goes on; the release then
        checks that unit file by file, as it does any unreviewed work; except into the train with a
        `release.releaseBranchFixExclusions` path, where the merge gate refuses it without the proof,
        so review stops there)
  verify <sha> [--pr <n> --base <branch>]
        REVIEWED <sha> by <login> exit 0 | UNREVIEWED <reason> exit 2 | ERROR <reason> exit 1

A proof names its base, so renaming the train voids the proofs of units still open against the old
name: an admin re-posts them after the cutover. Withdrawing a proof does not follow a copy already
carried to a rebased head: withdraw both heads.

Trust: only a status posted by an account with ADMIN permission on the repository counts, because
anyone who can push (a partner's branch, a workflow token) can post a commit status too. Statuses
from anyone else, from apps and bots, and from deleted accounts are ignored. Permission is read at
verify time: demoting an admin voids the proofs they posted. Read newest first, an admin status
that is not `success` withdraws every older one, so an admin withdraws a proof by posting
`failure`. Status state, description, creator and permission come from GitHub's API; nothing is
inferred from a branch name, a commit message or a comment.
"""
import json
import os
import re
import subprocess
import sys
import time

CONTEXT = "devstride/reviewed"
SHA = re.compile(r"^[0-9a-f]{40}$")
TRUSTED = ("admin",)


class Unreadable(Exception):
    pass


class NotFound(Unreadable):
    pass


def gh_json(cwd, *args):
    try:
        p = subprocess.run(["gh"] + list(args), cwd=cwd, capture_output=True, text=True)
    except OSError as err:
        raise Unreadable("gh could not run: %s" % err)
    if p.returncode != 0:
        err = (p.stderr or p.stdout).strip()
        raise (NotFound if "HTTP 404" in err else Unreadable)(
            "gh %s failed: %s" % (" ".join(args[:2]), err[:200]))
    try:
        return json.loads(p.stdout)
    except ValueError:
        raise Unreadable("gh %s returned something that is not JSON" % " ".join(args[:2]))


def statuses(sha, cwd):
    """Every commit status on <sha> for the context, newest first (paged)."""
    found, page = [], 1
    while True:
        batch = gh_json(cwd, "api", "repos/{owner}/{repo}/commits/%s/statuses?per_page=100&page=%d" % (sha, page))
        if not isinstance(batch, list):
            raise Unreadable("the statuses on %s could not be read" % sha[:12])
        found += [s for s in batch if isinstance(s, dict) and isinstance(s.get("context"), str)
                  and s["context"].lower() == CONTEXT]   # GitHub's contexts are case-insensitive
        if len(batch) < 100:
            break
        page += 1   # GitHub's 1,000 limit is per context, so other contexts can make many pages
    for s in found:
        if not (isinstance(s.get("state"), str) and isinstance(s.get("created_at"), str)
                and isinstance(s.get("id"), int)):
            raise Unreadable("a %s status on %s could not be read" % (CONTEXT, sha[:12]))
    return sorted(found, key=lambda s: (s["created_at"], s["id"]), reverse=True)


def permission(creator, cwd, cache):
    """The repository permission of a status's creator; "none" for an app, a bot or a deleted
    account (their statuses never count)."""
    login = creator.get("login") if isinstance(creator, dict) else None
    if not isinstance(login, str) or not login or creator.get("type") == "Bot":
        return "none"
    if login not in cache:
        try:
            got = gh_json(cwd, "api", "repos/{owner}/{repo}/collaborators/%s/permission" % login)
        except NotFound:
            got = {"permission": "none"}
        level = got.get("permission") if isinstance(got, dict) else None
        if not isinstance(level, str):
            raise Unreadable("the permission of %s could not be read" % login)
        cache[login] = level
    return cache[login]


def describes(description, pr, base):
    """Does an admin's description name pull request <pr> into <base>? (None: any.)"""
    if not isinstance(description, str):
        return False
    if pr is None:
        return description.startswith("Settled review of #")
    stem = "Settled review of #%s into %s" % (pr, base)
    return description == stem or description.startswith(stem + ", carried from ")


def verify(sha, cwd, pr=None, base=None):
    """(True, login) when, read newest first, an admin's `success` status naming pull request <pr>
    into <base> comes before any admin status that is not `success`; else (False, reason). Raises
    Unreadable when GitHub cannot be read."""
    if not SHA.match(sha or ""):
        return False, "%r is not a full commit SHA" % sha
    cache, what = {}, (" for #%s into %s" % (pr, base)) if pr is not None else ""
    trusted = [s for s in statuses(sha, cwd) if permission(s.get("creator"), cwd, cache) in TRUSTED]
    for s in trusted:
        if s["state"] != "success":
            return False, "an admin withdrew the %s proof on %s (newest admin status: %s)" % (CONTEXT, sha[:12], s["state"])
        if describes(s.get("description"), pr, base):
            return True, s["creator"]["login"]
    return False, "no %s status from a repository admin on %s%s" % (CONTEXT, sha[:12], what)


def tree(sha, cwd):
    p = subprocess.run(["git", "rev-parse", "--verify", "--quiet", "%s^{tree}" % sha], cwd=cwd,
                       capture_output=True, text=True, env=dict(os.environ, GIT_NO_REPLACE_OBJECTS="1"))
    return p.stdout.strip() if p.returncode == 0 else None


def post(sha, cwd, pr, base, source=None, wait=3):
    if not SHA.match(sha or ""):
        return False, "%r is not a full commit SHA" % sha
    if not re.match(r"^[1-9][0-9]*$", pr or ""):
        return False, "--pr %r is not a pull request number" % pr
    if not base or base.startswith(("origin/", "refs/")) or re.match(r"^[0-9a-f]{40}$", base):
        return False, "--base %r: pass the bare branch name the review ran against (e.g. train), never a remote ref or a SHA" % base
    for attempt in (0, 1):   # just after a push GitHub may still report the old head: read once more
        info = gh_json(cwd, "pr", "view", pr, "--json", "state,headRefOid,baseRefName")
        if not isinstance(info, dict) or info.get("headRefOid") == sha or attempt:
            break
        time.sleep(wait)
    if not isinstance(info, dict) or info.get("state") != "OPEN":
        return False, "#%s is not an open pull request" % pr
    if info.get("headRefOid") != sha:
        return False, "%s is not the head of #%s (%s)" % (sha[:12], pr, str(info.get("headRefOid"))[:12])
    if info.get("baseRefName") != base:
        return False, "#%s is based on %s now, not %s, the base it was reviewed against" % (pr, info.get("baseRefName"), base)
    if source is not None:
        if not SHA.match(source):
            return False, "--from %r is not a full commit SHA" % source
        a, b = tree(source, cwd), tree(sha, cwd)
        if not a or not b:
            return False, "the trees of %s and %s could not be read" % (source[:12], sha[:12])
        if a != b:
            return False, "%s is not a tree-identical rebase of the reviewed head %s" % (sha[:12], source[:12])
        ok, why = verify(source, cwd, pr, base)
        if not ok:
            return False, "the reviewed head carries no proof to carry over: %s" % why
    description = "Settled review of #%s into %s%s" % (
        pr, base, ", carried from %s (same tree)" % source[:12] if source else "")
    if len(description) > 140:
        return False, "the base name of #%s is too long for a status description" % pr
    gh_json(cwd, "api", "-X", "POST", "repos/{owner}/{repo}/statuses/%s" % sha, "-f", "state=success",
            "-f", "context=%s" % CONTEXT, "-f", "description=%s" % description)
    ok, why = verify(sha, cwd, pr, base)
    if not ok:
        return False, "posted, but it does not count as proof (only a repository admin's status does): %s" % why
    return True, description


def wait_seconds():
    try:
        return min(60.0, max(0.0, float(os.environ.get("REVIEWED_STATUS_WAIT", "3"))))
    except ValueError:
        return 3.0


def main(argv):
    args = argv[1:]
    usage = ("usage: reviewed-status.py post <sha> --pr <n> --base <branch> [--from <reviewed-sha>]"
             " | verify <sha> [--pr <n> --base <branch>]\n")
    if not args or args[0] not in ("post", "verify") or len(args) < 2:
        sys.stderr.write(usage)
        return 2
    verb, sha, rest = args[0], args[1], args[2:]
    allowed = ("--from", "--pr", "--base") if verb == "post" else ("--pr", "--base")
    opts = {}
    while rest:
        if rest[0] in allowed and len(rest) > 1 and rest[0] not in opts:
            opts[rest[0]] = rest[1]
            rest = rest[2:]
        else:
            sys.stderr.write(usage)
            return 2
    if (verb == "post" and ("--pr" not in opts or "--base" not in opts)) or (
            verb == "verify" and ("--pr" in opts) != ("--base" in opts)):
        sys.stderr.write(usage)
        return 2
    try:
        if verb == "verify":
            ok, why = verify(sha, None, opts.get("--pr"), opts.get("--base"))
            print(("REVIEWED %s by %s" if ok else "UNREVIEWED %s") % ((sha, why) if ok else (why,)))
            return 0 if ok else 2
        ok, why = post(sha, None, opts["--pr"], opts["--base"], opts.get("--from"),
                       wait_seconds())
        print(("POSTED %s %s: %s" % (sha, CONTEXT, why)) if ok else "NOT POSTED %s" % why)
        return 0 if ok else 2
    except Unreadable as err:
        print(("ERROR %s" if verb == "verify" else "NOT POSTED %s") % err)
        return 1 if verb == "verify" else 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
