#!/bin/bash
# scripts/check-public-hygiene.sh — nothing private is in a folder that is, or will become, public.
#
# Why: every file of this plugin is published world-readable and permanent. A private tracker
# number, a link to an agent session, an internal host or a path from someone's machine is easy to
# paste and impossible to take back once published, and a reviewer who misses one is the only
# other line of defence.
#
# What it scans: every line of every file under <dir>, and every file's path inside it (names are
# published too), and nothing else (no commit message, branch name or pull-request text). Inside a git work tree the files are the tracked ones plus the
# untracked ones git does not ignore (`git ls-files --cached --others --exclude-standard`), so an
# ignored `__pycache__` is never read; anywhere else (an exported copy) the folder is walked whole.
# This script and its test are not scanned, by their path inside the folder, since they must spell
# the patterns; in the folder's allow file only an allowed item number or host is skipped (a `file`
# path is scanned, so it cannot carry a machine path).
#
# Kinds of finding:
#   item-number      `I` followed by four to six digits, unless the allow file lists it
#   session-link     a link to an agent session on claude.ai
#   internal-host    a host under devstride.com or devstride.dev the allow file does not list
#   binary-file      a binary file (it has no lines to scan), unless the allow file names it
#   internal-path    a home folder (macOS or Linux), a home-relative development path, a `.worktrees/`
#                    path, or an agent's encoded session path (a `-Users-<name>` folder, a temporary
#                    or projects folder under `/private/` or `.claude/`)
#
# The allow file (`<dir>/scripts/public-hygiene.allow` unless --allow names another) holds one
# `item <I-number> <reason>`, `host <name> <reason>` or `file <path> <reason>` (a binary file, by
# its path inside the folder) per line; `#` starts a comment. A false positive is fixed by an allow
# line with a reason or by rewording — never by loosening a pattern here.
#
# Usage: check-public-hygiene.sh --tree <dir> [--allow <path>]
# First line: `PUBLIC HYGIENE: CLEAN` or `PUBLIC HYGIENE: <n> finding(s)`, then one
# `HYGIENE: <kind> in <path>:<line>: <excerpt>` line per finding, paths relative to <dir> (a binary
# file, and a finding in a path's own name, has no line number).
# Exit 0 clean, 1 findings, 2 usage (no folder, an unreadable folder or allow list).
set -u
TREE=""; ALLOW=""
usage() { echo "check-public-hygiene: $1" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --tree) [ $# -ge 2 ] || usage "--tree needs a folder"; TREE="$2"; shift 2 ;;
    --allow) [ $# -ge 2 ] || usage "--allow needs a path"; ALLOW="$2"; shift 2 ;;
    -h|--help) awk 'NR>1 && !/^#/{exit} NR>1{print}' "$0"; exit 0 ;;
    *) usage "unknown argument: $1 (usage: --tree <dir> [--allow <path>])" ;;
  esac
done
[ -n "$TREE" ] || usage "--tree <dir> is required"
[ -d "$TREE" ] || usage "not a folder: $TREE"
TREE="$(cd "$TREE" 2>/dev/null && pwd -P)" || usage "cannot read the folder"
[ -n "$ALLOW" ] || ALLOW="$TREE/scripts/public-hygiene.allow"
[ -f "$ALLOW" ] && [ -r "$ALLOW" ] || usage "cannot read the allow list $ALLOW"
command -v python3 >/dev/null 2>&1 || usage "python3 is required"
PH_TREE="$TREE" PH_ALLOW="$ALLOW" python3 - <<'PY'
import os, re, subprocess, sys
env = os.environ
def usage(msg):
    print("check-public-hygiene: " + msg, file=sys.stderr); sys.exit(2)
# The script and its test spell every pattern, so they are not scanned, by their path inside the
# folder. The allow file is: its comments and every reason are, only the token a line allows is
# left out.
SELF = {"scripts/check-public-hygiene.sh", "scripts/tests/check-public-hygiene.sh"}
ALLOW_PATH = "scripts/public-hygiene.allow"
# Each kind's token has a grammar, and a token that matches it is exempt only from its OWN kind of
# finding (an item number from item-number, a host from internal-host); every other pattern still
# reads it, so an allow line cannot smuggle a link, a path or another number in. A `file` line is
# scanned whole.
TOKEN = {"item": re.compile(r"I[0-9]{4,6}"), "host": re.compile(r"(?:[a-z0-9-]+\.)+[a-z]{2,}"),
         "file": re.compile(r"[^/~\s#][^\s#]*")}
ALLOW_LINE = re.compile(r"^\s*(item|host)\s+(\S+)(.*)$")
items, hosts, files = set(), set(), set()
with open(env["PH_ALLOW"], encoding="utf-8") as f:
    for n, raw in enumerate(f, 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split(None, 2)
        if len(parts) < 3 or parts[0] not in TOKEN or not TOKEN[parts[0]].fullmatch(parts[1].lower() if parts[0] == "host" else parts[1]):
            usage("allow list line %d must be `item <I-number> <reason>`, `host <hostname> <reason>` or"
                  " `file <path inside the folder> <reason>`" % n)
        {"item": items, "host": hosts, "file": files}[parts[0]].add(parts[1].lower() if parts[0] == "host" else parts[1])
ITEM = re.compile(r"(?<![A-Za-z0-9_])I[0-9]{4,6}(?![A-Za-z0-9_])")
LINK = re.compile(r"claude\.ai/code/session_", re.I)
HOST = re.compile(r"(?<![A-Za-z0-9.-])((?:[A-Za-z0-9-]+\.)*devstride\.(?:com|dev))(?![A-Za-z0-9-])", re.I)
PATH = re.compile(r"/Users/|/home/[A-Za-z0-9._-]+/|(?:~|\$HOME|\$\{HOME\})/(?:dev|src|code|git|repos|projects|work)/"
                  r"|\.worktrees/|-Users-[A-Za-z0-9]|/private/tmp/claude-|/private/var/folders/|\.claude/projects/")
findings = []
def excerpt(text, start, end):
    a, b = max(0, start - 30), min(len(text), end + 30)
    return " ".join(text[a:b].split())
def scan(text, where, exempt=None):
    """exempt = (kind, span): an allow line's token, exempt ONLY from its own kind of finding."""
    def own(kind, m):
        return exempt is not None and exempt[0] == kind and m.start() >= exempt[1][0] and m.end() <= exempt[1][1]
    for m in ITEM.finditer(text):
        if m.group(0) not in items and not own("item", m):
            findings.append(("item-number", where, excerpt(text, m.start(), m.end())))
    for m in LINK.finditer(text):
        findings.append(("session-link", where, excerpt(text, m.start(), m.end())))
    for m in HOST.finditer(text):
        if m.group(1).lower() not in hosts and not own("host", m):
            findings.append(("internal-host", where, excerpt(text, m.start(), m.end())))
    for m in PATH.finditer(text):
        findings.append(("internal-path", where, excerpt(text, m.start(), m.end())))
TREE = env["PH_TREE"]
def listed():
    """Tree-relative paths, sorted. Inside a work tree: tracked files plus untracked ones git does
    not ignore. Anywhere else, or when git ignores the folder itself (it would list nothing and the
    scan would pass unread), every file under the folder."""
    def git(*args):
        return subprocess.run(["git", "-C", TREE, *args], capture_output=True)
    try:
        inside = git("rev-parse", "--is-inside-work-tree")
        if inside.returncode == 0 and inside.stdout.strip() == b"true" and git("check-ignore", "-q", ".").returncode != 0:
            run = git("ls-files", "--cached", "--others", "--exclude-standard", "-z")
            if run.returncode != 0:
                usage("git ls-files failed: " + run.stderr.decode("utf-8", "replace").strip())
            return sorted({os.fsdecode(p) for p in run.stdout.split(b"\0") if p})
    except FileNotFoundError:  # no git on this machine: walk
        pass
    out = []
    for folder, dirs, names in os.walk(TREE):
        dirs[:] = [d for d in dirs if d != ".git"]
        for name in names + [d for d in dirs if os.path.islink(os.path.join(folder, d))]:
            if name != ".git":
                out.append(os.path.relpath(os.path.join(folder, name), TREE))
    return sorted(out)
for path in listed():
    # A name is published as surely as the content: a file named for an item number, or a fixture
    # folder named for an agent's encoded session path, is a finding like the same text inside one.
    scan(path, path)
    if path in SELF:
        continue
    full = os.path.join(TREE, path)
    if os.path.islink(full):  # a link has no content of its own: its target text is what is published
        scan(os.readlink(full), "%s:1" % path)
        continue
    if not os.path.isfile(full):  # tracked but deleted in the working copy, or a nested repository
        continue
    try:
        with open(full, "rb") as f:
            data = f.read()
    except OSError as e:
        usage("cannot read %s: %s" % (path, e.strerror))
    # A binary file has no lines to read, so it cannot be shown clean: each one is a finding unless
    # the allow file names it with a reason. Binary means what git means: a NUL byte near the start.
    if b"\0" in data[:8000]:
        if path not in files:
            findings.append(("binary-file", path, "a binary file cannot be scanned; allow it with `file <path> <reason>`"))
        continue
    # Lines are split on "\n" alone: a carriage return, form feed or Unicode separator inside a line
    # is content.
    lines = data.decode("utf-8", "replace").split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    for line_no, text in enumerate(lines, 1):
        exempt = None
        if path == ALLOW_PATH:
            m = ALLOW_LINE.match(text)
            if m and TOKEN[m.group(1)].fullmatch(m.group(2).lower() if m.group(1) == "host" else m.group(2)):
                exempt = (m.group(1), m.span(2))
        scan(text, "%s:%d" % (path, line_no), exempt)
if findings:
    print("PUBLIC HYGIENE: %d finding(s)" % len(findings))
    for kind, where, text in findings:
        print("HYGIENE: %s in %s: %s" % (kind, where, text))
    sys.exit(1)
print("PUBLIC HYGIENE: CLEAN")
PY
