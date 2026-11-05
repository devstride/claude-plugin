#!/usr/bin/env python3
"""Where a leaf item lands, and what its branches are called — deterministic, dependency-free.

The single implementation of the routing rule in `skills/build-item/SKILL.md` ("Working base")
and `references/release-train.md`, and of the matching rule in
`skills/release/references/branch-patterns.md`. Claude follows those documents; any other agent
(Codex, a script, a person) runs this file and gets the same answer. A repository's own tooling
that re-implements the rule should run `routing-fixtures.json` beside it against itself.

Every subcommand reads one JSON object on stdin and writes one JSON object on stdout:

  match        {"name", "patterns":[…]}                        -> {"matches", "pattern"}
  prefix       {"userName"}                                   -> {"prefix"}
  slug         {"title", "words"?}                            -> {"slug"}
  branch-name  {"config", "item", "title"|"slug", "prefix", "date"} -> {"branch"}
  excluded     {"config", "files":[…]}                        -> {"excluded":[…]}
  small        {"config", "numstat"}                          -> {"small", "files", "lines", "riskFiles":[…]}
  target       {"config", "chain":[{"number","title","workType"}…], "heads":[…], "prefix", "date",
                "explicit"?, "changedFiles"?, "oneOff"?, "roles"?, "epicSlug"?}
               -> {"kind": explicit|integration|epic|train|base|ask|refuse, "branch"?, "create"?,
                   "candidates"?, "reason"}
  release-target {"config", "chain":[{…, "releaseScope"?}…], "heads", "prefix", "date", "roles"?, "planSlug"?}
               -> {"kind": plan|train|base|named|ask|refuse, "branch"?, "create"?, "from"?, "candidates"?, "reason"}
  epic-base    the same request -> {"kind": plan|base|ask|refuse, "branch"?, "candidates"?, "reason"}

`target` precedence: the item must be a leaf type (else refuse) → an explicit branch (refused when
it is the production branch or the release source, matches `protectedBranches` or
`release.releaseBranchPattern`, or is not on origin) → `integrationBranch` → for an item that is NOT a
one-off, the NEAREST release-unit ancestor's integration branch when `epicIntegrationBranches.enabled`
(one on origin → reuse; several → ask; none, but one in an older naming → ask; else create) → for a
one-off, the release train when `releaseTrain.branch` (or, by its old name, `supportTrain.branch`) is set AND `release.mergeTrainBeforeCut` is
true, unless a changed file matches `release.releaseBranchFixExclusions` (then the base branch, by
its own pull request) → `baseBranch`. `create: true` means: create it on origin off `baseBranch`.

`oneOff` is the caller's classification — pass it whenever you know it (build-item's one-off mode
always does: a one-off under an Epic still never uses that epic's branch); absent, an item with no
release-unit ancestor is a one-off. `roles` ({"leaf":[…], "releaseUnit"}) carries the roles resolved
from the organization's work-type hierarchy and is used only when the config has no
`hierarchyRoles`; neither → an error, never a guess. `epicSlug` is the epic's title slug under the
repository's `epicIntegrationBranches.slugRule`; absent, the title is kebab-cased to six words.

`release-target` says where a release unit's release pull request goes, and `epic-base` what a NEW
integration branch for it is cut from. `chain` runs from the item (a leaf or the release unit) up to
the root; an entry's `releaseScope` is the text after `Release scope:` in that item's description,
absent when the description has no such line (read the description in full — a summary omits it).
The NEAREST marker above the release unit decides, case-insensitively: `plan` makes that ancestor the
plan root, `epic` (or no marker anywhere) is the default, anything else is refused. Default: the
release goes to `epicIntegrationBranches.releaseTarget` (`baseBranch`, the default, is the base
branch; the release train is created off it when missing) and new integration branches are cut from
the base branch. Plan scope: the release goes to the plan's integration branch
(`planIntegrationBranches.pattern`, found and named as an epic's is; `planSlug` is the plan root's
title slug, absent the title is kebab-cased to six words), created off `from` — the default release
target, which is also where the whole plan is released — and a new integration branch is cut from the
plan branch once it exists, else from the base branch.

`small` says whether a one-off on the release train is a SMALL fix (`references/release-train.md`):
`numstat` is the text of `git diff --numstat -z --no-renames origin/<train>...HEAD` (NUL-separated,
so paths arrive unquoted). It must arrive intact: a non-empty value that does not end in NUL was cut
or had its NULs dropped on the way (a shell variable does both), and is refused. Pipe it straight
into the request (`references/release-train.md` gives the command). Small means
`releaseTrain.smallFixes` is set, the diff changes at most `maxFiles` files and at most
`maxChangedLines` lines (added plus removed), holds no binary file, and touches no path matching
`release.productionReview.highRiskPaths` or `release.releaseBranchFixExclusions`. An empty diff is
not small: there is nothing to batch.

`config` is the repository's `.claude/ds-config.json` (only the keys below are read). `chain` runs
from the item itself up to the root, each entry carrying its work-type NAME (a workstream has
none). `heads` is the list of branch names on origin (`git ls-remote --heads origin`). `prefix` is
the first name of `git config user.name`, lowercased; `date` is today in `branchNaming.dateFormat`.
Nothing here touches git or the network: the caller gathers the facts, this decides.

Malformed input is an error on stderr (`routing: …`) with exit 2 — never a traceback.
"""
import json
import re
import sys


def fail(msg):
    sys.stderr.write("routing: %s\n" % msg)
    sys.exit(2)


# ── the matching rule (branch-patterns.md) ──

DATE_TOKEN = re.compile(r"^<[A-Z]{2}-[A-Z]{2}-[A-Z]{2}>")


def pattern_regex(pattern):
    """Anchored at both ends; `*` one path segment (>=1 char), `**` across segments (>=1 char),
    a date token two digits-hyphen-two digits-hyphen-two digits, a trailing `[-n]` an optional
    hyphen-and-digits, everything else literal."""
    if not isinstance(pattern, str) or not pattern:
        fail("a pattern must be a non-empty string")
    source, rest = "", pattern
    while rest:
        if rest.startswith("**"):
            source, rest = source + ".+", rest[2:]
        elif rest.startswith("*"):
            source, rest = source + "[^/]+", rest[1:]
        elif rest == "[-n]":
            source, rest = source + "(-[0-9]+)?", ""
        elif DATE_TOKEN.match(rest):
            source, rest = source + "[0-9]{2}-[0-9]{2}-[0-9]{2}", DATE_TOKEN.sub("", rest, count=1)
        else:
            source, rest = source + re.escape(rest[0]), rest[1:]
    return re.compile("^" + source + "$")


def first_match(name, patterns):
    if not isinstance(name, str) or not isinstance(patterns, list):
        fail("a name must be a string and patterns a list")
    for pattern in patterns:
        if pattern_regex(pattern).match(name):
            return pattern
    return None


# ── names ──

def slugify(title, words=6):
    if not isinstance(title, str):
        fail("a title must be a string")
    text = re.sub(r"^\s*\[[0-9.]+\]\s*", "", title or "").lower()
    parts = [p for p in re.sub(r"[^a-z0-9]+", " ", text).strip().split() if p][:words]
    if not parts:
        fail("cannot make a slug from %r — pass one" % title)
    return "-".join(parts)


def user_prefix(user_name):
    words = (user_name or "").strip().split()
    prefix = re.sub(r"[^a-z0-9-]", "", words[0].lower()) if words else ""
    if not prefix:
        fail("git config user.name is empty — set it, it names your branches")
    return prefix


def fill(template, values):
    def token(m):
        name = m.group(1)
        if name not in values:
            fail("unknown token <%s> in %r" % (name, template))
        return values[name]
    return re.sub(r"<([^<>]+)>", token, template)


def template_regex(template, fixed):
    """A configured name template as an anchored expression: `fixed` tokens match exactly, a date
    token its digits, any other token one path segment."""
    def token(m):
        name = m.group(1)
        if name in fixed:
            return re.sub(r"[*\[\]<>]", "", fixed[name])
        return m.group(0) if re.match(r"^[A-Z]{2}-[A-Z]{2}-[A-Z]{2}$", name) else "*"
    return pattern_regex(re.sub(r"<([^<>]+)>", token, template))


def date_token(template):
    m = re.search(r"<([A-Z]{2}-[A-Z]{2}-[A-Z]{2})>", template)
    return m.group(1) if m else None


# ── config ──

def section(config, key):
    value = config.get(key)
    return value if isinstance(value, dict) else {}


def train_section(config):
    """The train's settings: `releaseTrain`, or — when only the old name is present — `supportTrain`.
    A config carrying both is malformed (exit 2): which one wins would be a guess."""
    if isinstance(config.get("releaseTrain"), dict) and isinstance(config.get("supportTrain"), dict):
        fail("config: both releaseTrain and supportTrain are set — supportTrain is the old name of "
             "releaseTrain; keep releaseTrain only")
    new = section(config, "releaseTrain")
    return new if new else section(config, "supportTrain")


def need(value, what):
    if not isinstance(value, str) or not value:
        fail("config: %s is missing" % what)
    return value


def feature_branch(config, item, slug, prefix, date):
    pattern = need(section(config, "branchNaming").get("pattern"), "branchNaming.pattern")
    values = {"prefix": prefix, "I#####": item, "slug": slug}
    token = date_token(pattern)
    if token:
        values[token] = date
    return fill(pattern, values)


def epic_branch_candidates(config, epic_number, epic_slug, heads):
    """This epic's integration branches on origin: those matching the configured pattern (keyed on
    the epic number, or — only when the pattern has none — on `epic_slug()`, a function so a title
    with no usable slug still finds a number-keyed branch), and —
    so an epic cut under an earlier naming is found and never given a second branch — any other
    head whose LAST path segment starts `<epic-number>-` or `epic-<epic-number>-` (with or
    without the `epic-` marker, any prefix or date shape)."""
    pattern = need(section(config, "epicIntegrationBranches").get("pattern"), "epicIntegrationBranches.pattern")
    key = {"epic-number": epic_number} if "<epic-number>" in pattern else {"epic-title-slug": epic_slug()}
    current = template_regex(pattern, key)
    found = [h for h in heads if current.match(h)]
    starts = (epic_number + "-", "epic-" + epic_number + "-")
    older = [h for h in heads if h not in found and h.rsplit("/", 1)[-1].startswith(starts)]
    return pattern, found, older


def plan_branch_candidates(config, plan_number, plan_slug, heads):
    """The plan's integration branches on origin, found exactly as `epic_branch_candidates` finds an
    epic's: by the configured pattern (keyed on the plan number, or on `plan_slug()` when the
    pattern has none), and any other head whose LAST path segment starts `plan-<plan-number>-`."""
    pattern = need(section(config, "planIntegrationBranches").get("pattern"), "planIntegrationBranches.pattern")
    key = {"plan-number": plan_number} if "<plan-number>" in pattern else {"plan-title-slug": plan_slug()}
    current = template_regex(pattern, key)
    found = [h for h in heads if current.match(h)]
    older = [h for h in heads if h not in found and h.rsplit("/", 1)[-1].startswith("plan-" + plan_number + "-")]
    return pattern, found, older


def positive(value, what):
    if not isinstance(value, int) or isinstance(value, bool) or value < 1:
        fail("config: %s must be a positive whole number" % what)
    return value


def cmd_small(req):
    config = req.get("config")
    if not isinstance(config, dict):
        fail("small: config must be an object")
    numstat = req.get("numstat")
    if not isinstance(numstat, str):
        fail("small: numstat must be the text of git diff --numstat")
    if numstat and not numstat.endswith("\0"):
        fail("small: numstat does not end in NUL — it was cut or lost its NULs on the way; pipe git diff --numstat -z straight in")
    limits = train_section(config).get("smallFixes")
    if limits is None:
        return {"small": False, "files": 0, "lines": 0, "riskFiles": [], "reason": "releaseTrain.smallFixes is not set"}
    if not isinstance(limits, dict):
        fail("config: releaseTrain.smallFixes must be an object")
    max_files = positive(limits.get("maxFiles"), "releaseTrain.smallFixes.maxFiles")
    max_lines = positive(limits.get("maxChangedLines"), "releaseTrain.smallFixes.maxChangedLines")
    release = section(config, "release")
    risky = list(section(release, "productionReview").get("highRiskPaths") or []) + list(release.get("releaseBranchFixExclusions") or [])
    paths, lines, binary = [], 0, []
    for row in numstat.split("\0"):
        row = row.strip("\n")
        if not row:
            continue
        parts = row.split("\t", 2)
        if len(parts) != 3:
            fail("small: %r is not a numstat line" % row)
        added, removed, path = parts
        paths.append(path)
        if added == "-" or removed == "-":
            binary.append(path)
        elif added.isdigit() and removed.isdigit():
            lines += int(added) + int(removed)
        else:
            fail("small: %r is not a numstat line" % row)
    risk = [f for f in paths if first_match(f, risky)]
    out = {"files": len(paths), "lines": lines, "riskFiles": risk}
    if not paths:
        reason = "the diff is empty"
    elif risk:
        reason = "it touches %s, on the high-risk list" % ", ".join(risk)
    elif binary:
        reason = "it changes a binary file (%s)" % ", ".join(binary)
    elif len(paths) > max_files:
        reason = "%d files, over the %d-file limit" % (len(paths), max_files)
    elif lines > max_lines:
        reason = "%d changed lines, over the %d-line limit" % (lines, max_lines)
    else:
        reason = "%d file(s), %d changed line(s)" % (len(paths), lines)
        return dict(out, small=True, reason=reason)
    return dict(out, small=False, reason=reason)


# ── subcommands ──

def cmd_target(req):
    config = req.get("config")
    if not isinstance(config, dict):
        fail("target: config must be an object")
    chain, heads = req.get("chain"), req.get("heads") or []
    if not isinstance(chain, list) or not chain or not all(isinstance(n, dict) for n in chain):
        fail("target: chain must be a non-empty list of {number, title, workType} objects")
    if not isinstance(heads, list) or not all(isinstance(h, str) for h in heads):
        fail("target: heads must be a list of branch names")
    base = need(config.get("baseBranch"), "baseBranch")
    roles = section(config, "hierarchyRoles") or (req.get("roles") if isinstance(req.get("roles"), dict) else {})
    leaf, unit = roles.get("leaf"), roles.get("releaseUnit")
    if not isinstance(leaf, list) or not leaf or not isinstance(unit, str) or not unit:
        fail("target: no hierarchyRoles in config — pass roles {leaf, releaseUnit} resolved from the work-type hierarchy")
    item = chain[0]
    if item.get("workType") not in leaf:
        return {"kind": "refuse", "reason": "%s is %s, not one of %s" % (
            item.get("number"), item.get("workType") or "a workstream", " / ".join(leaf))}
    release = section(config, "release")
    files = req.get("changedFiles") or []
    if not isinstance(files, list) or not all(isinstance(f, str) for f in files):
        fail("target: changedFiles must be a list of paths")
    train = train_section(config).get("branch")
    blocked = [f for f in files if first_match(f, release.get("releaseBranchFixExclusions") or [])]

    def landing(kind, branch, create, reason):
        # Deploy configuration and migrations never ride the train, however the train was chosen.
        if train and branch == train and blocked:
            return {"kind": "base", "branch": base, "create": False,
                    "reason": "it touches %s, which never rides the release train" % ", ".join(blocked)}
        return {"kind": kind, "branch": branch, "create": create, "reason": reason}

    explicit = req.get("explicit")
    if explicit:
        exact = [release.get("productionBranch"), release.get("releaseSource")]
        patterns = list(config.get("protectedBranches") or []) + [p for p in [release.get("releaseBranchPattern")] if p]
        if explicit in exact or first_match(explicit, patterns):
            return {"kind": "refuse", "reason": "%s is a protected branch — work never lands on it directly" % explicit}
        if explicit not in heads:
            return {"kind": "refuse", "reason": "%s does not exist on origin" % explicit}
        return landing("explicit", explicit, False, "named by the caller")
    if config.get("integrationBranch"):
        return landing("integration", config["integrationBranch"], False, "integrationBranch is set")
    epic = next((n for n in chain[1:] if n.get("workType") == unit), None)
    if "oneOff" in req and not isinstance(req["oneOff"], bool):
        fail("target: oneOff must be true or false")
    one_off = req["oneOff"] if "oneOff" in req else epic is None
    epic_slug = req.get("epicSlug")
    if epic_slug is not None and (not isinstance(epic_slug, str) or not epic_slug):
        fail("target: epicSlug must be a non-empty string")
    if not one_off and epic and section(config, "epicIntegrationBranches").get("enabled") is True:
        number = need(epic.get("number"), "chain[].number")
        slug = lambda: epic_slug or slugify(epic.get("title", ""))
        pattern, found, legacy = epic_branch_candidates(config, number, slug, heads)
        if len(found) == 1:
            return {"kind": "epic", "branch": found[0], "create": False, "reason": "its %s %s" % (unit, number)}
        if found:
            return {"kind": "ask", "candidates": sorted(found),
                    "reason": "%s %s has several integration branches" % (unit, number)}
        if legacy:
            return {"kind": "ask", "candidates": sorted(legacy),
                    "reason": "%s %s already has an integration branch in the older naming" % (unit, number)}
        values = {"prefix": need(req.get("prefix"), "prefix"), "epic-number": number}
        if "<epic-title-slug>" in pattern:
            values["epic-title-slug"] = slug()
        token = date_token(pattern)
        if token:
            values[token] = need(req.get("date"), "date")
        return {"kind": "epic", "branch": fill(pattern, values), "create": True,
                "reason": "its %s %s, on a new integration branch" % (unit, number)}
    if not one_off:
        return {"kind": "base", "branch": base, "create": False,
                "reason": "%s integration branches are off" % unit if epic else "not a one-off, and no %s above it" % unit}
    if train and release.get("mergeTrainBeforeCut") is True:
        return landing("train", train, train not in heads, "a one-off")
    reason = "a one-off"
    if train:
        reason += " (release train set, but releases do not merge it)"
    return {"kind": "base", "branch": base, "create": False, "reason": reason}


def scope_request(req, command):
    """What `release-target` and `epic-base` share: the checked request, the release unit the item
    belongs to, and the nearest `Release scope:` marker ABOVE it. Returns (facts, None) or
    (None, a refusal)."""
    config = req.get("config")
    if not isinstance(config, dict):
        fail("%s: config must be an object" % command)
    chain, heads = req.get("chain"), req.get("heads") or []
    if not isinstance(chain, list) or not chain or not all(isinstance(n, dict) for n in chain):
        fail("%s: chain must be a non-empty list of {number, title, workType, releaseScope?} objects" % command)
    if not isinstance(heads, list) or not all(isinstance(h, str) for h in heads):
        fail("%s: heads must be a list of branch names" % command)
    for n in chain:
        if n.get("releaseScope") is not None and not isinstance(n["releaseScope"], str):
            fail("%s: chain[].releaseScope must be the marker's text" % command)
    base = need(config.get("baseBranch"), "baseBranch")
    roles = section(config, "hierarchyRoles") or (req.get("roles") if isinstance(req.get("roles"), dict) else {})
    unit = roles.get("releaseUnit")
    if not isinstance(unit, str) or not unit:
        fail("%s: no hierarchyRoles in config — pass roles {leaf, releaseUnit} resolved from the work-type hierarchy" % command)
    at = next((i for i, n in enumerate(chain) if n.get("workType") == unit), None)
    if at is None:
        return None, {"kind": "refuse", "reason": "%s has no %s above it, and only a %s is released" % (
            chain[0].get("number"), unit, unit)}
    marked = next((n for n in chain[at + 1:] if n.get("releaseScope") is not None), None)
    value = marked["releaseScope"].strip().lower() if marked else "epic"
    if value not in ("plan", "epic"):
        return None, {"kind": "refuse", "reason": "%s says \"Release scope: %s\" — the value is plan or epic" % (
            marked.get("number"), marked["releaseScope"].strip())}
    facts = {"config": config, "heads": heads, "base": base, "unit": unit, "epic": chain[at],
             "root": marked if value == "plan" else None}
    if facts["root"] and section(config, "epicIntegrationBranches").get("enabled") is not True:
        return None, {"kind": "refuse", "reason": "%s releases as a plan, which needs %s integration branches, "
                      "and they are off" % (marked.get("number"), unit)}
    return facts, None


def epic_release_target(facts):
    """Where an epic's release goes without plan scope: `epicIntegrationBranches.releaseTarget`
    (`baseBranch`, the default, means the base branch itself)."""
    config, base = facts["config"], facts["base"]
    named = section(config, "epicIntegrationBranches").get("releaseTarget")
    branch = base if named in (None, "baseBranch") else named
    train = train_section(config).get("branch")
    if train and branch == train:
        return {"kind": "train", "branch": train, "create": train not in facts["heads"], "from": base,
                "reason": "epicIntegrationBranches.releaseTarget is the release train"}
    if branch == base:
        return {"kind": "base", "branch": base, "create": False, "from": base, "reason": "the base branch"}
    return {"kind": "named", "branch": branch, "create": False, "from": branch,
            "reason": "epicIntegrationBranches.releaseTarget names %s" % branch}


def plan_branch(facts, req):
    root = facts["root"]
    number = need(root.get("number"), "chain[].number")
    plan_slug = req.get("planSlug")
    if plan_slug is not None and (not isinstance(plan_slug, str) or not plan_slug):
        fail("planSlug must be a non-empty string")
    slug = lambda: plan_slug or slugify(root.get("title", ""))
    pattern, found, older = plan_branch_candidates(facts["config"], number, slug, facts["heads"])
    if len(found) == 1:
        return {"branch": found[0], "create": False}
    if found:
        return {"kind": "ask", "candidates": sorted(found), "reason": "plan %s has several integration branches" % number}
    if older:
        return {"kind": "ask", "candidates": sorted(older),
                "reason": "plan %s already has an integration branch in another naming" % number}
    values = {"prefix": need(req.get("prefix"), "prefix"), "plan-number": number}
    if "<plan-title-slug>" in pattern:
        values["plan-title-slug"] = slug()
    token = date_token(pattern)
    if token:
        values[token] = need(req.get("date"), "date")
    return {"branch": fill(pattern, values), "create": True}


def cmd_release_target(req):
    facts, refusal = scope_request(req, "release-target")
    if refusal:
        return refusal
    target = epic_release_target(facts)
    if not facts["root"] or target["kind"] == "refuse":
        return target
    found = plan_branch(facts, req)
    if "kind" in found:
        return found
    # The plan branch is cut from, and the whole plan is released to, where the epic would have gone.
    return {"kind": "plan", "branch": found["branch"], "create": found["create"], "from": target["branch"],
            "reason": "plan %s releases as one unit (Release scope: plan)" % facts["root"].get("number")}


def cmd_epic_base(req):
    facts, refusal = scope_request(req, "epic-base")
    if refusal:
        return refusal
    if facts["root"]:
        found = plan_branch(facts, req)
        if "kind" in found:
            return found
        if not found["create"]:
            return {"kind": "plan", "branch": found["branch"],
                    "reason": "plan %s's integration branch" % facts["root"].get("number")}
        return {"kind": "base", "branch": facts["base"],
                "reason": "plan %s has no integration branch yet" % facts["root"].get("number")}
    return {"kind": "base", "branch": facts["base"], "reason": "the base branch"}


def main():
    if len(sys.argv) != 2:
        fail("usage: routing.py match|prefix|slug|branch-name|excluded|target|release-target|epic-base|small < request.json")
    try:
        req = json.load(sys.stdin)
    except ValueError as error:
        fail("stdin is not JSON (%s)" % error)
    if not isinstance(req, dict):
        fail("stdin must be a JSON object")
    command = sys.argv[1]
    if command == "match":
        pattern = first_match(need(req.get("name"), "name"), req.get("patterns") or [])
        out = {"matches": pattern is not None, "pattern": pattern}
    elif command == "prefix":
        out = {"prefix": user_prefix(req.get("userName"))}
    elif command == "slug":
        words = req.get("words", 6)
        if not isinstance(words, int) or isinstance(words, bool) or words < 1:
            fail("slug: words must be a positive whole number")
        out = {"slug": slugify(req.get("title", ""), words)}
    elif command == "branch-name":
        config = req.get("config") or {}
        slug = req.get("slug") or slugify(req.get("title", ""))
        out = {"branch": feature_branch(config, need(req.get("item"), "item"), slug,
                                        need(req.get("prefix"), "prefix"), need(req.get("date"), "date"))}
    elif command == "excluded":
        exclusions = section(req.get("config") or {}, "release").get("releaseBranchFixExclusions") or []
        files = req.get("files") or []
        if not isinstance(files, list):
            fail("excluded: files must be a list")
        out = {"excluded": [f for f in files if first_match(f, exclusions)]}
    elif command == "target":
        out = cmd_target(req)
    elif command == "release-target":
        out = cmd_release_target(req)
    elif command == "epic-base":
        out = cmd_epic_base(req)
    elif command == "small":
        out = cmd_small(req)
    else:
        fail("unknown subcommand %r" % command)
    sys.stdout.write(json.dumps(out, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
