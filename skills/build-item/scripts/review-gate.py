#!/usr/bin/env python3
"""May this landing go onto the release train? The one gate for a one-off's fast merge.

The single implementation of the rule in `references/release-train.md` ("A larger or riskier fix
gets its full review before it lands"): a train one-off lands when it is a small fix (`routing.py
small`, never a second copy of that rule), or when a LOCAL-FULL review (`review` skill) settled at
exactly this head. `build-item` 5a runs `check` before every fast merge onto the train; any other
tool that lands one-offs (a repository's own CLI) runs this file, never a copy. No network.

  check   stdin {"base", "head"?, "targetKind"?, "config"?, "receiptsDir"?,
                 "numstat"?, "tree"?, "mergeBase"?}
          stdout {"verdict": "small"|"reviewed"|"not-applicable", "files", "lines", "riskFiles",
                  "reason", "mergeBody"}
  record  stdin {"base", "head"?, "cycles", "engines": [...], "findings": [{"id", "severity",
                 "disposition", "note"?}], "config"?, "receiptsDir"?, "tree"?, "mergeBase"?}
                 (tree, mergeBase and config together, with head, or all from git)
          stdout {"receipt", "mergeBody"}

`base` is the ref the one-off lands on (e.g. `origin/train/release`); `head` defaults to `HEAD`.
Run in the repository: the config (`.claude/ds-config.json`), the diff
(`git diff --numstat -z --no-renames <base>...<head>`), the head's tree and the merge base come
from git unless the request supplies `config`, `numstat`, `tree` and `mergeBase` (all four
together, with `head`: the fixtures' git-free mode).

`check`:
- `targetKind` other than "train" (default "train") -> `not-applicable`: epic stories get their full
  review at the epic's release pull request.
- `releaseTrain.smallFixes` not set -> `not-applicable`: the repository set no size rule.
- `small: true` -> `small`.
- else a receipt for this head whose tree and merge base match, and which is itself settled (the
  same rules `record` applies) -> `reviewed`.
- else exit 2, one line naming the review to run. Never merge on a non-zero exit.

`record` (LOCAL-FULL, once it settled) writes the receipt `<receiptsDir>/<head>.json`; receiptsDir
defaults to `<git common dir>/devstride/reviews/local-full`, shared by every worktree of the
repository on this machine and never committed. It refuses a finding still open, an engine list
without `claude` (or, with `review.localCommand` set, with nothing but `claude`), or fewer than one
cycle. A receipt is evidence for exactly one head, tree and
merge base: any new commit, or a train merged into the branch, needs a new review.

Exit 0 with an answer, 2 with one `review-gate: <reason>` line on stderr, 1 for anything else.
"""
import importlib.util
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROUTING = os.path.join(HERE, "routing.py")
CLOSED = ("fixed", "dismissed", "refuted", "deferred", "captured")
SHA = re.compile(r"^[0-9a-f]{40}([0-9a-f]{24})?$")


class Refuse(Exception):
    pass


def need(cond, reason):
    if not cond:
        raise Refuse(reason)


def text(value):
    return isinstance(value, str) and value.strip() != ""


def git(*args):
    p = subprocess.run(["git"] + list(args), capture_output=True)
    need(p.returncode == 0, "git %s failed: %s" % (" ".join(args[:3]), p.stderr.decode("utf-8", "replace").strip()[:200]))
    return p.stdout.decode("utf-8", "surrogateescape")


def small_rule(config, numstat):
    spec = importlib.util.spec_from_file_location("routing", ROUTING)
    routing = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(routing)

    def refuse(msg):
        raise Refuse(msg.replace("small: ", "", 1))
    routing.fail = refuse
    return routing.cmd_small({"config": config, "numstat": numstat})


def subject(req, with_diff=True):
    need(isinstance(req, dict), "the request must be a JSON object")
    need(text(req.get("base")), "base is required: the ref the one-off lands on")
    keys = ("numstat", "tree", "mergeBase", "config") if with_diff else ("tree", "mergeBase", "config")
    pure = [k for k in keys if k in req]
    if pure:
        need(len(pure) == len(keys) and text(req.get("head")), "%s come together, with head" % ", ".join(keys))
        for key in ("head", "tree", "mergeBase"):
            need(SHA.match(req[key] or ""), "%s must be a full commit or tree id" % key)
        need(not with_diff or isinstance(req["numstat"], str), "numstat must be the text of git diff --numstat -z")
        return req["head"], req["tree"], req["mergeBase"], req.get("numstat")
    head = git("rev-parse", "--verify", "%s^{commit}" % (req.get("head") or "HEAD")).strip()
    tree = git("rev-parse", "%s^{tree}" % head).strip()
    base = git("rev-parse", "--verify", "%s^{commit}" % req["base"]).strip()
    merge_base = git("merge-base", base, head).strip()
    numstat = git("diff", "--numstat", "-z", "--no-renames", "%s...%s" % (base, head)) if with_diff else None
    return head, tree, merge_base, numstat


def config_of(req):
    if "config" in req:
        need(isinstance(req["config"], dict), "config must be an object")
        return req["config"]
    root = git("rev-parse", "--show-toplevel").strip()
    path = os.path.join(root, ".claude", "ds-config.json")
    try:
        with open(path) as f:
            config = json.load(f)
    except (OSError, ValueError) as err:
        raise Refuse("cannot read %s: %s" % (path, err))
    need(isinstance(config, dict), "%s is not a JSON object" % path)
    return config


def receipts_dir(req):
    if "receiptsDir" in req:
        need(text(req["receiptsDir"]), "receiptsDir must be a path")
        return req["receiptsDir"]
    common = git("rev-parse", "--path-format=absolute", "--git-common-dir").strip()
    return os.path.join(common, "devstride", "reviews", "local-full")


def settled(r, config):
    """The receipt's own claims: a settled LOCAL-FULL review. Raises Refuse naming what is wrong."""
    need(isinstance(r, dict) and r.get("schema") == 1 and r.get("mode") == "LOCAL-FULL", "not a schema-1 LOCAL-FULL receipt")
    cycles, engines, findings = r.get("cycles"), r.get("engines"), r.get("findings")
    need(isinstance(cycles, int) and not isinstance(cycles, bool) and cycles >= 1, "cycles must be a whole number, at least 1")
    need(isinstance(engines, list) and engines and all(text(e) for e in engines), "engines must list the engines that ran")
    need("claude" in engines, "engines must include claude: LOCAL-FULL always runs the Claude review")
    review = config.get("review") if isinstance(config.get("review"), dict) else {}
    need(not text(review.get("localCommand")) or any(e != "claude" for e in engines),
         "engines must include the configured CLI engine (review.localCommand): a Claude-only LOCAL-FULL is never recorded")
    need(isinstance(findings, list), "findings must be a list (empty when there were none)")
    clean = []
    for f in findings:
        need(isinstance(f, dict) and text(f.get("id")) and text(f.get("severity")), "each finding needs an id and a severity")
        need(f.get("disposition") in CLOSED, "finding %s is %r: settle it first (%s)" % (f.get("id"), f.get("disposition"), ", ".join(CLOSED)))
        note = f.get("note")
        need(note is None or (isinstance(note, str) and "\n" not in note and len(note) <= 200), "finding %s: note must be one line of at most 200 characters" % f["id"])
        clean.append({k: f[k] for k in ("id", "severity", "disposition", "note") if f.get(k) is not None})
    return clean


def body(receipt):
    lines = ["Review: LOCAL-FULL at %s over %s (merge base %s), %d cycle(s), engines: %s" % (
        receipt["head"], receipt["base"], receipt["mergeBase"][:12], receipt["cycles"], ", ".join(receipt["engines"]))]
    for f in receipt["findings"]:
        lines.append("- %s %s %s%s" % (f["id"], f["severity"], f["disposition"], ": " + f["note"] if f.get("note") else ""))
    if not receipt["findings"]:
        lines.append("- no findings")
    return "\n".join(lines)


def check(req):
    head, tree, merge_base, numstat = subject(req)
    kind = req.get("targetKind", "train")
    need(text(kind), "targetKind must be a routing kind")
    if kind != "train":
        return {"verdict": "not-applicable", "files": 0, "lines": 0, "riskFiles": [],
                "reason": "a %s landing gets its full review at its release pull request" % kind, "mergeBody": ""}
    config = config_of(req)
    small = small_rule(config, numstat)
    shape = {"files": small["files"], "lines": small["lines"], "riskFiles": small["riskFiles"]}
    if small["reason"] == "releaseTrain.smallFixes is not set":
        return dict(shape, verdict="not-applicable", reason="releaseTrain.smallFixes is not set: no size rule",
                    mergeBody="")
    if small["small"]:
        return dict(shape, verdict="small", reason=small["reason"],
                    mergeBody="Review: small fix (%s), covered by the train's release review" % small["reason"])
    path = os.path.join(receipts_dir(req), head + ".json")
    try:
        with open(path) as f:
            receipt = json.load(f)
    except OSError:
        receipt = None
    except ValueError:
        raise Refuse("the receipt %s is not JSON: delete it and review again" % path)
    run = "run /devstride:review local-full %s" % req["base"]
    if receipt is None:
        raise Refuse("not a small fix (%s) and no LOCAL-FULL review settled at %s: %s" % (small["reason"], head[:12], run))
    need(isinstance(receipt, dict) and receipt.get("head") == head, "the receipt %s names another head: %s" % (path, run))
    need(receipt.get("tree") == tree and receipt.get("mergeBase") == merge_base,
         "the LOCAL-FULL review at %s covered another diff (tree or merge base changed): %s" % (head[:12], run))
    try:
        settled(receipt, config)
    except Refuse as err:
        raise Refuse("the receipt %s is not a settled LOCAL-FULL review (%s): %s" % (path, err, run))
    return dict(shape, verdict="reviewed", reason="%s; LOCAL-FULL settled at %s" % (small["reason"], head[:12]),
                mergeBody=body(receipt))


def record(req):
    head, tree, merge_base, _ = subject(req, with_diff=False)
    receipt = {"schema": 1, "mode": "LOCAL-FULL", "base": req["base"], "head": head, "tree": tree, "mergeBase": merge_base,
               "cycles": req.get("cycles"), "engines": req.get("engines"), "findings": req.get("findings")}
    receipt["findings"] = settled(receipt, config_of(req))
    folder = receipts_dir(req)
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, head + ".json")
    with open(path + ".tmp", "w") as f:
        json.dump(receipt, f, indent=1, ensure_ascii=False)
    os.replace(path + ".tmp", path)
    return {"receipt": path, "mergeBody": body(receipt)}


def main(argv):
    commands = {"check": check, "record": record}
    if len(argv) != 2 or argv[1] not in commands:
        sys.stderr.write("review-gate: usage: review-gate.py check|record < request.json\n")
        return 2
    try:
        request = json.loads(sys.stdin.read())
    except ValueError as err:
        sys.stderr.write("review-gate: the request is not JSON: %s\n" % err)
        return 2
    try:
        result = commands[argv[1]](request)
    except Refuse as err:
        sys.stderr.write("review-gate: %s\n" % str(err).replace("\n", " "))
        return 2
    sys.stdout.write(json.dumps(result, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as err:  # never a traceback on the caller's screen
        sys.stderr.write("review-gate: internal error: %s\n" % err)
        sys.exit(1)
