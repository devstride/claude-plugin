#!/usr/bin/env python3
"""Should this session start the next release? The precondition half of `release.autoStart`.

The rules are in `skills/release/references/auto-start.md`. A trigger (a one-off landing on the
release train, an epic release merging onto it, or a release finishing) runs this, and only a
`START` goes on to claim the `release-train` claim; the claim, not this check, decides who wins.

  check   START <owner>/<repo> (<n> commit(s) on <train> not on <source>)                   exit 0
          SKIP <reason>                                                                   exit 0
          ERROR <reason>                                                                  exit 1
  key     prints <owner>/<repo>, the claim key                                            exit 0 | 1

`check` says START only when ALL hold: `release.autoStart.enabled` is true, a `claims` block is
configured, `release.mergeTrainBeforeCut` is true with a train branch (`releaseTrain.branch`, or by
its old name `supportTrain.branch`; both set is an ERROR), and after a fetch
`git log --no-merges origin/<releaseSource>..origin/<train>` is non-empty. It never looks for an
open train pull request: the winner's release step 0b runs that search itself, after the claim.
No network beyond `git ls-remote` and `git fetch`.

The train is looked up on origin first, the way routing.py's `resolve_train` does (one rule, reused):
not there and no other `train/*` branch → SKIP, nothing has landed yet; not there but exactly one
other `train/*` branch → ERROR naming the rename not yet cut over and its commands, because a
release reads only the configured train and would stop on it; several others → ERROR asking which
one is live. Never a fetch of a branch that is not there.

The key is lower-cased (GitHub names are case-insensitive), so every spelling of one remote claims
one key. Test seams: AUTO_START_REPO (owner/name, else parsed from `origin`), AUTO_START_NO_FETCH=1 (no
network: the heads are read from the local `refs/remotes/origin/*`).
"""
import importlib.util
import json
import os
import re
import subprocess
import sys


HERE = os.path.dirname(os.path.abspath(__file__))
ROUTING = os.path.join(os.path.dirname(os.path.dirname(HERE)), "build-item/scripts/routing.py")


def load_routing():
    """Where the train is on origin is routing.py's `resolve_train`; reuse it, never a second copy."""
    spec = importlib.util.spec_from_file_location("routing", ROUTING)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def out(line, code=0):
    print(line)
    sys.exit(code)


def load_config():
    here = os.path.abspath(os.getcwd())
    while True:
        candidate = os.path.join(here, ".claude", "ds-config.json")
        if os.path.isfile(candidate):
            try:
                with open(candidate) as handle:
                    loaded = json.load(handle)
            except (OSError, ValueError) as error:
                out("ERROR %s cannot be read as JSON (%s)" % (candidate, error), 1)
            return (loaded if isinstance(loaded, dict) else {}), os.path.dirname(os.path.dirname(candidate))
        parent = os.path.dirname(here)
        if parent == here:
            return {}, os.getcwd()
        here = parent


def section(value, key):
    found = value.get(key) if isinstance(value, dict) else None
    return found if isinstance(found, dict) else {}


def git(root, *args):
    return subprocess.run(["git", "-C", root] + list(args), capture_output=True, text=True)


def repo_key(root):
    forced = os.environ.get("AUTO_START_REPO")
    if forced:
        return forced.lower()
    url = git(root, "config", "--get", "remote.origin.url").stdout.strip()   # raw: insteadOf never moves the key
    match = re.search(r"[:/]([^/:]+)/([^/]+?)(?:\.git)?/?$", url)
    if not match:
        out("ERROR cannot read <owner>/<repo> from the origin remote (%r)" % url, 1)
    return ("%s/%s" % (match.group(1), match.group(2))).lower()


def origin_heads(root):
    """The branch names on origin: one `git ls-remote`, or the local remote-tracking refs offline."""
    if os.environ.get("AUTO_START_NO_FETCH") == "1":
        listed = git(root, "for-each-ref", "--format=%(refname:lstrip=3)", "refs/remotes/origin/")
        return {name for name in listed.stdout.split() if name and name != "HEAD"}
    listed = git(root, "ls-remote", "--heads", "origin")
    if listed.returncode != 0:
        out("ERROR git ls-remote of origin failed: %s" % (listed.stderr or "").strip()[:200], 1)
    return {line.split("refs/heads/", 1)[1] for line in listed.stdout.splitlines() if "refs/heads/" in line}


def check():
    config, root = load_config()
    release = section(config, "release")
    if section(release, "autoStart").get("enabled") is not True:
        out("SKIP release.autoStart.enabled is not true")
    if not isinstance(config.get("claims"), dict):
        out("SKIP release.autoStart needs a claims block; without one it does nothing")
    if isinstance(config.get("releaseTrain"), dict) and isinstance(config.get("supportTrain"), dict):
        out("ERROR both releaseTrain and supportTrain are set; supportTrain is the old name of releaseTrain", 1)
    train = (section(config, "releaseTrain") or section(config, "supportTrain")).get("branch")
    if release.get("mergeTrainBeforeCut") is not True or not isinstance(train, str) or not train:
        out("SKIP no release train (release.mergeTrainBeforeCut and releaseTrain.branch)")
    source = release.get("releaseSource") or "develop"   # the schema's default, never baseBranch
    where = load_routing().resolve_train(train, origin_heads(root))
    if "kind" in where:
        out("ERROR %s" % where["reason"], 1)
    if where["create"]:
        out("SKIP the release train %s is not on origin yet: nothing has landed on it" % train)
    if where["branch"] != train:
        out("ERROR a release reads only %s, so none can start until the rename is cut over%s"
            % (train, where["note"]), 1)
    if os.environ.get("AUTO_START_NO_FETCH") != "1":
        fetched = git(root, "fetch", "-q", "origin",
                      "+refs/heads/%s:refs/remotes/origin/%s" % (train, train),
                      "+refs/heads/%s:refs/remotes/origin/%s" % (source, source))
        if fetched.returncode != 0:
            out("ERROR git fetch of %s and %s failed: %s" % (train, source, (fetched.stderr or "").strip()[:200]), 1)
    ahead = git(root, "log", "--no-merges", "--format=%H", "origin/%s..origin/%s" % (source, train))
    if ahead.returncode != 0:
        out("ERROR cannot compare origin/%s with origin/%s: %s" % (train, source, (ahead.stderr or "").strip()[:200]), 1)
    commits = [line for line in ahead.stdout.splitlines() if line.strip()]
    if not commits:
        out("SKIP the train holds nothing beyond %s" % source)
    out("START %s (%d commit(s) on %s not on %s)" % (repo_key(root), len(commits), train, source))


def main(argv):
    if len(argv) != 2 or argv[1] not in ("check", "key"):
        sys.stderr.write("usage: auto-start.py check|key\n")
        return 2
    if argv[1] == "key":
        _, root = load_config()
        out(repo_key(root))
    check()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
