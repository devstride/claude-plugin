#!/usr/bin/env python3
"""The release train's fix-exclusion check — what the train may not carry, deterministic and stdlib-only.

The release skill's train procedure (`skills/release/references/release-branch.md`, section 1) refuses
deploy configuration and database migrations on the train, because the train reaches production at
the next release. A RELEASE UNIT (an epic's pull request) merged onto the train through its own
reviewed pull request is the exception: it was reviewed whole, so the check covers only work no pull
request reviewed. This script decides which is which.

Usage:
  train_exclusions.py --config <ds-config.json> --source-before <sha> --head <ref>
                      [--train <branch>] [--repo <dir>]

  --config         the repository's `.claude/ds-config.json`. Read: `release.releaseBranchFixExclusions`,
                   `release.releaseSource`, `releaseTrain.branch` (the old name `supportTrain.branch`
                   when only that is present), `epicIntegrationBranches.pattern` and the optional
                   `release.migrationRenumber` ({"sqlGlobs": [...], "metaGlobs": [...]}).
  --source-before  the release source's SHA when the train snapshot was cut (the range start).
  --head           the snapshot (or any commit) whose range `<source-before>..<head>` is checked.
  --train          the train branch (default: the configured `releaseTrain.branch`); a reviewed
                   release unit counts only when its pull request was based on it.
  --repo           the git repository (default: the current directory). `gh` is called from there,
                   found on PATH.

Checked set: the files each FIRST-PARENT commit in `<source-before>..<head>` changed
(`git diff --name-only --no-renames <c>^1 <c>`). Left out of it:
  (i)  a merge of the release source (its second parent is an ancestor of `origin/<releaseSource>`);
  (ii) a merge that brought a REVIEWED release-unit pull request onto the train: the subject is
       `Merge pull request #<n> from <owner>/<head>`, `<head>` matches `epicIntegrationBranches.pattern`
       (matched as in `skills/release/references/branch-patterns.md`, with date tokens and every other
       token a wildcard), AND `gh pr view <n> --json baseRefName,state,mergeCommit` says the pull
       request is MERGED, based on the train, with exactly that commit as its merge commit. A
       hand-written subject gh does not confirm is checked like any other commit.
Everything else (a fast-merged one-off, a direct commit, a snapshot fix commit) is checked exactly:
a changed file matching `release.releaseBranchFixExclusions` is refused.

Named exception, only with `release.migrationRenumber` set: a commit whose only excluded-path changes
are (a) a migration under `sqlGlobs` deleted and re-added under a new name with byte-identical
content, where the old file was introduced by a reviewed release unit in this range, and (b) files
under `metaGlobs`. It is reported as {"from", "to"}. Any other excluded-path change is refused.

Output (stdout, one JSON object):
  {"refused": [files], "allowedRenumbers": [{"from", "to"}], "reviewedUnits": [pull request numbers]}
Exit 0 nothing refused; 1 something refused; 2 usage, config or git error (one `train_exclusions:`
line on stderr).
"""
import importlib.util
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROUTING = os.path.join(HERE, "..", "..", "build-item", "scripts", "routing.py")


def fail(msg):
    sys.stderr.write("train_exclusions: %s\n" % msg)
    sys.exit(2)


def load_routing():
    """The one glob matcher (branch-patterns.md) lives in routing.py; reuse it, never a second copy."""
    spec = importlib.util.spec_from_file_location("routing", ROUTING)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


routing = load_routing()


def git(repo, *args, check=True):
    p = subprocess.run(["git", "-C", repo] + list(args), capture_output=True)
    if check and p.returncode != 0:
        fail("git %s failed: %s" % (" ".join(args), p.stderr.decode("utf-8", "replace").strip()))
    return p


def git_text(repo, *args):
    return git(repo, *args).stdout.decode("utf-8", "replace")


def is_ancestor(repo, a, b):
    return git(repo, "merge-base", "--is-ancestor", a, b, check=False).returncode == 0


def matches(path, patterns):
    return routing.first_match(path, patterns) is not None


def reviewed_unit(repo, commit, subject, epic_regex, train):
    """The pull request number when `commit` is the confirmed merge of a reviewed release unit."""
    m = re.match(r"^Merge pull request #([0-9]+) from [^/\s]+/(\S+)$", subject)
    if not m or not epic_regex.match(m.group(2)):
        return None
    number = m.group(1)
    try:
        p = subprocess.run(["gh", "pr", "view", number, "--json", "baseRefName,state,mergeCommit"],
                           cwd=repo, capture_output=True, text=True)
        info = json.loads(p.stdout) if p.returncode == 0 else None
    except (OSError, ValueError):
        info = None
    if not isinstance(info, dict) or info.get("state") != "MERGED" or info.get("baseRefName") != train:
        return None
    merge = info.get("mergeCommit")
    if not isinstance(merge, dict) or merge.get("oid") != commit:
        return None
    return int(number)


def analyse(repo, config, source_before, head, train):
    release = config.get("release") if isinstance(config.get("release"), dict) else {}
    exclusions = release.get("releaseBranchFixExclusions") or []
    source = release.get("releaseSource")
    epic_pattern = (config.get("epicIntegrationBranches") or {}).get("pattern")
    if not isinstance(exclusions, list) or not all(isinstance(x, str) for x in exclusions):
        fail("config: release.releaseBranchFixExclusions must be a list of patterns")
    if not isinstance(source, str) or not source:
        fail("config: release.releaseSource is missing")
    epic_regex = routing.template_regex(epic_pattern, {}) if isinstance(epic_pattern, str) and epic_pattern else None
    renumber = release.get("migrationRenumber")
    sql_globs = meta_globs = None
    if isinstance(renumber, dict):
        sql_globs, meta_globs = renumber.get("sqlGlobs") or [], renumber.get("metaGlobs") or []
        for g in (sql_globs, meta_globs):
            if not isinstance(g, list) or not all(isinstance(x, str) for x in g):
                fail("config: release.migrationRenumber globs must be lists of patterns")

    commits = git_text(repo, "rev-list", "--first-parent", "--reverse", "%s..%s" % (source_before, head)).split()
    origin_source = "origin/" + source
    introduced, reviewed, plan = set(), [], []
    for c in commits:
        parents = git_text(repo, "rev-list", "--parents", "-n", "1", c).split()[1:]
        if not parents:
            continue
        if len(parents) > 1:
            if is_ancestor(repo, parents[1], origin_source):
                continue
            number = reviewed_unit(repo, c, git_text(repo, "log", "-1", "--format=%s", c).strip(), epic_regex, train) \
                if epic_regex else None
            if number is not None:
                reviewed.append(number)
                added = git_text(repo, "diff", "--name-only", "--no-renames", "--diff-filter=A", parents[0], c)
                introduced.update(added.splitlines())
                continue
        plan.append((c, parents[0]))

    refused, renumbers = set(), []
    for c, first in plan:
        status = {}
        for line in git_text(repo, "diff", "--name-status", "--no-renames", first, c).splitlines():
            code, _, path = line.partition("\t")
            status[path] = code[:1]
        hits = sorted(p for p in status if matches(p, exclusions))
        if not hits:
            continue
        if sql_globs is None:
            refused.update(hits)
            continue
        deleted = [p for p in hits if status[p] == "D" and matches(p, sql_globs)]
        added = [p for p in hits if status[p] == "A" and matches(p, sql_globs)]
        meta = [p for p in hits if matches(p, meta_globs) and not matches(p, sql_globs)]
        pairs, unused = [], list(added)
        for old in deleted:
            if old not in introduced:
                continue
            before = git(repo, "show", "%s:%s" % (first, old), check=False)
            for new in unused:
                after = git(repo, "show", "%s:%s" % (c, new), check=False)
                if before.returncode == 0 and after.returncode == 0 and before.stdout == after.stdout:
                    pairs.append((old, new))
                    unused.remove(new)
                    break
        accounted = {p for pair in pairs for p in pair} | (set(meta) if pairs else set())
        refused.update(p for p in hits if p not in accounted)
        renumbers += [{"from": old, "to": new} for old, new in pairs]
    return {"refused": sorted(refused), "allowedRenumbers": renumbers, "reviewedUnits": reviewed}


def main(argv):
    opts, i = {}, 0
    names = {"--config": "config", "--source-before": "source", "--head": "head", "--train": "train", "--repo": "repo"}
    while i < len(argv):
        if argv[i] not in names or i + 1 >= len(argv):
            fail("usage: train_exclusions.py --config <file> --source-before <sha> --head <ref> [--train <branch>] [--repo <dir>]")
        opts[names[argv[i]]] = argv[i + 1]
        i += 2
    for key in ("config", "source", "head"):
        if not opts.get(key):
            fail("missing --%s" % {"source": "source-before"}.get(key, key))
    try:
        with open(opts["config"], encoding="utf-8") as f:
            config = json.load(f)
    except (OSError, ValueError) as error:
        fail("cannot read the config %s (%s)" % (opts["config"], error))
    if not isinstance(config, dict):
        fail("the config must be a JSON object")
    train_cfg = routing.train_section(config)
    train = opts.get("train") or train_cfg.get("branch")
    if not isinstance(train, str) or not train:
        fail("no train branch: pass --train or set releaseTrain.branch")
    out = analyse(opts.get("repo") or ".", config, opts["source"], opts["head"], train)
    sys.stdout.write(json.dumps(out, sort_keys=True) + "\n")
    return 1 if out["refused"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
