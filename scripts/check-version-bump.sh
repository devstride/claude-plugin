#!/bin/bash
# scripts/check-version-bump.sh — a change to shipped files must arrive with a version bump.
#
# Why: `version` in .claude-plugin/plugin.json is the install cache key. A shipped change that
# is published without a bump is invisible to every installed copy, and it fails silently — the
# source looks right and no user sees it. This check makes the bump mechanical: run it against the
# base the change will land on.
#
# Where the plugin lives: the plugin directory is the one this script sits in (or --plugin-dir),
# and it may be the root of its git repository or a subdirectory of a larger one. Every path is
# read relative to that directory and only changes inside it count.
#
# The base: `--base` (default origin/master) is what was last published. While that ref does not
# hold the plugin directory yet, the base is the newest commit reachable from the head whose
# subject starts `plugin import` (the first import, or a later re-sync from the published
# repository), so several changes add up to one version above the imported one. The first line
# printed says which base was used.
#
# Rules, checked from the base to `<head>`:
#   1. If any shipped file changed — any path outside the inert maintainer files (root documents,
#      scripts/) that BOTH this checkout's skills/update/scripts/update-plugin.py and the one at the
#      base list, other than a version-only edit of .claude-plugin/plugin.json — the head
#      version must be greater than the base version (numeric semver compare). The updater applies
#      that same intersection to a commit after a release, so "ships nothing" means one thing in both.
#   2. If the version changed, CHANGELOG.md must carry a `## [<version>]` heading and
#      README.md's `Current version:` line must name it.
#   3. For each `--in-flight <ref>` (repeatable): a branch whose version is already on its way to
#      release but not published yet, such as the branch releases are cut from or a release
#      branch under review. A version above the base can belong to such a release, so it is not
#      this change's to add to: if any shipped file changed between that ref's merge base with
#      the head and the head, the head version must be above the version at that ref. A ref
#      holding `*` is a pattern matched against remote-tracking and local branches (for example
#      'origin/release/*'). A ref that does not exist, or does not hold the plugin, is skipped.
#      The branch checked out is never compared with itself: when it is one of those refs (a
#      review fix on a release branch or a release-train snapshot, by its local name or its
#      origin/ copy), that one is left out and every other in-flight ref still counts.
#   4. If the version changed, every step of every workflow in workflows/ that the grouped
#      release-steps skill serves must have its reference (skills/release-steps/references/<mode>.md,
#      the mode being the contract name without its major), so no version ships a release step
#      the skill cannot serve.
# Release tags are not consulted: the publisher owns them.
#
# Usage: check-version-bump.sh [--base <ref>] [--head <ref>] [--in-flight <ref>]... [--plugin-dir <dir>]
#        exit 0 ok, 1 violation, 2 usage
set -u
BASE="origin/master"; HEAD_REF="HEAD"; PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"; IN_FLIGHT=""
VB_HELPER="$PLUGIN_DIR/skills/update/scripts/update-plugin.py"; export VB_HELPER
while [ $# -gt 0 ]; do
  case "$1" in
    --base) [ $# -ge 2 ] || { echo "check-version-bump: --base needs a value" >&2; exit 2; }; BASE="$2"; shift 2 ;;
    --head) [ $# -ge 2 ] || { echo "check-version-bump: --head needs a value" >&2; exit 2; }; HEAD_REF="$2"; shift 2 ;;
    --plugin-dir) [ $# -ge 2 ] || { echo "check-version-bump: --plugin-dir needs a value" >&2; exit 2; }; PLUGIN_DIR="$2"; shift 2 ;;
    --in-flight) [ $# -ge 2 ] && [ -n "$2" ] || { echo "check-version-bump: --in-flight needs a value" >&2; exit 2; }
      IN_FLIGHT="$IN_FLIGHT$2
"; shift 2 ;;
    -h|--help) awk 'NR>1 && !/^#/{exit} NR>1{print}' "$0"; exit 0 ;;
    *) echo "check-version-bump: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$BASE" ] || { echo "check-version-bump: --base needs a value" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "check-version-bump: python3 is required" >&2; exit 2; }
[ -f "$VB_HELPER" ] || { echo "check-version-bump: missing $VB_HELPER" >&2; exit 2; }
# Work from the plugin directory: `<ref>:./<path>` and `git diff --relative` then mean "inside the
# plugin", whether it is the repository root or a subdirectory.
cd "$PLUGIN_DIR" 2>/dev/null || { echo "check-version-bump: no such plugin directory: $PLUGIN_DIR" >&2; exit 2; }
PREFIX="$(git rev-parse --show-prefix 2>/dev/null)" || { echo "check-version-bump: not a git repository" >&2; exit 2; }
git rev-parse --verify -q "$BASE^{commit}" >/dev/null || { echo "check-version-bump: unknown ref: $BASE" >&2; exit 2; }
git rev-parse --verify -q "$HEAD_REF^{commit}" >/dev/null || { echo "check-version-bump: unknown ref: $HEAD_REF" >&2; exit 2; }
MB="$(git merge-base "$BASE" "$HEAD_REF")" || { echo "check-version-bump: no merge base between $BASE and $HEAD_REF" >&2; exit 2; }
if git cat-file -e "$MB:./.claude-plugin/plugin.json" 2>/dev/null; then
  echo "base: $BASE (merge base $(git rev-parse --short "$MB"))"
else
  # The base does not hold the plugin yet: fall back to the newest import commit. --grep matches
  # any line of a message, so the subject is tested again, anchored.
  IMPORT="$(git log --format='%H %s' --grep='^plugin import' "$HEAD_REF" | awk '$2 == "plugin" && $3 ~ /^import/ { print $1; exit }')"
  [ -n "$IMPORT" ] || { echo "check-version-bump: $BASE has no ${PREFIX}.claude-plugin/plugin.json and no commit whose subject starts 'plugin import' is reachable from $HEAD_REF" >&2; exit 2; }
  MB="$IMPORT"
  echo "base: plugin import commit $(git rev-parse --short "$MB") ($BASE has no ${PREFIX:-./}.claude-plugin/plugin.json yet)"
fi
# The in-flight refs, patterns expanded, each with its merge base with the head: one
# `<ref> <merge base>` line each. A missing ref, or one with no merge base, is left out.
IN_FLIGHT_BASES=""
OWN="$(git symbolic-ref -q --short HEAD 2>/dev/null || true)"
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  case "$ref" in
    *'*'*) names="$(git for-each-ref --format='%(refname:short)' "refs/remotes/$ref" "refs/heads/$ref")" ;;
    *) names="$ref" ;;
  esac
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ -n "$OWN" ] && { [ "$name" = "$OWN" ] || [ "$name" = "origin/$OWN" ]; }; then
      echo "in flight: $name is this branch; not compared with itself"
      continue
    fi
    git rev-parse --verify -q "$name^{commit}" >/dev/null || continue
    fmb="$(git merge-base "$name" "$HEAD_REF" 2>/dev/null)" || continue
    IN_FLIGHT_BASES="$IN_FLIGHT_BASES$name $fmb
"
  done <<EOF
$names
EOF
done <<EOF
$IN_FLIGHT
EOF
export VB_MB="$MB" VB_HEAD="$HEAD_REF" VB_IN_FLIGHT="$IN_FLIGHT_BASES"
python3 - <<'PY'
import importlib.util, json, os, re, subprocess, sys
MB, HEAD = os.environ["VB_MB"], os.environ["VB_HEAD"]
spec = importlib.util.spec_from_file_location("update_plugin", os.environ["VB_HELPER"])
helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
def sh(*a):
    return subprocess.run(["git", *a], capture_output=True, text=True).stdout
def version_at(ref):
    try:
        return json.loads(sh("show", "%s:./.claude-plugin/plugin.json" % ref)).get("version", "")
    except Exception:
        return ""
def semver(v):
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", v or "")
    return tuple(int(x) for x in m.groups()) if m else None
base_v, head_v = version_at(MB), version_at(HEAD)
problems = []
if semver(head_v) is None:
    problems.append("head version %r is not MAJOR.MINOR.PATCH" % head_v)
# The release this change follows decides what is inert, intersected with this checkout's list —
# exactly what the updater applies to a commit after that release.
base_files, base_dirs = helper.parse_inert(sh("show", "%s:./skills/update/scripts/update-plugin.py" % MB))
inert = lambda p: helper.is_inert(p) and (p in base_files or p.startswith(base_dirs))
# -z and --no-renames: an escaped path reads as the path it is, and a skill moved into scripts/
# still lists the shipped path it removes. An undecodable path counts as shipped. --relative and
# the `.` pathspec keep the diff to the plugin directory and name each path from it.
def shipped_since(start):
    raw = subprocess.run(["git", "diff", "--no-renames", "--name-only", "-z", "--relative", start, HEAD, "--", "."], capture_output=True).stdout
    changed = []
    for p in raw.split(b"\0"):
        if p:
            try:
                changed.append(p.decode("utf-8"))
            except UnicodeDecodeError:
                changed.append("(undecodable) " + p.decode("utf-8", "replace"))
    files = [f for f in changed if not inert(f) and f != ".claude-plugin/plugin.json"]
    if ".claude-plugin/plugin.json" in changed:
        # a version-only edit is the bump itself, not a shipped change
        d = sh("diff", "--relative", start, HEAD, "--", ".claude-plugin/plugin.json")
        body = [l for l in d.splitlines() if (l.startswith("+") or l.startswith("-")) and not l.startswith(("+++", "---"))]
        if any('"version"' not in l for l in body):
            files.append(".claude-plugin/plugin.json")
    return files
shipped = shipped_since(MB)
bumped = head_v != base_v
if shipped and not bumped:
    problems.append("shipped files changed without a version bump (still %s): %s" % (head_v, ", ".join(shipped[:8]) + (" …" if len(shipped) > 8 else "")))
if bumped and semver(head_v) and semver(base_v) and semver(head_v) <= semver(base_v):
    problems.append("version went from %s to %s — it must increase" % (base_v, head_v))
if bumped and semver(head_v):
    changelog = sh("show", "%s:./CHANGELOG.md" % HEAD)
    if not re.search(r"^## \[%s\]" % re.escape(head_v), changelog, re.M):
        problems.append("CHANGELOG.md has no `## [%s]` heading — move the Unreleased entries under one" % head_v)
    readme = sh("show", "%s:./README.md" % HEAD)
    m = re.search(r"Current version:\s*\**\s*`?v?([0-9.]+)", readme)
    if not m or m.group(1) != head_v:
        problems.append("README.md `Current version:` says %s, plugin.json says %s" % (m.group(1) if m else "nothing", head_v))
# Rule 3: a version already on its way to release is not open to this change.
for line in os.environ.get("VB_IN_FLIGHT", "").splitlines():
    ref, _, ref_mb = line.partition(" ")
    ref_v = version_at(ref)
    if not semver(ref_v) or not semver(head_v):
        continue
    ref_shipped = shipped_since(ref_mb)
    if ref_shipped and semver(head_v) <= semver(ref_v):
        problems.append("%s already carries %s on its way to release, and this change ships files since it (%s): "
                        "the version must be above %s" % (ref, ref_v, ", ".join(ref_shipped[:8]) + (" …" if len(ref_shipped) > 8 else ""), ref_v))
    else:
        print("in flight: %s at %s (%d shipped file(s) since its merge base)" % (ref, ref_v, len(ref_shipped)))
if bumped:
    # rule 4: no version while a workflow step's release-steps reference is still unwritten
    tree = set(sh("ls-tree", "-r", "--name-only", HEAD, "--", "workflows", "skills/release-steps").splitlines())
    unwritten = {}
    for path in sorted(p for p in tree if re.fullmatch(r"workflows/[^/]+\.json", p)):
        try:
            definition = json.loads(sh("show", "%s:./%s" % (HEAD, path)))
            steps = [s for ph in definition.get("phases", []) for s in ph.get("steps", [])]
        except Exception:
            continue  # an unreadable definition is check-workflows.py's business
        for step in steps:
            run = step.get("run") if isinstance(step, dict) else None
            if isinstance(run, dict) and run.get("source") == "builtin" and run.get("ref") == "release-steps":
                mode = str(step.get("contract", "")).split("@")[0]
                if "skills/release-steps/references/%s.md" % mode not in tree:
                    unwritten.setdefault(mode, path)
    if unwritten:
        modes = sorted(unwritten)
        problems.append("%d release step(s) have no reference yet in skills/release-steps/references/ (%s%s): "
                        "version it only once every one is written"
                        % (len(modes), ", ".join(modes[:6]), " …" if len(modes) > 6 else ""))
if problems:
    for p in problems: print("VERSION-BUMP: " + p)
    sys.exit(1)
print("ok version %s%s (%d shipped file(s) changed%s)" % (head_v, "" if not bumped else " (bumped from %s)" % base_v, len(shipped), "; no bump required" if not shipped else ""))
PY
