#!/usr/bin/env python3
"""May this release merge on the owner's standing yes? `release.lightRelease.standingYes` and
`release.fullRelease.standingYes`.

The rules are in `skills/release/references/auto-start.md`. Release step 4 runs this after its
pre-merge check and recap, with the evidence it already gathered; MERGE replaces the in-the-moment
yes, anything else goes to the owner exactly as before.

  standing-yes.py --pr <n> --head <sha> --class "<RELEASE CLASS line>"
                  --checks green|red --unresolved <count> --pre-ship "<PRE-SHIP verdict line>"
                  --pre-merge "<PRE-MERGE verdict line>" --previous-release <gate exit> --dev-deploy <exit>|not-applicable --tower "<status output>"
                  [--reviewed-head <sha>]   (the head release step 2 settled on: the full route)
      MERGE <head sha>          exit 0   (merge only that exact head: `gh pr merge --match-head-commit`)
      COMMENT <text>                     (second line after MERGE: the one comment to post on the pull request)
      ASK <reason>              exit 0   (the first condition that fails, in the order below)
      ERROR <reason>            exit 1   (bad arguments or an unreadable config: treat as ASK)

The configuration is read from the release head itself (`git show <head>:.claude/ds-config.json`),
never from the working folder: the consent has to be part of what was reviewed.

Two routes. A LIGHT release with the light standing yes on takes the light route; when that route
asks and the full standing yes is on, the full route decides (it also takes FULL releases). With
only the light yes on, its reason is the answer; with neither on, ASK.

The light route's MERGE needs ALL of, in this order:
  1. `release.lightRelease.standingYes` is true in the head's .claude/ds-config.json, and `release.clearance` is
     usable: `provider` `github` or `devstride` alone, or `commands` alone with claim, status,
     heartbeat, release and adopt each a non-empty string (only a live tower says who is On final),
     and `release.classifySkill` is a non-empty string (with no classifier, LIGHT is only a claim);
  2. the class line is exactly `RELEASE CLASS: LIGHT`;
  3. the pull request is OPEN into `release.productionBranch` (default master), --head is its
     CURRENT head (`gh pr view <pr>`, read here), and
     its tree equals the tree of the head the train review approved. That train is found here, never
     passed in: the latest merged release-train pull request into the release source, by the release
     skill's own search (both titles, `Release train:` and `Support train:`, each with its complete
     range marker `<!-- devstride:release-train source <sha> snapshot <sha> -->`, or the
     support-train spelling; the holder marker is not one), whose merge commit is an ancestor of --head; its `headRefOid` is the reviewed head;
  4. --checks is `green` (every required check on the head succeeded);
  5. --unresolved is 0 (the paginated unresolved-thread count);
  6. the pre-ship line is `PRE-SHIP: PASS (<n> ran, 0 waived)` or `PRE-SHIP: NOTHING TO RUN`, and
     the pre-merge line is `PRE-MERGE: CLEAR`, or `PRE-MERGE: NOT CONFIGURED` only when
     `release.preMergeSkill` is absent or null (HOLD and NOT RUN are the owner's decision);
  7. --previous-release is 0 (the previous-release gate);
  8. --dev-deploy is 0 (the dev-deploy wait, run BEFORE this check); `not-applicable` only when
     `release.devDeployVerification` is absent or null (any other value, an empty string included,
     is configured);
  9. the tower status has exactly one `On final:` line, and it reads `On final: #<pr> <head>` for
     this pull request (digits, then whitespace).

The full route (`release.fullRelease`: the owner's written standing yes for releases with every
gate green, any class) needs, in this order:
  F1. `release.fullRelease.standingYes` true, `ownerDecision` a real YYYY-MM-DD date not after
      today (the day the owner wrote the yes), `release.clearance` usable (as 1), and
      `migrationGlobs` a non-empty list of patterns (`branch-patterns.md` syntax);
  F2. the class line is `RELEASE CLASS: LIGHT` or `RELEASE CLASS: FULL`;
  F3. the pull request is OPEN into the production branch, not a draft, and at --head;
  F4. --reviewed-head is a full commit id (never a ref) and is --head, or an ancestor of it with
      the same tree (review's one empty re-trigger commit);
  F5. conditions 4 to 9 above;
  F6. every file matching `migrationGlobs` that the release adds or changes against
      `origin/<productionBranch>` (which must equal the pull request's live base; from their merge
      base, renames split, repository-root paths) has its content approved:
      its blob id at --head is the `blob` of an `approvedMigrations` entry (`{"blob", "path",
      "item", "approved"}`, written on the owner's own yes, dated no later than today). A deleted
      migration file, a file name with a control character, or an entry with a bad shape, asks.
      The helper cannot tell who wrote an entry: provenance is the owner's words, the entry's own
      commit and the recap and comment that name every approved migration a release carries. The same content under a new number (a renumber) stays
      approved; any change to the content needs a new approval.
"""
import argparse
import datetime
import importlib.util
import json
import os
import re
import subprocess
import sys


def say(line, code=0):
    print(line)
    sys.exit(code)


def load_config(head):
    """The release head's own .claude/ds-config.json; {} when that commit has none."""
    done = subprocess.run(["git", "show", "%s:.claude/ds-config.json" % head], capture_output=True, text=True)
    if done.returncode != 0:
        return {}
    try:
        loaded = json.loads(done.stdout)
    except ValueError as error:
        say("ERROR .claude/ds-config.json at %s cannot be read as JSON (%s)" % (head[:12], error), 1)
    return loaded if isinstance(loaded, dict) else {}


def pr_view(number):
    """`gh pr view <n>`: the live record of one pull request, or None."""
    try:
        done = subprocess.run(["gh", "pr", "view", str(number), "--json", "state,title,baseRefName,baseRefOid,headRefOid,isDraft"],
                              capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if done.returncode != 0:
        return None
    try:
        found = json.loads(done.stdout or "null")
    except ValueError:
        return None
    return found if isinstance(found, dict) else None


TRAIN_TITLES = (("Release train:", "release-train"), ("Support train:", "support-train"))


def has_range_marker(body, kind):
    """The complete range marker `<!-- devstride:<kind> source <sha> snapshot <sha> -->`, never a
    substring: the holder marker `devstride:release-train-holder` or prose naming it is not one."""
    return re.search(r"<!--\s*devstride:%s source [0-9a-f]{7,40} snapshot [0-9a-f]{7,40}\s*-->" % re.escape(kind),
                     body) is not None


def latest_train(source):
    """The latest merged release-train pull request into `source`, or None when gh cannot answer."""
    rows = []
    for title, _marker in TRAIN_TITLES:
        try:
            done = subprocess.run(["gh", "pr", "list", "--base", source, "--state", "merged", "--search",
                                   'in:title "%s" sort:created-desc' % title, "--json",
                                   "number,title,body,mergedAt,headRefOid,mergeCommit", "--limit", "50"],
                                  capture_output=True, text=True, timeout=60)
        except (OSError, subprocess.TimeoutExpired):
            return None
        if done.returncode != 0:
            return None
        try:
            found = json.loads(done.stdout or "[]")
        except ValueError:
            return None
        rows += [r for r in found if isinstance(r, dict)]
    trains = [r for r in rows if any(str(r.get("title", "")).startswith(t) and has_range_marker(str(r.get("body", "")), m)
                                     for t, m in TRAIN_TITLES) and r.get("mergedAt")]
    return max(trains, key=lambda r: str(r["mergedAt"])) if trains else {}


def is_ancestor(older, newer):
    return subprocess.run(["git", "merge-base", "--is-ancestor", older, newer], capture_output=True).returncode == 0


CLEARANCE_VERBS = ("claim", "status", "heartbeat", "release", "adopt")


def usable_clearance(clearance):
    if not isinstance(clearance, dict):
        return False
    provider, commands = clearance.get("provider"), clearance.get("commands")
    if provider is not None and commands is not None:
        return False
    if provider is not None:
        return provider in ("github", "devstride")
    return isinstance(commands, dict) and all(isinstance(commands.get(v), str) and commands[v].strip()
                                              for v in CLEARANCE_VERBS)


def full_sha(rev):
    done = subprocess.run(["git", "rev-parse", "--verify", "%s^{commit}" % rev], capture_output=True, text=True)
    return done.stdout.strip() if done.returncode == 0 else None


def tree_of(head):
    done = subprocess.run(["git", "rev-parse", "%s^{tree}" % head], capture_output=True, text=True)
    return done.stdout.strip() if done.returncode == 0 else None


class Parser(argparse.ArgumentParser):
    def error(self, message):
        say("ERROR %s" % message, 1)


class Ask(Exception):
    pass


def ask(cond, reason):
    if not cond:
        raise Ask(reason)


def open_at_head(number, head, production):
    """The live pull request, OPEN into production and at `head`; Ask otherwise."""
    found = pr_view(number)
    live = str(found.get("headRefOid") or "").strip() if found else ""
    ask(live, "the current head of pull request #%d cannot be read" % number)
    ask(found.get("state") == "OPEN" and found.get("baseRefName") == production,
        "pull request #%d is not open into %s (%s into %s)" % (number, production, found.get("state"), found.get("baseRefName")))
    ask(live == head, "pull request #%d is at %s, not the head %s this check was given" % (number, live[:12], head[:12]))
    return found


def gates(a, release):
    """Conditions 4 to 9: the evidence release step 4 gathered, the same for both routes."""
    ask(a.checks == "green", "a required check on the head is not green")
    ask(a.unresolved == 0, "%d review thread(s) unresolved" % a.unresolved)
    pre = a.pre_ship.strip()
    passed = re.match(r"^PRE-SHIP: PASS \((\d+) ran, (\d+) waived\)$", pre)
    ask(pre == "PRE-SHIP: NOTHING TO RUN" or (passed and passed.group(2) == "0"),
        "the pre-ship checks did not all pass unwaived (%s)" % (pre or "no verdict"))
    merge_check = a.pre_merge.strip()
    allowed = ("PRE-MERGE: CLEAR",) if release.get("preMergeSkill") is not None else ("PRE-MERGE: CLEAR", "PRE-MERGE: NOT CONFIGURED")
    ask(merge_check in allowed, "the pre-merge check did not clear (%s)" % (merge_check or "no verdict"))
    ask(a.previous_release == 0, "the previous-release gate answered %d, not 0" % a.previous_release)
    dev = a.dev_deploy.strip()
    configured = release.get("devDeployVerification") is not None
    ask(not (dev == "not-applicable" and configured), "release.devDeployVerification is configured: run the dev-deploy wait and pass its exit")
    ask(dev in ("0", "not-applicable"), "the dev-deploy wait answered %s, not 0" % (dev or "nothing"))
    finals = [line for line in a.tower.splitlines() if line.startswith("On final:")]
    parsed = re.match(r"^On final: #(\d+)\s+\S", finals[0]) if len(finals) == 1 else None
    ask(parsed and int(parsed.group(1)) == a.pr, "pull request #%d is not the one release On final in the tower status" % a.pr)


def light_route(a, head, release):
    classifier = release.get("classifySkill")
    ask(isinstance(classifier, str) and classifier.strip(), "no release.classifySkill is configured, so nothing has shown this release is light")
    ask(a.klass.strip() == "RELEASE CLASS: LIGHT", "not a light release (%s)" % (a.klass.strip() or "no class line"))
    open_at_head(a.pr, head, release.get("productionBranch") or "master")
    source = release.get("releaseSource") or "develop"
    train = latest_train(source)
    ask(train is not None, "the merged release-train pull requests into %s cannot be read" % source)
    ask(train, "no merged release-train pull request into %s: nothing reviewed to compare with" % source)
    merge = str((train.get("mergeCommit") or {}).get("oid") or "")
    ask(merge and is_ancestor(merge, head), "the latest train #%s is not merged into the head %s" % (train.get("number"), head[:12]))
    reviewed = tree_of(str(train.get("headRefOid") or ""))
    ask(reviewed is not None, "the reviewed train head of #%s cannot be read" % train.get("number"))
    tree = tree_of(head)
    ask(tree == reviewed, "the head's tree %s differs from the reviewed train tree %s" % (tree[:12], reviewed[:12]))
    gates(a, release)
    return "Merged on the standing yes for light releases identical to the reviewed train (release.lightRelease.standingYes)."


DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
BLOB = re.compile(r"^[0-9a-f]{40}([0-9a-f]{24})?$")
ITEM = re.compile(r"^I\d+$")
CONTROL = re.compile(r"[\x00-\x1f\x7f]")
SHA = re.compile(r"^[0-9a-f]{40}([0-9a-f]{24})?$")
SKILLS = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ROUTING = os.path.join(SKILLS, "build-item/scripts/routing.py")


def a_date(value):
    if not (isinstance(value, str) and DATE.match(value)):
        return None
    try:
        return datetime.date.fromisoformat(value)
    except ValueError:
        return None


def glob_matcher(patterns):
    """routing.py's one glob matcher (`branch-patterns.md`), never a second copy."""
    spec = importlib.util.spec_from_file_location("routing", ROUTING)
    routing = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(routing)

    def refuse(message):
        raise Ask("release.fullRelease.migrationGlobs: %s" % message)
    routing.fail = refuse
    return lambda path: routing.first_match(path, patterns) is not None


def approvals(full):
    entries = full.get("approvedMigrations", [])
    ask(isinstance(entries, list), "release.fullRelease.approvedMigrations must be a list")
    found = {}
    for i, e in enumerate(entries):
        ask(isinstance(e, dict) and isinstance(e.get("blob"), str) and BLOB.match(e["blob"])
            and isinstance(e.get("path"), str) and e["path"].strip()
            and isinstance(e.get("item"), str) and ITEM.match(e["item"]) and a_date(e.get("approved")),
            "release.fullRelease.approvedMigrations[%d] needs blob (the file's git blob id), path, item (I#####) and approved (YYYY-MM-DD)" % i)
        ask(a_date(e["approved"]) <= datetime.date.today(),
            "release.fullRelease.approvedMigrations[%d] is dated %s, after today: an approval is given, never planned" % (i, e["approved"]))
        found.setdefault(e["blob"], e)
    return found


def migrations(head, production, full, live_base):
    """The release's migration files, each approved by content; Ask names the first that is not."""
    is_migration = glob_matcher(full["migrationGlobs"])
    approved = approvals(full)
    base = full_sha("origin/%s" % production)
    ask(base, "origin/%s cannot be read: fetch it first" % production)
    ask(base == live_base, "origin/%s is at %s but the pull request's base is at %s: fetch it first"
        % (production, base[:12], (live_base or "unreadable")[:12]))
    done = subprocess.run(["git", "merge-base", base, head], capture_output=True, text=True)
    ask(done.returncode == 0, "no merge base between origin/%s and the head" % production)
    diff = subprocess.run(["git", "diff", "--name-status", "-z", "--no-renames", "--no-relative", "--no-ext-diff", done.stdout.strip(), head], capture_output=True)
    ask(diff.returncode == 0, "the release diff cannot be read")
    fields = diff.stdout.decode("utf-8", "surrogateescape").split("\0")
    shipped = []
    for status, path in zip(fields[0::2], fields[1::2]):
        ask(not CONTROL.search(path), "the release changes a file whose name holds a control character (%r): no glob can be trusted to classify it" % path)
        if not path or not is_migration(path):
            continue
        ask(status != "D", "the release deletes the migration %s" % path)
        blob = subprocess.run(["git", "rev-parse", "%s:%s" % (head, path)], capture_output=True, text=True).stdout.strip()
        entry = approved.get(blob)
        ask(entry, "the migration %s (blob %s) has no owner approval for this content" % (path, blob[:12] or "unreadable"))
        shipped.append("%s (%s, approved %s)" % (path, entry["item"], entry["approved"]))
    return shipped


def full_route(a, head, release, full):
    decided = a_date(full.get("ownerDecision"))
    ask(decided and decided <= datetime.date.today(),
        "release.fullRelease.ownerDecision must be the date the owner wrote the yes (YYYY-MM-DD, not in the future)")
    globs = full.get("migrationGlobs")
    ask(isinstance(globs, list) and globs and all(isinstance(g, str) and g.strip() for g in globs),
        "release.fullRelease.migrationGlobs must list the migration file patterns: without it no migration can be told apart")
    ask(a.klass.strip() in ("RELEASE CLASS: LIGHT", "RELEASE CLASS: FULL"), "no release class (%s)" % (a.klass.strip() or "no class line"))
    production = release.get("productionBranch") or "master"
    found = open_at_head(a.pr, head, production)
    ask(found.get("isDraft") is False, "pull request #%d is still a draft: CI has not run on the reviewed head" % a.pr)
    given = (a.reviewed_head or "").strip()
    ask(SHA.match(given), "no --reviewed-head as a full commit id: the full route needs the exact head release step 2 settled on, never a ref")
    reviewed = full_sha(given)
    ask(reviewed == given, "the reviewed head %s cannot be read" % given[:12])
    ask(reviewed == head or (is_ancestor(reviewed, head) and tree_of(reviewed) == tree_of(head)),
        "the head %s is not the reviewed head %s (or its same-tree re-trigger)" % (head[:12], reviewed[:12]))
    gates(a, release)
    shipped = migrations(head, production, full, str(found.get("baseRefOid") or "").strip())
    return ("Merged on the owner's written standing yes for releases with every gate green "
            "(release.fullRelease.standingYes, owner decision %s). Migrations: %s." % (full["ownerDecision"], "; ".join(shipped) or "none"))


def main():
    parser = Parser(prog="standing-yes.py")
    parser.add_argument("--pr", type=int, required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--class", dest="klass", required=True)
    parser.add_argument("--checks", choices=["green", "red"], required=True)
    parser.add_argument("--unresolved", type=int, required=True)
    parser.add_argument("--pre-ship", required=True)
    parser.add_argument("--pre-merge", required=True)
    parser.add_argument("--previous-release", type=int, required=True)
    parser.add_argument("--dev-deploy", required=True)
    parser.add_argument("--tower", required=True)
    parser.add_argument("--reviewed-head")
    a = parser.parse_args()

    head = full_sha(a.head)
    if head is None:
        say("ASK the head %s cannot be read" % a.head)
    config = load_config(head)
    release = config.get("release") if isinstance(config.get("release"), dict) else {}
    light = release.get("lightRelease")
    full = release.get("fullRelease")
    light_on = isinstance(light, dict) and light.get("standingYes") is True
    full_on = isinstance(full, dict) and full.get("standingYes") is True
    if not (light_on or full_on):
        say("ASK the standing yes is off (neither release.lightRelease.standingYes nor release.fullRelease.standingYes is true)")
    if not usable_clearance(release.get("clearance")):
        say("ASK no usable release.clearance is configured, so no tower can show this release On final")
    reason = None
    if light_on and (a.klass.strip() == "RELEASE CLASS: LIGHT" or not full_on):
        try:
            comment = light_route(a, head, release)
            say("MERGE %s\nCOMMENT %s" % (head, comment))
        except Ask as why:
            reason = str(why)
    if full_on:
        try:
            comment = full_route(a, head, release, full)
            say("MERGE %s\nCOMMENT %s" % (head, comment))
        except Ask as why:
            reason = str(why) if reason is None else "%s (light route: %s)" % (why, reason)
    say("ASK %s" % reason)


if __name__ == "__main__":
    main()
