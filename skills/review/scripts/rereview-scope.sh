#!/usr/bin/env bash
# Decide one contextual follow-up scope — delta or full — from SHAs alone.
#
# Contract (skills/review/references/delta-re-review.md holds the reasoning):
#   - Everything is SHA-pinned and three-dot: reviewed patch = `<base>...<reviewed-head>`,
#     next delta = `<reviewed-head>...HEAD`. Never a capped PR-files list or judgement.
#   - Decision, first match wins:
#       none              HEAD == reviewed-head — no fix commits, no follow-up cycle spent
#       full: history-rewritten   reviewed-head is not an ancestor of HEAD (a rebase moved it)
#       full: new-file <path>     the delta touches no file in the preceding reviewed patch
#                                 (a delta rename is matched on source AND destination)
#       full: delta <n> of <m> lines (> T%)   the delta rewrote more than --threshold of
#                                 the preceding reviewed patch's lines — the fixes ARE new work
#       delta             otherwise: the engine is reading fixes to a diff it already read
#   - Prints ONE JSON line with the numbers the step-8 report needs. Exit 0 always on a
#     decision; 2 on usage error (a RESULT-shaped line is still printed).
#
# Usage: rereview-scope.sh --base <ref> --reviewed-head <sha> [--threshold 0.5]
set -u
BASE=""; PREV=""; T="0.5"
need() { [ $# -ge 2 ] || { echo "{\"scope\":\"usage-error\",\"error\":\"$1 needs a value\"}"; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --base) need "$@"; BASE="$2"; shift 2 ;;
    --reviewed-head) need "$@"; PREV="$2"; shift 2 ;;
    --threshold) need "$@"; T="$2"; shift 2 ;;
    -h|--help) awk 'NR>1 && !/^#/{exit} NR>1{print}' "$0"; exit 0 ;;
    *) echo "{\"scope\":\"usage-error\",\"error\":\"unknown argument: $1\"}"; exit 2 ;;
  esac
done
[ -n "$BASE" ] && [ -n "$PREV" ] || { echo '{"scope":"usage-error","error":"--base and --reviewed-head are required"}'; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo '{"scope":"usage-error","error":"python3 is required"}'; exit 2; }
python3 -c 'import sys; v=float(sys.argv[1]); sys.exit(0 if 0 < v <= 1 else 1)' "$T" 2>/dev/null || { echo '{"scope":"usage-error","error":"--threshold must be a number in (0, 1]"}'; exit 2; }
git rev-parse --verify -q "$BASE^{commit}" >/dev/null || { echo "{\"scope\":\"usage-error\",\"error\":\"unknown ref: $BASE\"}"; exit 2; }
git rev-parse --verify -q "$PREV^{commit}" >/dev/null || { echo "{\"scope\":\"usage-error\",\"error\":\"unknown ref: $PREV\"}"; exit 2; }
HEAD_SHA="$(git rev-parse HEAD)"; PREV_SHA="$(git rev-parse "$PREV^{commit}")"
export S_BASE="$BASE" S_PREV="$PREV_SHA" S_HEAD="$HEAD_SHA" S_T="$T"
python3 - <<'PY'
import json, os, subprocess, sys
E = os.environ; BASE, PREV, HEAD, T = E["S_BASE"], E["S_PREV"], E["S_HEAD"], float(E["S_T"])
def git(*a): return subprocess.run(["git"] + list(a), capture_output=True).stdout   # bytes: a diff need not be UTF-8
def numstat(a, b):
    """entries as (source, destination) — equal for a plain path, both sides for a rename —
    plus added+deleted lines and bytes; three-dot, SHA-pinned. `-z` makes git emit a rename's
    two paths as separate NUL-terminated fields, so no brace form is ever parsed."""
    entries, lines = [], 0
    tokens = git("diff", "--numstat", "-M", "-z", "%s...%s" % (a, b)).decode("utf-8", "surrogateescape").split("\0")
    i = 0
    while i < len(tokens):
        parts = tokens[i].split("\t", 2); i += 1   # a path may itself contain a tab
        if len(parts) < 3: continue
        add, dele, path = parts[0], parts[1], parts[2]
        if path == "" and i + 1 < len(tokens):   # rename: the next two tokens are source, destination
            entries.append((tokens[i], tokens[i + 1])); i += 2
        else: entries.append((path, path))
        for v in (add, dele):
            if v.isdigit(): lines += int(v)
    nbytes = len(git("diff", "%s...%s" % (a, b)))
    return entries, lines, nbytes
out = {"scope": None, "reason": None, "reviewed": None, "delta": None, "newFiles": [], "threshold": T, "reviewedHead": PREV, "head": HEAD}
prev_entries, prev_lines, prev_bytes = numstat(BASE, PREV)
# Files in the preceding reviewed patch as they exist at its head. A rename counts under its
# destination; a deleted path is absent, so recreating it is new.
at_prev = set(git("ls-tree", "-r", "--name-only", "-z", PREV).decode("utf-8", "surrogateescape").split("\0"))
prev_files = {dst for (src, dst) in prev_entries} & at_prev
out["reviewed"] = {"files": len(prev_entries), "lines": prev_lines, "bytes": prev_bytes}
if HEAD == PREV:
    out.update(scope="none", reason="no fix commits: HEAD is the reviewed head", delta={"files": 0, "lines": 0, "bytes": 0})
elif subprocess.run(["git", "merge-base", "--is-ancestor", PREV, HEAD]).returncode != 0:
    d_entries, d_lines, d_bytes = numstat(BASE, HEAD)
    out.update(scope="full", reason="history-rewritten: the reviewed head is not an ancestor of HEAD", delta={"files": len(d_entries), "lines": d_lines, "bytes": d_bytes})
else:
    d_entries, d_lines, d_bytes = numstat(PREV, HEAD)
    out["delta"] = {"files": len(d_entries), "lines": d_lines, "bytes": d_bytes}
    # NEW only when neither side belongs to the preceding reviewed patch.
    new = sorted(dst for (src, dst) in d_entries if src not in prev_files and dst not in prev_files)
    out["newFiles"] = new
    if new: out.update(scope="full", reason="new-file %s" % new[0] + (" (+%d more)" % (len(new) - 1) if len(new) > 1 else ""))
    elif d_lines > T * prev_lines: out.update(scope="full", reason="delta %d of %d lines (> %d%%)" % (d_lines, prev_lines, int(T * 100)))
    else: out.update(scope="delta", reason="the fixes stay inside the reviewed patch's files and under %d%% of its lines" % int(T * 100))
print(json.dumps(out, separators=(",", ":")))
PY
