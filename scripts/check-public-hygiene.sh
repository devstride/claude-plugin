#!/bin/bash
# scripts/check-public-hygiene.sh — nothing private enters this public repository by accident.
#
# Why: everything committed here (file contents, commit messages, branch names, pull-request titles
# and bodies) is world-readable and permanent. A private tracker number, a link to an agent
# session, an internal host or a path from someone's machine is easy to paste and impossible to
# take back once pushed, and a reviewer who misses one is the only other line of defence.
#
# What it scans: the branch name, the title, the body (a file), every commit message in
# <base>..<head> and every ADDED line of `git diff <base>...<head>`. The files that define this
# check (this script, its test and the allow file) are not scanned: they must spell the patterns.
#
# Kinds of finding:
#   item-number      `I` followed by four to six digits, unless the allow file lists it
#   session-link     a link to an agent session on claude.ai
#   session-trailer  a `Claude-Session:` or `Codex-Session:` line — in commit messages, the title
#                    and the body only, because skill text that documents the trailer is fine
#   internal-host    a host under devstride.com or devstride.dev the allow file does not list
#   internal-path    a home folder (macOS or Linux), a home-relative development path, a `.worktrees/`
#                    path, or an agent's encoded session path (a `-Users-<name>` folder, a temporary
#                    or projects folder under `/private/` or `.claude/`)
#
# The allow file (`scripts/public-hygiene.allow`) holds one `item <I-number> <reason>` or
# `host <name> <reason>` per line; `#` starts a comment. A false positive is fixed by an allow line
# with a reason or by rewording — never by loosening a pattern here. The pull-request check runs
# main's copy of the allow file, so a new allow line lands in its own pull request first.
#
# Usage: check-public-hygiene.sh --base <ref> [--head <ref>] [--branch <name>] [--title <text>]
#                                [--body-file <path>] [--allow <path>]
# First line: `PUBLIC HYGIENE: CLEAN` or `PUBLIC HYGIENE: <n> finding(s)`, then one
# `HYGIENE: <kind> in <where>: <excerpt>` line per finding.
# Exit 0 clean, 1 findings, 2 usage (an unknown ref, an unreadable file or allow list).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE=""; HEAD_REF="HEAD"; BRANCH=""; TITLE=""; BODY_FILE=""; ALLOW="$ROOT/scripts/public-hygiene.allow"
usage() { echo "check-public-hygiene: $1" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --base) [ $# -ge 2 ] || usage "--base needs a value"; BASE="$2"; shift 2 ;;
    --head) [ $# -ge 2 ] || usage "--head needs a value"; HEAD_REF="$2"; shift 2 ;;
    --branch) [ $# -ge 2 ] || usage "--branch needs a value"; BRANCH="$2"; shift 2 ;;
    --title) [ $# -ge 2 ] || usage "--title needs a value"; TITLE="$2"; shift 2 ;;
    --body-file) [ $# -ge 2 ] || usage "--body-file needs a path"; BODY_FILE="$2"; shift 2 ;;
    --allow) [ $# -ge 2 ] || usage "--allow needs a path"; ALLOW="$2"; shift 2 ;;
    -h|--help) awk 'NR>1 && !/^#/{exit} NR>1{print}' "$0"; exit 0 ;;
    *) usage "unknown argument: $1" ;;
  esac
done
[ -n "$BASE" ] || usage "--base <ref> is required"
[ -z "$BODY_FILE" ] || [ -r "$BODY_FILE" ] || usage "cannot read the body file $BODY_FILE"
[ -r "$ALLOW" ] || usage "cannot read the allow list $ALLOW"
command -v python3 >/dev/null 2>&1 || usage "python3 is required"
git rev-parse --verify -q "$BASE^{commit}" >/dev/null || usage "unknown ref: $BASE"
git rev-parse --verify -q "$HEAD_REF^{commit}" >/dev/null || usage "unknown ref: $HEAD_REF"
PH_BASE="$BASE" PH_HEAD="$HEAD_REF" PH_BRANCH="$BRANCH" PH_TITLE="$TITLE" PH_BODY_FILE="$BODY_FILE" \
PH_ALLOW="$ALLOW" python3 - <<'PY'
import os, re, subprocess, sys
env = os.environ
def usage(msg):
    print("check-public-hygiene: " + msg, file=sys.stderr); sys.exit(2)
SELF = {"scripts/check-public-hygiene.sh", "scripts/tests/check-public-hygiene.sh", "scripts/public-hygiene.allow"}
items, hosts = set(), set()
with open(env["PH_ALLOW"], encoding="utf-8") as f:
    for n, raw in enumerate(f, 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split(None, 2)
        if len(parts) < 3 or parts[0] not in ("item", "host"):
            usage("allow list line %d must be `item <I-number> <reason>` or `host <name> <reason>`" % n)
        (items if parts[0] == "item" else hosts).add(parts[1].lower() if parts[0] == "host" else parts[1])
ITEM = re.compile(r"(?<![A-Za-z0-9_])I[0-9]{4,6}(?![A-Za-z0-9_])")
LINK = re.compile(r"claude\.ai/code/session_", re.I)
TRAILER = re.compile(r"^\s*(Claude|Codex)-Session:", re.I | re.M)
HOST = re.compile(r"(?<![A-Za-z0-9.-])((?:[A-Za-z0-9-]+\.)*devstride\.(?:com|dev))(?![A-Za-z0-9-])", re.I)
PATH = re.compile(r"/Users/|/home/[A-Za-z0-9._-]+/|(?:~|\$HOME|\$\{HOME\})/(?:dev|src|code|git|repos|projects|work)/"
                  r"|\.worktrees/|-Users-[A-Za-z0-9]|/private/tmp/claude-|/private/var/folders/|\.claude/projects/")
findings = []
def excerpt(text, start, end):
    a, b = max(0, start - 30), min(len(text), end + 30)
    return " ".join(text[a:b].split())
def scan(text, where, trailers):
    for m in ITEM.finditer(text):
        if m.group(0) not in items:
            findings.append(("item-number", where, excerpt(text, m.start(), m.end())))
    for m in LINK.finditer(text):
        findings.append(("session-link", where, excerpt(text, m.start(), m.end())))
    if trailers:
        for m in TRAILER.finditer(text):
            findings.append(("session-trailer", where, excerpt(text, m.start(), m.end())))
    for m in HOST.finditer(text):
        if m.group(1).lower() not in hosts:
            findings.append(("internal-host", where, excerpt(text, m.start(), m.end())))
    for m in PATH.finditer(text):
        findings.append(("internal-path", where, excerpt(text, m.start(), m.end())))
if env["PH_BRANCH"]:
    scan(env["PH_BRANCH"], "branch", True)
if env["PH_TITLE"]:
    scan(env["PH_TITLE"], "title", True)
if env["PH_BODY_FILE"]:
    with open(env["PH_BODY_FILE"], encoding="utf-8", errors="replace") as f:
        scan(f.read(), "body", True)
def git(*args):
    run = subprocess.run(["git", *args], capture_output=True)
    if run.returncode != 0:
        usage("git %s failed: %s" % (" ".join(args), run.stderr.decode("utf-8", "replace").strip()))
    return run.stdout.decode("utf-8", "replace")
log = git("log", "--format=%H%x00%B%x1e", "%s..%s" % (env["PH_BASE"], env["PH_HEAD"]))
for record in log.split("\x1e"):
    record = record.strip("\n")
    if "\x00" in record:
        sha, message = record.split("\x00", 1)
        scan(message, "commit " + sha[:7], True)
ESCAPES = {"a": 7, "b": 8, "t": 9, "n": 10, "v": 11, "f": 12, "r": 13, '"': 34, "\\": 92}
def unquote(name):
    """git C-quotes a path holding a double quote, a backslash or (core.quotePath) a non-ASCII byte."""
    if not (len(name) >= 2 and name.startswith('"') and name.endswith('"')):
        return name
    body, out, i = name[1:-1], bytearray(), 0
    while i < len(body):
        if body[i] == "\\" and i + 1 < len(body):
            if body[i + 1] in ESCAPES:
                out.append(ESCAPES[body[i + 1]]); i += 2; continue
            if body[i + 1:i + 4].isdigit():
                out.append(int(body[i + 1:i + 4], 8) & 0xFF); i += 4; continue
        out += body[i].encode("utf-8"); i += 1
    return out.decode("utf-8", "replace")
# Headers are read only BETWEEN hunks: inside one, the hunk header's counts say how many removed
# and added lines follow, so an added line that itself starts with "++ " is content. Lines are
# split on "\n" alone: a carriage return, form feed or Unicode separator inside a line is content.
HUNK = re.compile(r"^@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
path, line_no, old_left, new_left = None, 0, 0, 0
diff = git("diff", "--no-color", "--no-ext-diff", "--no-renames", "-U0", "%s...%s" % (env["PH_BASE"], env["PH_HEAD"]))
for line in diff.split("\n"):
    if old_left > 0 or new_left > 0:
        if line.startswith("+"):
            new_left -= 1
            if path and path not in SELF:
                scan(line[1:], "%s:%d" % (path, line_no), False)
            line_no += 1
        elif line.startswith("-"):
            old_left -= 1
        continue  # "\ No newline at end of file" and anything else inside a hunk is not a line
    if line.startswith("+++ "):
        target = unquote(line[4:].rstrip("\t"))
        path = target[2:] if target.startswith("b/") else None
    elif line.startswith("@@"):
        m = HUNK.match(line)
        if m:
            old_left = int(m.group(1)) if m.group(1) is not None else 1
            line_no = int(m.group(2))
            new_left = int(m.group(3)) if m.group(3) is not None else 1
if findings:
    print("PUBLIC HYGIENE: %d finding(s)" % len(findings))
    for kind, where, text in findings:
        print("HYGIENE: %s in %s: %s" % (kind, where, text))
    sys.exit(1)
print("PUBLIC HYGIENE: CLEAN")
PY
