#!/bin/bash
# scripts/check-neutrality.sh — the shipped plugin names nothing that belongs to one repository.
#
# Why: this plugin serves every repository that runs the loop. A seam is named for what it does
# generically; the launcher, command families, data sets, checkout names and deploy workflows of
# the repository the plugin grew up in are that repository's own and creep in one paragraph at a
# time. Each one reads as an instruction to a stranger whose repository has none of them.
#
# What it scans: skills/, hooks/, schemas/, .claude-plugin/, README.md, CONTRIBUTING.md and
# RELEASING.md under the root (not CHANGELOG.md, whose history may name retired things), one line
# at a time, against scripts/neutrality-denylist.txt (`<label><TAB><pattern>`, Python regular
# expressions). Item numbers are checked separately: an `I` and four to six digits is a finding
# unless scripts/public-hygiene.allow lists it (`item <I-number> <reason>`), the one list of the
# example numbers the shipped text may use.
#
# The allow file (scripts/neutrality-allow.txt) holds `<substring><TAB><reason>` lines; a finding
# is exempt only when its match lies inside an occurrence of an allowed substring on that line.
# A false positive is fixed by rewording or by an allow line with a reason, never by loosening a
# denylist pattern.
#
# Usage: check-neutrality.sh [--root <dir>] [--denylist <path>] [--allow <path>] [--items <path>]
# Output: `NEUTRALITY: CLEAN`, or one `NEUTRALITY: <file>:<line>: <label>: <excerpt>` per finding.
# Exit 0 clean, 1 findings, 2 usage (an unreadable list or root, a bad pattern).
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$HERE"; DENY=""; ALLOW=""; ITEMS=""
usage() { echo "check-neutrality: $1" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || usage "--root needs a directory"; ROOT="$2"; shift 2 ;;
    --denylist) [ $# -ge 2 ] || usage "--denylist needs a path"; DENY="$2"; shift 2 ;;
    --allow) [ $# -ge 2 ] || usage "--allow needs a path"; ALLOW="$2"; shift 2 ;;
    --items) [ $# -ge 2 ] || usage "--items needs a path"; ITEMS="$2"; shift 2 ;;
    -h|--help) awk 'NR>1 && !/^#/{exit} NR>1{print}' "$0"; exit 0 ;;
    *) usage "unknown argument: $1" ;;
  esac
done
[ -d "$ROOT" ] || usage "no such directory: $ROOT"
[ -n "$DENY" ] || DENY="$ROOT/scripts/neutrality-denylist.txt"
[ -n "$ALLOW" ] || ALLOW="$ROOT/scripts/neutrality-allow.txt"
[ -n "$ITEMS" ] || ITEMS="$ROOT/scripts/public-hygiene.allow"
for f in "$DENY" "$ALLOW" "$ITEMS"; do [ -r "$f" ] || usage "cannot read $f"; done
command -v python3 >/dev/null 2>&1 || usage "python3 is required"
NT_ROOT="$ROOT" NT_DENY="$DENY" NT_ALLOW="$ALLOW" NT_ITEMS="$ITEMS" python3 - <<'PY'
import os, re, sys
env = os.environ
root = env["NT_ROOT"]
def usage(msg):
    print("check-neutrality: " + msg, file=sys.stderr); sys.exit(2)
def rows(path):
    with open(path, encoding="utf-8") as f:
        for n, raw in enumerate(f, 1):
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            yield n, line
deny = []
for n, line in rows(env["NT_DENY"]):
    parts = line.split("\t", 1)
    if len(parts) != 2 or not parts[0].strip() or not parts[1].strip():
        usage("%s:%d: expected <label><TAB><pattern>" % (env["NT_DENY"], n))
    try:
        deny.append((parts[0].strip(), re.compile(parts[1].strip())))
    except re.error as e:
        usage("%s:%d: bad pattern: %s" % (env["NT_DENY"], n, e))
allowed = []
for n, line in rows(env["NT_ALLOW"]):
    parts = line.split("\t", 1)
    if len(parts) != 2 or not parts[0] or not parts[1].strip():
        usage("%s:%d: expected <substring><TAB><reason>" % (env["NT_ALLOW"], n))
    allowed.append(parts[0])
items = set()
for _, line in rows(env["NT_ITEMS"]):
    parts = line.split()
    if len(parts) >= 2 and parts[0] == "item":
        items.add(parts[1])
ITEM = re.compile(r"\bI[0-9]{4,6}\b")
TARGETS = ["skills", "hooks", "schemas", ".claude-plugin", "README.md", "CONTRIBUTING.md", "RELEASING.md"]
files = []
for t in TARGETS:
    p = os.path.join(root, t)
    if os.path.isfile(p):
        files.append(p)
    elif os.path.isdir(p):
        for d, dirs, names in os.walk(p):
            dirs[:] = sorted(x for x in dirs if x not in ("__pycache__", ".git"))
            files.extend(os.path.join(d, x) for x in sorted(names) if not x.endswith(".pyc"))
def exempt(line, start, end):
    for s in allowed:
        i = line.find(s)
        while i != -1:
            if i <= start and end <= i + len(s):
                return True
            i = line.find(s, i + 1)
    return False
found = []
for path in files:
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except (UnicodeDecodeError, OSError):
        continue  # a binary file has no lines to read
    rel = os.path.relpath(path, root)
    for n, line in enumerate(text.splitlines(), 1):
        hits = []
        for label, rx in deny:
            hits += [(label, m) for m in rx.finditer(line)]
        hits += [("item-number", m) for m in ITEM.finditer(line) if m.group(0) not in items]
        for label, m in hits:
            if exempt(line, m.start(), m.end()):
                continue
            excerpt = line.strip()
            if len(excerpt) > 120:
                excerpt = excerpt[:117] + "..."
            found.append("NEUTRALITY: %s:%d: %s: %s" % (rel, n, label, excerpt))
if not found:
    print("NEUTRALITY: CLEAN"); sys.exit(0)
for line in found:
    print(line)
sys.exit(1)
PY
