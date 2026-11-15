#!/usr/bin/env python3
"""Whether a branch carries a migration the owner has not approved — before it joins the release
train or the base branch. Deterministic, standard library and git only, no network.

The rules are in `skills/release/references/migration-approval.md`. The reading of the migration
diff, the globs and the approvals is `standing-yes.py`'s own (beside this file), never a copy: this
script asks the release's question about any head against any base, earlier.

  check --base <ref> --head <ref> [--already <ref>]…
      Reads `.claude/ds-config.json` as committed at <head>. Considers only the files that differ
      between <head> and its merge base with <base> and match `release.fullRelease.migrationGlobs`.
      A migration whose content is already at an `--already` ref (the release train, the
      production branch) is not joining anything and is not asked about: the release's own
      check covers what was there before.
      stdout, one JSON object:
        {"applies": bool, "approved": bool, "reason": "<one plain line>",
         "unapproved": [{"path", "blob", "status": "new"|"changed"|"deleted"|"not-a-file"}]}
      exit 0  approved, or not applicable (no written standing yes for full releases, no
              migrationGlobs, or `release.fullRelease.approveBeforeJoining` false)
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
import contextlib
import datetime
import importlib.util
import io
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
UNIT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,199}$")
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
    """An ISO time with an offset, as UTC; None when it is not one."""
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return parsed.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def settings(sy, head):
    """`release.fullRelease` at `head` when the early question applies, else (None, why not)."""
    said = io.StringIO()
    try:
        with contextlib.redirect_stdout(said):  # its own ERROR line belongs in our one JSON answer
            config = sy.load_config(head)
    except SystemExit:
        raise Unanswerable(said.getvalue().strip().replace("ERROR ", "", 1)
                           or ".claude/ds-config.json at %s cannot be read as JSON" % head[:12])
    release = config.get("release") if isinstance(config.get("release"), dict) else {}
    full = release.get("fullRelease")
    if not (isinstance(full, dict) and full.get("standingYes") is True):
        return None, "no written standing yes for full releases: the release itself asks"
    globs = full.get("migrationGlobs")
    if not (isinstance(globs, list) and globs and all(isinstance(g, str) and g.strip() for g in globs)):
        return None, "release.fullRelease.migrationGlobs names no migration files: the release itself asks"
    if full.get("approveBeforeJoining") is False:
        return None, "release.fullRelease.approveBeforeJoining is false: the release itself asks"
    return full, ""


def already_there(sy, refs, status, path, blob):
    """Whether one of `refs` already holds this migration as `head` has it (or, deleted, lacks it)."""
    for ref in refs:
        there = subprocess.run(["git", "rev-parse", "--verify", "-q", "%s:%s" % (ref, path)], capture_output=True, text=True)
        if (status == "D" and there.returncode != 0) or (status != "D" and there.returncode == 0 and there.stdout.strip() == blob):
            return True
    return False


def check(base, head, already=()):
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
    full, why_not = settings(sy, head_sha)
    if full is None:
        return {"applies": False, "approved": True, "reason": why_not, "unapproved": []}
    try:
        approved = sy.approvals(full)
        changed = sy.changed_migrations(base_sha, head_sha, sy.glob_matcher(full["migrationGlobs"]), base)
    except sy.Ask as asked:
        raise Unanswerable(str(asked))
    unapproved = []
    for status, path, mode, blob in changed:
        if already_there(sy, there, status, path, blob):
            continue
        if status == "D":
            unapproved.append({"path": path, "blob": "", "status": "deleted"})
        elif mode not in ("100644", "100755"):
            unapproved.append({"path": path, "blob": blob, "status": "not-a-file"})
        elif blob not in approved:
            unapproved.append({"path": path, "blob": blob, "status": STATUS.get(status, "changed")})
    if unapproved:
        names = ", ".join("%s (%s)" % (u["path"], u["status"]) for u in unapproved)
        reason = "%d migration%s without the owner's approval for this content: %s" % (
            len(unapproved), "" if len(unapproved) == 1 else "s", names)
    elif changed:
        reason = "every migration this branch adds or changes is approved by content (%d)" % len(changed)
    else:
        reason = "this branch adds or changes no migration"
    return {"applies": True, "approved": not unapproved, "reason": reason, "unapproved": unapproved}


def entry(a):
    sy = standing_yes()
    if not sy.ITEM.match(a.item):
        raise ValueError("--item must be an item number (I#####)")
    if not UNIT.match(a.unit):
        raise ValueError("--unit must be an item number or a branch name")
    asked = instant(a.asked)
    approved = instant(a.approved) if a.approved else datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if not asked or not approved:
        raise ValueError("--asked and --approved must be ISO times with an offset")
    if asked > approved:
        raise ValueError("--asked is after --approved")
    if sy.CONTROL.search(a.path) or not a.path.strip():
        raise ValueError("--path is not a usable file name")
    head = sy.full_sha(a.head)
    if not head:
        raise ValueError("%s is not a commit in this checkout" % a.head)
    listed = subprocess.run(["git", "ls-tree", "-z", head, "--", a.path], capture_output=True).stdout.decode("utf-8", "surrogateescape")
    mode = listed.split(" ", 1)[0] if listed else ""
    if mode not in ("100644", "100755"):
        raise ValueError("%s is not a plain file at %s" % (a.path, head[:12]))
    blob = subprocess.run(["git", "rev-parse", "%s:%s" % (head, a.path)], capture_output=True, text=True).stdout.strip()
    return {
        # The date is the owner's day, as approvedMigrations has always carried it.
        "entry": {"blob": blob, "path": a.path, "item": a.item, "approved": datetime.date.today().isoformat()},
        "subject": "chore(release): approve migration %s [%s]" % (a.path, a.item),
        "trailers": ["Migration-Approval-Unit: %s" % a.unit,
                     "Migration-Approval-Asked: %s" % asked,
                     "Migration-Approval-Approved: %s" % approved],
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
    e = verbs.add_parser("entry")
    for name in ("--head", "--path", "--item", "--unit", "--asked"):
        e.add_argument(name, required=True)
    e.add_argument("--approved")
    a = parser.parse_args(argv[1:])
    if a.verb == "check":
        try:
            answer = check(a.base, a.head, a.already)
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
