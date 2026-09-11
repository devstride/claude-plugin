#!/bin/bash
# scripts/check-version-bump.sh — a change to shipped files must arrive with a version bump.
#
# Why: `version` in .claude-plugin/plugin.json is the install cache key. A change to skills/,
# hooks/ or plugin.json that lands on main without a bump is invisible to every installed copy,
# and it fails silently — the repo looks right and no user sees it. This check makes the bump
# mechanical: run it against the base the change will land on (RELEASING.md step 4).
#
# Rules, checked against `<base>...<head>`:
#   1. If any shipped file changed (skills/**, hooks/**, .claude-plugin/plugin.json other than
#      its version line), the head version must be greater than the base version (numeric
#      semver compare).
#   2. If the version changed, the head version must not already be a tag
#      (`devstride--v<version>`), unless HEAD is the commit that tag points at. An unchanged
#      version is rule 1's business: a change that ships nothing needs no bump.
#   3. If the version changed, CHANGELOG.md must carry a `## [<version>]` heading and
#      README.md's `Current version:` line must name it.
#   4. If the version changed, the head version must be greater than the newest devstride--v*
#      tag known locally (a bump to a version older than the last release is a mistake).
#
# Usage: check-version-bump.sh --base <ref> [--head <ref>]      exit 0 ok, 1 violation, 2 usage
set -u
BASE=""; HEAD_REF="HEAD"
while [ $# -gt 0 ]; do
  case "$1" in
    --base) [ $# -ge 2 ] || { echo "check-version-bump: --base needs a value" >&2; exit 2; }; BASE="$2"; shift 2 ;;
    --head) [ $# -ge 2 ] || { echo "check-version-bump: --head needs a value" >&2; exit 2; }; HEAD_REF="$2"; shift 2 ;;
    -h|--help) awk 'NR>1 && !/^#/{exit} NR>1{print}' "$0"; exit 0 ;;
    *) echo "check-version-bump: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$BASE" ] || { echo "check-version-bump: --base <ref> is required" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "check-version-bump: python3 is required" >&2; exit 2; }
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "check-version-bump: not a git repository" >&2; exit 2; }
cd "$ROOT" || exit 2
git rev-parse --verify -q "$BASE^{commit}" >/dev/null || { echo "check-version-bump: unknown ref: $BASE" >&2; exit 2; }
git rev-parse --verify -q "$HEAD_REF^{commit}" >/dev/null || { echo "check-version-bump: unknown ref: $HEAD_REF" >&2; exit 2; }
MB="$(git merge-base "$BASE" "$HEAD_REF")" || { echo "check-version-bump: no merge base between $BASE and $HEAD_REF" >&2; exit 2; }
export VB_MB="$MB" VB_HEAD="$HEAD_REF"
python3 - <<'PY'
import json, os, re, subprocess, sys
MB, HEAD = os.environ["VB_MB"], os.environ["VB_HEAD"]
def sh(*a):
    return subprocess.run(["git", *a], capture_output=True, text=True).stdout
def version_at(ref):
    try:
        return json.loads(sh("show", "%s:.claude-plugin/plugin.json" % ref)).get("version", "")
    except Exception:
        return ""
def semver(v):
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", v or "")
    return tuple(int(x) for x in m.groups()) if m else None
base_v, head_v = version_at(MB), version_at(HEAD)
problems = []
if semver(head_v) is None:
    problems.append("head version %r is not MAJOR.MINOR.PATCH" % head_v)
changed = [l for l in sh("diff", "--name-only", MB, HEAD).splitlines() if l]
shipped = [f for f in changed if f.startswith("skills/") or f.startswith("hooks/")]
if ".claude-plugin/plugin.json" in changed:
    # a version-only edit is the bump itself, not a shipped change
    d = sh("diff", MB, HEAD, "--", ".claude-plugin/plugin.json")
    body = [l for l in d.splitlines() if (l.startswith("+") or l.startswith("-")) and not l.startswith(("+++", "---"))]
    if any('"version"' not in l for l in body):
        shipped.append(".claude-plugin/plugin.json")
bumped = head_v != base_v
if shipped and not bumped:
    problems.append("shipped files changed without a version bump (still %s): %s" % (head_v, ", ".join(shipped[:8]) + (" …" if len(shipped) > 8 else "")))
if bumped and semver(head_v) and semver(base_v) and semver(head_v) <= semver(base_v):
    problems.append("version went from %s to %s — it must increase" % (base_v, head_v))
tags = [t for t in sh("tag", "-l", "devstride--v*").split() if semver(t[len("devstride--v"):])]
if tags:
    newest = max(tags, key=lambda t: semver(t[len("devstride--v"):]))
    newest_v = newest[len("devstride--v"):]
    tag_for_head = "devstride--v%s" % head_v
    if bumped and tag_for_head in tags:
        tagged = sh("rev-parse", tag_for_head + "^{commit}").strip(); head_sha = sh("rev-parse", HEAD + "^{commit}").strip()
        if tagged != head_sha:
            problems.append("version %s is already released as %s (at %s); bump past it" % (head_v, tag_for_head, tagged[:7]))
    if bumped and semver(head_v) and semver(head_v) <= semver(newest_v):
        problems.append("version %s is not newer than the newest release tag %s" % (head_v, newest))
if bumped and semver(head_v):
    changelog = sh("show", "%s:CHANGELOG.md" % HEAD)
    if not re.search(r"^## \[%s\]" % re.escape(head_v), changelog, re.M):
        problems.append("CHANGELOG.md has no `## [%s]` heading — move the Unreleased entries under one (RELEASING.md step 1)" % head_v)
    readme = sh("show", "%s:README.md" % HEAD)
    m = re.search(r"Current version:\s*\**\s*`?v?([0-9.]+)", readme)
    if not m or m.group(1) != head_v:
        problems.append("README.md `Current version:` says %s, plugin.json says %s (RELEASING.md step 3)" % (m.group(1) if m else "nothing", head_v))
if problems:
    for p in problems: print("VERSION-BUMP: " + p)
    sys.exit(1)
print("ok version %s%s (%d shipped file(s) changed%s)" % (head_v, "" if not bumped else " (bumped from %s)" % base_v, len(shipped), "; no bump required" if not shipped else ""))
PY
