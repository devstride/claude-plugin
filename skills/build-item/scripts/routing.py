#!/usr/bin/env python3
"""Where a leaf item lands, and what its branches are called — deterministic, dependency-free.

The single implementation of the routing rule in `skills/build-item/SKILL.md` ("Working base")
and `references/support-train.md`, and of the matching rule in
`skills/release/references/branch-patterns.md`. Claude follows those documents; any other agent
(Codex, a script, a person) runs this file and gets the same answer. A repository's own tooling
that re-implements the rule should run `routing-fixtures.json` beside it against itself.

Every subcommand reads one JSON object on stdin and writes one JSON object on stdout:

  match        {"name", "patterns":[…]}                        -> {"matches", "pattern"}
  prefix       {"userName"}                                   -> {"prefix"}
  slug         {"title", "words"?}                            -> {"slug"}
  branch-name  {"config", "item", "title"|"slug", "prefix", "date"} -> {"branch"}
  excluded     {"config", "files":[…]}                        -> {"excluded":[…]}
  target       {"config", "chain":[{"number","title","workType"}…], "heads":[…], "prefix", "date",
                "explicit"?, "changedFiles"?, "oneOff"?, "roles"?, "epicSlug"?}
               -> {"kind": explicit|integration|epic|train|base|ask|refuse, "branch"?, "create"?,
                   "candidates"?, "reason"}

`target` precedence: the item must be a leaf type (else refuse) → an explicit branch (refused when
it is the production branch or the release source, matches `protectedBranches` or
`release.releaseBranchPattern`, or is not on origin) → `integrationBranch` → for an item that is NOT a
one-off, the NEAREST release-unit ancestor's integration branch when `epicIntegrationBranches.enabled`
(one on origin → reuse; several → ask; none, but one in an older naming → ask; else create) → for a
one-off, the support train when `supportTrain.branch` is set AND `release.mergeTrainBeforeCut` is
true, unless a changed file matches `release.releaseBranchFixExclusions` (then the base branch, by
its own pull request) → `baseBranch`. `create: true` means: create it on origin off `baseBranch`.

`oneOff` is the caller's classification — pass it whenever you know it (build-item's one-off mode
always does: a one-off under an Epic still never uses that epic's branch); absent, an item with no
release-unit ancestor is a one-off. `roles` ({"leaf":[…], "releaseUnit"}) carries the roles resolved
from the organization's work-type hierarchy and is used only when the config has no
`hierarchyRoles`; neither → an error, never a guess. `epicSlug` is the epic's title slug under the
repository's `epicIntegrationBranches.slugRule`; absent, the title is kebab-cased to six words.

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
    train = section(config, "supportTrain").get("branch")
    blocked = [f for f in files if first_match(f, release.get("releaseBranchFixExclusions") or [])]

    def landing(kind, branch, create, reason):
        # Deploy configuration and migrations never ride the train, however the train was chosen.
        if train and branch == train and blocked:
            return {"kind": "base", "branch": base, "create": False,
                    "reason": "it touches %s, which never rides the support train" % ", ".join(blocked)}
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
        reason += " (support train set, but releases do not merge it)"
    return {"kind": "base", "branch": base, "create": False, "reason": reason}


def main():
    if len(sys.argv) != 2:
        fail("usage: routing.py match|prefix|slug|branch-name|excluded|target < request.json")
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
    else:
        fail("unknown subcommand %r" % command)
    sys.stdout.write(json.dumps(out, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
