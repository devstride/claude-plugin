#!/usr/bin/env python3
"""Which commits on a release-train snapshot carry a review receipt, and what is left to review.

With `releaseTrain.reviewEveryLanding` true, every one-off is reviewed before it lands on the train
(`review-gate.py check`), and its landing merge records the review's receipt in its message
(`review-gate.py`'s `mergeBody`). The train's pull request into the release source then reviews
only what no receipt or pull request covers (`skills/release/references/release-branch.md` §1
step 4). This script decides which is which, from git and GitHub only; it changes nothing.

Usage:
  train_receipts.py --config <ds-config.json> --source-before <sha> --head <ref>
                    [--train <branch>] [--repo <dir>]

  --config         the repository's `.claude/ds-config.json`. Read: `release.releaseSource` (default
                   `develop` only when the key is missing), `releaseTrain.branch` (the old name
                   `supportTrain` when only that is present), `review.localCommand`,
                   `epicIntegrationBranches.pattern` and the optional `planIntegrationBranches.pattern`.
  --source-before  the start of the range (the release source's SHA when the snapshot was cut, or the
                   old snapshot for an absorbed range); it must be an ancestor of --head, else exit 2.
  --head           the snapshot head (or any commit) whose range `<source-before>..<head>` is read.
  --train          the train branch (default: the configured one).
  --repo           the git repository (default: the current directory).

Each FIRST-PARENT commit in the range is one of:
  - `receipted`: a landing on the train (a merge commit that `origin/<train>` contains) whose message
    carries a receipt line (`review-gate.py` `parse_receipt`) naming the commit that landed: the
    merge's second parent, or the head a clean refresh brought it to (each step a two-parent merge
    of train work the landing's first parent already holds, adding nothing of its own). Its engines
    must show a Claude result and, with `review.localCommand` set, a result from another engine.
  - `covered`: a merge of the release source (its second parent is an ancestor of
    `origin/<releaseSource>`), or the merge of a reviewed release unit (an epic's or a plan's pull
    request with its settled-review proof, as `train_exclusions.py` decides it).
  - `unreviewed`: everything else, with the diff to review (`git diff <from> <to>`): a landing with
    no receipt or one that names another commit (its whole change against the train), a direct
    commit (against its parent), a merge of anything else.
A late absorption (a snapshot merge of train commits, not itself on the train) is read commit by
commit, by these rules. What any merge ITSELF changed beyond git's own merge of its parents (a
conflict resolution, a hand edit; `train_exclusions.py`'s rule) is always `unreviewed`, whatever
else covers the merge: its `from` is git's automatic merge result (a tree id).

Output (stdout, one JSON object):
  {"verdict": "receipted" | "needs-review",
   "receipted": [{"commit", "item", "head", "cycles", "engines"}],
   "covered": [{"commit", "by"}],
   "unreviewed": [{"commit", "item", "why", "from", "to", "files"}],
   "body": the markdown list the train's pull request carries as its review evidence}
`item` is the number leading a fast merge's subject (`merge: <item> …`) or starting the branch name in
a pull-request merge subject, else null. Exit 0 when nothing is unreviewed, 1 when something is, 2
on a usage, config or git error (one `train_receipts:` line on stderr).
"""
import importlib.util
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SKILLS = os.path.dirname(os.path.dirname(HERE))
ITEM = re.compile(r"^merge: (I[0-9]+)\b|^Merge pull request #[0-9]+ from [^ /]+/(?:[^ ]+/)?(I[0-9]+)-")


def fail(msg):
    sys.stderr.write("train_receipts: %s\n" % msg)
    sys.exit(2)


def load(name, path):
    """The exclusion check's git and review-proof helpers and the gate's receipt parser: reused,
    never a second copy."""
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


te = load("train_exclusions", os.path.join(HERE, "train_exclusions.py"))
te.fail = fail
gate = load("review_gate", os.path.join(SKILLS, "build-item/scripts/review-gate.py"))


def parents_of(repo, c):
    return te.git_text(repo, "rev-list", "--parents", "-n", "1", c).split()[1:]


def message(repo, c):
    return te.git_text(repo, "log", "-1", "--format=%B", c)


def item_of(subject):
    m = ITEM.match(subject)
    return (m.group(1) or m.group(2)) if m else None


def files(repo, a, b):
    out = te.git(repo, "diff", "--name-only", "--no-renames", "-z", a, b).stdout
    return sorted(te.zlist(out.decode("utf-8", "surrogateescape")))


def auto_merge_tree(repo, parents):
    p = te.git(repo, "merge-tree", "--write-tree", "-z", parents[0], parents[1], check=False)
    tree = p.stdout.decode("utf-8", "surrogateescape").split("\0")[0].strip()
    if p.returncode not in (0, 1) or not re.fullmatch(r"[0-9a-f]{40,64}", tree):
        fail("git merge-tree --write-tree failed (git 2.38 or newer is needed)")
    return tree


def landed_head(repo, receipt_head, landed, first):
    """True when `landed` (a landing merge's second parent) is the receipt's head, or reaches it
    through clean refresh merges of train work that `first` (the landing's first parent) holds."""
    seen = 0
    while landed != receipt_head and seen < 50:
        ps = parents_of(repo, landed)
        if len(ps) != 2 or not te.is_ancestor(repo, ps[1], first) or te.merge_only_changes(repo, landed, ps):
            return False
        landed, seen = ps[0], seen + 1
    return landed == receipt_head


def engines_ok(receipt, need_cli):
    ok = [e["engine"] for e in receipt["engines"] if e["result"] != "failed"]
    return "claude" in ok and (not need_cli or any(e != "claude" for e in ok))


def analyse(repo, config, source_before, head, train):
    release = config.get("release") if isinstance(config.get("release"), dict) else {}
    source = release["releaseSource"] if "releaseSource" in release else "develop"
    if not isinstance(source, str) or not source:
        fail("config: release.releaseSource must be a non-empty string when present")
    review = config.get("review") if isinstance(config.get("review"), dict) else {}
    need_cli = isinstance(review.get("localCommand"), str) and review["localCommand"].strip() != ""
    routing = te.routing
    epic = (config.get("epicIntegrationBranches") or {}).get("pattern")
    plan = (config.get("planIntegrationBranches") or {}).get("pattern")
    regexes = [routing.template_regex(p, {}) for p in (plan, epic) if isinstance(p, str) and p]
    if not te.is_ancestor(repo, source_before, head):
        fail("--source-before %s is not an ancestor of --head %s: the range is wrong" % (source_before, head))
    origin_source, origin_train = "origin/" + source, "origin/" + train
    out = {"receipted": [], "covered": [], "unreviewed": []}

    def unreviewed(c, subject, why, a, b):
        out["unreviewed"].append({"commit": c, "item": item_of(subject), "why": why, "from": a, "to": b,
                                  "files": files(repo, a, b)})

    def unit(c, subject):
        found = te.merged_pull_request(repo, c, subject)
        for regex in regexes:
            if found and regex.match(found[1]):
                number = te.reviewed_unit(repo, c, found, regex, train)
                if number is not None:
                    return number
        return None

    def walk(commits):
        for c in commits:
            ps = parents_of(repo, c)
            if not ps:
                continue
            subject = te.git_text(repo, "log", "-1", "--format=%s", c).strip()
            if len(ps) == 1:
                unreviewed(c, subject, "a direct commit", ps[0], c)
                continue
            if len(ps) > 2:
                unreviewed(c, subject, "a merge of more than two parents", ps[0], c)
                continue
            if te.merge_only_changes(repo, c, ps):
                unreviewed(c, subject, "what the merge itself changed (a conflict resolution or a hand edit)",
                           auto_merge_tree(repo, ps), c)
            if te.is_ancestor(repo, ps[1], origin_source):
                out["covered"].append({"commit": c, "by": "the release source"})
                continue
            if te.is_ancestor(repo, c, origin_train):
                receipt = gate.parse_receipt(message(repo, c))
                if receipt and landed_head(repo, receipt["head"], ps[1], ps[0]) and engines_ok(receipt, need_cli):
                    out["receipted"].append({"commit": c, "item": item_of(subject), "head": receipt["head"],
                                             "cycles": receipt["cycles"], "engines": receipt["engines"]})
                    continue
                number = unit(c, subject)
                if number is not None:
                    out["covered"].append({"commit": c, "by": "pull request #%d" % number})
                    continue
                why = ("landed without a review receipt" if receipt is None else
                       "its receipt names %s, not the commit that landed" % receipt["head"][:12]
                       if not landed_head(repo, receipt["head"], ps[1], ps[0]) else
                       "its receipt shows no result from %s" % ("Claude and the CLI engine" if need_cli else "Claude"))
                unreviewed(c, subject, why, ps[0], c)
                continue
            if te.is_ancestor(repo, ps[1], origin_train):
                walk(te.git_text(repo, "rev-list", "--first-parent", "--reverse", ps[1], "^" + ps[0]).split())
                continue
            unreviewed(c, subject, "a merge of work that is not on the train", ps[0], c)

    walk(te.git_text(repo, "rev-list", "--first-parent", "--reverse", "%s..%s" % (source_before, head)).split())
    out["verdict"] = "needs-review" if out["unreviewed"] else "receipted"
    out["body"] = body(out)
    return out


def body(out):
    lines = ["Review receipts (every one-off reviewed before it landed):"]
    for r in out["receipted"]:
        lines.append("- %s, merge %s: LOCAL-FULL at %s, %d cycle(s), engines: %s" % (
            r["item"] or "no item", r["commit"][:10], r["head"][:12], r["cycles"],
            ", ".join("%s (%s)" % (e["engine"], e["result"].replace("-", " ")) for e in r["engines"])))
    if not out["receipted"]:
        lines.append("- none")
    if out["covered"]:
        lines.append("Covered by their own review:")
        lines += ["- merge %s: %s" % (c["commit"][:10], c["by"]) for c in out["covered"]]
    lines.append("Reviewed on this pull request (no receipt):" if out["unreviewed"] else "Nothing without a receipt.")
    for u in out["unreviewed"]:
        lines.append("- %s, %s %s: %s (%d file(s); git diff %s %s)" % (
            u["item"] or "no item", "commit", u["commit"][:10], u["why"], len(u["files"]), u["from"][:12], u["to"][:12]))
    return "\n".join(lines)


def main(argv):
    opts, i = {}, 0
    names = {"--config": "config", "--source-before": "source", "--head": "head", "--train": "train", "--repo": "repo"}
    while i < len(argv):
        if argv[i] not in names or i + 1 >= len(argv):
            fail("usage: train_receipts.py --config <file> --source-before <sha> --head <ref> [--train <branch>] [--repo <dir>]")
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
    train = opts.get("train") or te.routing.train_section(config).get("branch")
    if not isinstance(train, str) or not train:
        fail("no train branch: pass --train or set releaseTrain.branch")
    repo = opts.get("repo") or "."
    head = te.git(repo, "rev-parse", "--verify", "%s^{commit}" % opts["head"], check=False)
    if head.returncode != 0:
        fail("--head %s is not a commit" % opts["head"])
    out = analyse(repo, config, opts["source"], head.stdout.decode().strip(), train)
    sys.stdout.write(json.dumps(out, sort_keys=True) + "\n")
    return 1 if out["unreviewed"] else 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except Exception as err:  # never a traceback on the caller's screen
        sys.stderr.write("train_receipts: internal error: %s\n" % err)
        sys.exit(2)
