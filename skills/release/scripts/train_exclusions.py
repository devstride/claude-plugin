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
                   `release.releaseSource` (default `develop` only when the key is missing), `releaseTrain.branch` (the old name `supportTrain.branch`
                   when only that is present), `epicIntegrationBranches.pattern` and the optional
                   `release.migrationRenumber` ({"sqlGlobs": [...], "metaGlobs": [...]}).
  --source-before  the release source's SHA when the train snapshot was cut (the range start); it
                   must be an ancestor of --head and of `origin/<releaseSource>` (--start-on source,
                   the default) or of `origin/<train>` (--start-on train, for a start on the
                   train such as step 4a's snapshot), else exit 2.
  --head           the snapshot (or any commit) whose range `<source-before>..<head>` is checked.
  --train          the train branch (default: the configured `releaseTrain.branch`); a reviewed
                   release unit counts only when its pull request was based on it.
  --repo           the git repository (default: the current directory). `gh` is called from there,
                   found on PATH.

Checked set: the files each FIRST-PARENT commit in `<source-before>..<head>` changed
(`git diff --name-only --no-renames <c>^1 <c>`). Left out of it:
  (i)  a merge of the release source (its second parent is an ancestor of `origin/<releaseSource>`),
       for what the source changed — anything else it does to the train side is checked;
  (ii) a merge that brought a REVIEWED release-unit pull request onto the train: the subject is
       `Merge pull request #<n> from <owner>/<head>`, `<head>` matches `epicIntegrationBranches.pattern`
       (matched as in `skills/release/references/branch-patterns.md`, with date tokens and every other
       token a wildcard), AND `gh pr view <n> --json baseRefName,state,mergeCommit` says the pull
       request is MERGED, based on the train, with exactly that commit as its merge commit. A
       hand-written subject gh does not confirm is checked like any other commit.
A merge with more than two parents (octopus) is never exempt and never expanded: its whole diff
against its first parent is checked. Migration metadata (`migrationRenumber.metaGlobs`) that only a
merge changed is allowed when the range also yields an allowed renumber. Every merge, exempt or not, also has what it ITSELF changed (beyond git's own merge of its
parents: a conflict resolution or a hand edit) checked. A merge that is neither of the above whose second parent is an ancestor of
`origin/<train>` is a late absorption of train commits: its brought-in first-parent commits are
judged by these same rules, recursively. Paths are read NUL-delimited. Everything else (a fast-merged one-off, a direct commit, a snapshot fix commit) is checked exactly:
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
SKILLS = os.path.dirname(os.path.dirname(HERE))
ROUTING = os.path.join(SKILLS, "build-item/scripts/routing.py")


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


def zlist(text):
    return [x for x in text.split("\0") if x]


def name_status(repo, first, c):
    """{path: status letter} for c against its first parent, NUL-delimited so no path is mangled."""
    tokens = zlist(git(repo, "diff", "--name-status", "--no-renames", "-z", first, c).stdout.decode("utf-8", "surrogateescape"))
    return {tokens[i + 1]: tokens[i][:1] for i in range(0, len(tokens) - 1, 2)}


def merge_only_changes(repo, c, parents):
    """Files a merge's result changes beyond what git's own merge of its parents produces: conflict
    resolutions and hand edits ('evil merges'), plus every path git reported as conflicted (a
    modify/delete or rename conflict leaves no markers, so its resolution may match the synthetic
    tree). A clean automatic merge of edits both sides made to one file is not listed. Two parents
    are compared with `git merge-tree --write-tree` (git 2.38+); when it cannot run the check stops
    (exit 2) rather than check less. More than two parents: the combined diff (`--cc`); such a merge
    is also checked in full against its first parent."""
    if len(parents) != 2:
        out = git(repo, "diff-tree", "-z", "--cc", "--name-only", "--no-commit-id", "-r", c).stdout
        return zlist(out.decode("utf-8", "surrogateescape"))
    p = git(repo, "merge-tree", "--write-tree", "-z", parents[0], parents[1], check=False)
    tokens = p.stdout.decode("utf-8", "surrogateescape").split("\0")
    tree = tokens[0].strip() if tokens else ""
    if p.returncode not in (0, 1) or not re.fullmatch(r"[0-9a-f]{40,64}", tree):
        fail("git merge-tree --write-tree failed for %s (git 2.38 or newer is needed): %s"
             % (c, p.stderr.decode("utf-8", "replace").strip()))
    conflicted = set()
    if p.returncode == 1:
        i = 1
        while i < len(tokens) and tokens[i]:
            conflicted.add(tokens[i].split("\t", 1)[1] if "\t" in tokens[i] else tokens[i])
            i += 1
        # every conflict git reports must name a file it lists as conflicted: a directory-rename
        # split names only a directory, and can sit beside an ordinary conflict
        unlisted = set()
        try:
            i += 1
            while i < len(tokens) and tokens[i]:
                n = int(tokens[i])
                paths, kind = tokens[i + 1:i + 1 + n], tokens[i + 1 + n]
                i += n + 3
                if kind != "Auto-merging":
                    unlisted.update(x for x in paths if x not in conflicted)
        except (ValueError, IndexError):
            fail("could not read git merge-tree's conflict messages for %s" % c)
        if not conflicted or unlisted:
            fail("git merge-tree reported a conflict in %s on %s that names no conflicted file; "
                 "check that merge by hand" % (c, ", ".join(sorted(unlisted)) or "no path"))
    out = git(repo, "diff", "--name-only", "--no-renames", "-z", tree, c).stdout
    return sorted(set(zlist(out.decode("utf-8", "surrogateescape"))) | conflicted)


def analyse(repo, config, source_before, head, train, start_on="source"):
    release = config.get("release") if isinstance(config.get("release"), dict) else {}
    exclusions = release.get("releaseBranchFixExclusions") or []
    source = release["releaseSource"] if "releaseSource" in release else "develop"
    epic_pattern = (config.get("epicIntegrationBranches") or {}).get("pattern")
    if not isinstance(exclusions, list) or not all(isinstance(x, str) for x in exclusions):
        fail("config: release.releaseBranchFixExclusions must be a list of patterns")
    if not isinstance(source, str) or not source:
        fail("config: release.releaseSource must be a non-empty string when present")
    epic_regex = routing.template_regex(epic_pattern, {}) if isinstance(epic_pattern, str) and epic_pattern else None
    renumber = release.get("migrationRenumber")
    sql_globs = meta_globs = None
    if isinstance(renumber, dict):
        sql_globs, meta_globs = renumber.get("sqlGlobs") or [], renumber.get("metaGlobs") or []
        for g in (sql_globs, meta_globs):
            if not isinstance(g, list) or not all(isinstance(x, str) for x in g):
                fail("config: release.migrationRenumber globs must be lists of patterns")

    origin_source, origin_train = "origin/" + source, "origin/" + train
    start_ref = origin_source if start_on == "source" else origin_train
    if not is_ancestor(repo, source_before, start_ref):
        fail("--source-before %s is not an ancestor of %s: the range is wrong" % (source_before, start_ref))
    if not is_ancestor(repo, source_before, head):
        fail("--source-before %s is not an ancestor of --head %s: the range is wrong" % (source_before, head))
    if start_on == "train" and not is_ancestor(repo, head, origin_train):
        fail("--head %s is not on %s: --start-on train checks train work only" % (head, origin_train))

    introduced, reviewed = set(), []
    refused, renumbers, pending_meta = set(), [], set()

    def check_commit(c, first):
        status = name_status(repo, first, c)
        hits = sorted(p for p in status if matches(p, exclusions))
        if not hits:
            return
        if sql_globs is None:
            refused.update(hits)
            return
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
        renumbers.extend({"from": old, "to": new} for old, new in pairs)

    def flag_merge_path(p):
        """An excluded path a merge itself changed: metadata waits on a renumber, the rest is refused."""
        if not matches(p, exclusions):
            return
        if sql_globs is not None and matches(p, meta_globs) and not matches(p, sql_globs):
            pending_meta.add(p)
        else:
            refused.add(p)

    def names(a, b):
        return set(zlist(git(repo, "diff", "--name-only", "--no-renames", "-z", a, b).stdout.decode("utf-8", "surrogateescape")))

    def walk(commits):
        for c in commits:
            parents = git_text(repo, "rev-list", "--parents", "-n", "1", c).split()[1:]
            if not parents:
                continue
            if len(parents) > 1:
                # what the merge ITSELF changed (a conflict resolution) is never exempt; migration
                # metadata resolved in a merge is allowed only if the range also yields a renumber
                for p in merge_only_changes(repo, c, parents):
                    flag_merge_path(p)
                if len(parents) > 2:  # an octopus merge is never exempt and never expanded
                    check_commit(c, parents[0])
                    continue
                if is_ancestor(repo, parents[1], origin_source):
                    # a source merge brings only what the source changed: anything else it does to
                    # the train side (a resolution that deletes or edits train work) is checked
                    # every merge base (criss-cross history has several): what the source changed
                    # since any of them is the source's own work
                    bases = git_text(repo, "merge-base", "--all", parents[0], parents[1]).split()
                    brought = set().union(*(names(b, parents[1]) for b in bases)) if bases else set()
                    for p in names(parents[0], c) - brought:
                        flag_merge_path(p)
                    continue
                number = reviewed_unit(repo, c, git_text(repo, "log", "-1", "--format=%s", c).strip(), epic_regex, train) \
                    if epic_regex else None
                if number is not None:
                    reviewed.append(number)
                    added = git(repo, "diff", "--name-only", "--no-renames", "-z", "--diff-filter=A", parents[0], c)
                    introduced.update(zlist(added.stdout.decode("utf-8", "surrogateescape")))
                    continue
                if is_ancestor(repo, parents[1], origin_train):
                    # a late absorption of train commits: judge what it brought, commit by commit
                    walk(git_text(repo, "rev-list", "--first-parent", "--reverse", parents[1], "^" + parents[0]).split())
                    continue
            check_commit(c, parents[0])

    walk(git_text(repo, "rev-list", "--first-parent", "--reverse", "%s..%s" % (source_before, head)).split())
    if not renumbers:
        refused.update(pending_meta)
    return {"refused": sorted(refused), "allowedRenumbers": renumbers, "reviewedUnits": reviewed}


def main(argv):
    opts, i = {}, 0
    names = {"--config": "config", "--source-before": "source", "--head": "head", "--train": "train", "--repo": "repo", "--start-on": "start"}
    while i < len(argv):
        if argv[i] not in names or i + 1 >= len(argv):
            fail("usage: train_exclusions.py --config <file> --source-before <sha> --head <ref> [--train <branch>] [--repo <dir>] [--start-on train|source]")
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
    start = opts.get("start", "source")
    if start not in ("source", "train"):
        fail("--start-on must be train or source")
    out = analyse(opts.get("repo") or ".", config, opts["source"], opts["head"], train, start)
    sys.stdout.write(json.dumps(out, sort_keys=True) + "\n")
    return 1 if out["refused"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
