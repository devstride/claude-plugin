#!/usr/bin/env python3
"""Whether a branch carries a migration the owner has not approved — before it joins the release
train or the base branch. Deterministic, standard library and git only, no network.

The rules are in `skills/release/references/migration-approval.md`. The reading of the migration
diff, the globs and the approvals is `standing-yes.py`'s own (beside this file), never a copy: this
script asks the release's question about any head against any base, earlier.

  check --base <ref> --head <ref> [--already <ref>]… [--rule <policy.json>]
      The RULE (whether the early question applies, and which files are migrations) is read from
      `.claude/ds-config.json` as committed at <base>, or from `--rule` when a caller has already
      read the base's policy (the merge gate, from GitHub); the APPROVALS from the one committed at
      <head>. Nothing is read from the work tree. Considers only the files that differ between
      <head> and its merge base with <base> and match `release.fullRelease.migrationGlobs`.
      A plain file whose content is already at an `--already` ref (the release train, the
      production branch) is not joining anything and is not asked about; a deletion only when
      that ref made it. The release's own check covers what was there before.
      stdout, one JSON object:
        {"applies": bool, "approved": bool, "reason": "<one plain line>",
         "unapproved": [{"path", "blob", "status": "new"|"changed"|"deleted"|"not-a-file"}]}
      exit 0  approved, or not applicable (the base has no config, no written standing yes for
              full releases, no migrationGlobs, or `release.fullRelease.approveBeforeJoining` false)
      exit 2  one or more migrations have no approval for their content
      exit 1  the question could not be answered (a ref that is not a commit here, unreadable
              config or approvals); wherever a merge would follow, treat it as unapproved
  entry --head <ref> --path <file> --item I##### --unit <unit> --asked <ISO time> [--approved <ISO time>]
      What an approval records, built, never typed. stdout, one JSON object:
        {"entry": {"blob", "path", "item", "approved"},      (for approvedMigrations)
         "subject": "chore(release): approve migration <path> [I#####]",
         "trailers": ["Migration-Approval-Unit: …", "Migration-Approval-Asked: …",
                      "Migration-Approval-Approved: …"]}
      The trailers are the hold record: which unit waited for the owner's yes, from when, until
      when, readable from git history alone
      (`git log --format='%(trailers:key=Migration-Approval-Unit,valueonly)'`).
      exit 2 with one `migration-approval:` line when the file is not a plain file at <head> or an
      argument is malformed.
"""
import argparse
import datetime
import importlib.util
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
UNIT = re.compile(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,199}")
STATUS = {"A": "new", "D": "deleted"}


def standing_yes():
    """standing-yes.py, the one reader of migration globs, diffs and approvals."""
    sys.dont_write_bytecode = True  # leave no compiled file in the plugin directory
    spec = importlib.util.spec_from_file_location("standing_yes", os.path.join(HERE, "standing-yes.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Unanswerable(Exception):
    pass


def instant(value):
    """An ISO time with an offset, as an aware datetime; None when it is not one."""
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo else None


def stamp(moment):
    return moment.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def tree_entry(ref, path):
    """(mode, blob) of `path` at `ref`, from the repository root; ("", "") when it is not there;
    Unanswerable when git cannot say."""
    done = subprocess.run(["git", "ls-tree", "-z", "--full-tree", ref, "--", path], capture_output=True)
    if done.returncode != 0:
        raise Unanswerable("%s could not be looked up at %s" % (path, ref[:12]))
    listed = done.stdout.decode("utf-8", "surrogateescape")
    if not listed:
        return "", ""
    # Exactly the entry named: a folder lists its children, and none of them is the file asked about.
    records = [r for r in listed.split("\0") if r]
    if len(records) != 1 or "\t" not in records[0] or records[0].split("\t", 1)[1] != path:
        return "", ""
    fields = records[0].split("\t", 1)[0].split(" ")
    return (fields[0], fields[2]) if len(fields) == 3 else ("", "")


def committed_config(ref, name):
    """`.claude/ds-config.json` as committed at `ref`: a dict, or None when that commit has none.
    A file that is there but cannot be read as a JSON object is never "no config"."""
    mode, _ = tree_entry(ref, ".claude/ds-config.json")
    if not mode:
        return None
    done = subprocess.run(["git", "show", "%s:.claude/ds-config.json" % ref], capture_output=True, text=True)
    if done.returncode != 0:
        raise Unanswerable(".claude/ds-config.json at %s cannot be read" % name)
    try:
        loaded = json.loads(done.stdout)
    except ValueError as error:
        raise Unanswerable(".claude/ds-config.json at %s cannot be read as JSON (%s)" % (name, error))
    if not isinstance(loaded, dict):
        raise Unanswerable(".claude/ds-config.json at %s is not a JSON object" % name)
    return loaded


def full_release(config):
    release = config.get("release") if isinstance(config, dict) and isinstance(config.get("release"), dict) else {}
    return release.get("fullRelease") if isinstance(release.get("fullRelease"), dict) else {}


def rule(base_config):
    """The base branch's own rule: (migration globs, "") when the early question applies there,
    else (None, why not). The branch being asked about never decides this for itself."""
    full = full_release(base_config)
    if full.get("standingYes") is not True:
        return None, "no written standing yes for full releases on the base: the release itself asks"
    globs = full.get("migrationGlobs")
    if not (isinstance(globs, list) and globs and all(isinstance(g, str) and g.strip() for g in globs)):
        return None, "release.fullRelease.migrationGlobs names no migration files on the base: the release itself asks"
    if full.get("approveBeforeJoining") is False:
        return None, "release.fullRelease.approveBeforeJoining is false on the base: the release itself asks"
    return globs, ""


def already_there(refs, base_sha, status, path, blob):
    """Whether one of `refs` already holds this migration as `head` has it. A deletion counts only
    with evidence that the ref itself made it: the file is gone there and was there where the ref
    and the base last met."""
    for ref in refs:
        mode, there = tree_entry(ref, path)
        if status != "D":
            if mode in ("100644", "100755") and there == blob:
                return True
            continue
        if mode:
            continue
        met = subprocess.run(["git", "merge-base", ref, base_sha], capture_output=True, text=True)
        if met.returncode == 0 and tree_entry(met.stdout.strip(), path)[0]:
            return True
    return False


def given_rule(path):
    """A policy handed in by the caller (the merge gate's reading of the base branch): a dict."""
    try:
        with open(path) as f:
            loaded = json.load(f)
    except (OSError, ValueError) as error:
        raise Unanswerable("the policy %s cannot be read (%s)" % (path, error))
    if not isinstance(loaded, dict):
        raise Unanswerable("the policy %s is not a JSON object" % path)
    return loaded


def check(base, head, already=(), rule_file=None):
    sy = standing_yes()
    head_sha, base_sha = sy.full_sha(head), sy.full_sha(base)
    if not head_sha:
        raise Unanswerable("%s is not a commit in this checkout: fetch it first" % head)
    if not base_sha:
        raise Unanswerable("%s is not a commit in this checkout: fetch it first" % base)
    there = []
    for ref in already:
        sha = sy.full_sha(ref)
        if not sha:
            raise Unanswerable("%s is not a commit in this checkout: fetch it first" % ref)
        there.append(sha)
    # The RULE is the base branch's, as committed there: a branch cut before the rule, or one that
    # edits it, is still asked. The APPROVALS are the head's, so an approval travels with the work.
    globs, why_not = rule(given_rule(rule_file) if rule_file else committed_config(base_sha, base))
    if globs is None:
        return {"applies": False, "approved": True, "reason": why_not, "unapproved": []}
    try:
        approved = sy.approvals(full_release(committed_config(head_sha, head)))
        changed = list(sy.changed_migrations(base_sha, head_sha, sy.glob_matcher(globs), base))
    except sy.Ask as asked:
        raise Unanswerable(str(asked))
    unapproved = []
    for status, path, mode, blob in changed:
        if status == "D":
            if not already_there(there, base_sha, status, path, blob):
                unapproved.append({"path": path, "blob": "", "status": "deleted"})
        elif mode not in ("100644", "100755"):
            unapproved.append({"path": path, "blob": blob, "status": "not-a-file"})  # never excused: no content is pinned
        elif blob not in approved and not already_there(there, base_sha, status, path, blob):
            unapproved.append({"path": path, "blob": blob, "status": STATUS.get(status, "changed")})
    if unapproved:
        names = ", ".join("%s (%s)" % (u["path"], u["status"]) for u in unapproved)
        reason = "%d migration%s without the owner's approval for this content: %s" % (
            len(unapproved), "" if len(unapproved) == 1 else "s", names)
    elif changed:
        reason = "every migration this branch adds or changes is approved by content or already there (%d)" % len(changed)
    else:
        reason = "this branch adds or changes no migration"
    return {"applies": True, "approved": not unapproved, "reason": reason, "unapproved": unapproved}


def entry(a):
    sy = standing_yes()
    if not sy.ITEM.fullmatch(a.item):
        raise ValueError("--item must be an item number (I#####)")
    if not UNIT.fullmatch(a.unit):
        raise ValueError("--unit must be an item number or a branch name")
    now = datetime.datetime.now(datetime.timezone.utc)
    asked = instant(a.asked)
    approved = instant(a.approved) if a.approved else now
    if not asked or not approved:
        raise ValueError("--asked and --approved must be ISO times with an offset")
    if asked > approved:
        raise ValueError("--asked is after --approved")
    if approved > now:
        raise ValueError("--approved is in the future: an approval is given, never planned")
    if sy.CONTROL.search(a.path) or not a.path.strip():
        raise ValueError("--path is not a usable file name")
    head = sy.full_sha(a.head)
    if not head:
        raise ValueError("%s is not a commit in this checkout" % a.head)
    try:
        mode, blob = tree_entry(head, a.path)
    except Unanswerable as why:
        raise ValueError(str(why))
    if mode not in ("100644", "100755"):
        raise ValueError("%s is not a plain file at %s" % (a.path, head[:12]))
    return {
        # The day of the approval where this machine is, which is what the release's check compares
        # with its own today.
        "entry": {"blob": blob, "path": a.path, "item": a.item, "approved": approved.astimezone().date().isoformat()},
        "subject": "chore(release): approve migration %s [%s]" % (a.path, a.item),
        "trailers": ["Migration-Approval-Unit: %s" % a.unit,
                     "Migration-Approval-Asked: %s" % stamp(asked),
                     "Migration-Approval-Approved: %s" % stamp(approved)],
    }


class Parser(argparse.ArgumentParser):
    def error(self, message):
        sys.stderr.write("migration-approval: %s\n" % message)
        sys.exit(2)


def main(argv):
    os.environ["GIT_NO_REPLACE_OBJECTS"] = "1"  # every git read sees the real objects
    parser = Parser(prog="migration-approval.py")
    verbs = parser.add_subparsers(dest="verb")
    c = verbs.add_parser("check")
    c.add_argument("--base", required=True)
    c.add_argument("--head", required=True)
    c.add_argument("--already", action="append", default=[])
    c.add_argument("--rule")
    e = verbs.add_parser("entry")
    for name in ("--head", "--path", "--item", "--unit", "--asked"):
        e.add_argument(name, required=True)
    e.add_argument("--approved")
    a = parser.parse_args(argv[1:])
    if a.verb == "check":
        try:
            answer = check(a.base, a.head, a.already, a.rule)
        except Unanswerable as why:
            print(json.dumps({"applies": True, "approved": False, "reason": str(why), "unapproved": []}))
            return 1
        print(json.dumps(answer))
        return 0 if answer["approved"] else 2
    if a.verb == "entry":
        try:
            print(json.dumps(entry(a)))
        except ValueError as why:
            sys.stderr.write("migration-approval: %s\n" % why)
            return 2
        return 0
    parser.error("usage: migration-approval.py check|entry …")


if __name__ == "__main__":
    sys.exit(main(sys.argv))
