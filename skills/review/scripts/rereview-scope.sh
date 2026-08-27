#!/usr/bin/env bash
# Decide the scope of the local CLI engine's round 2 — delta or full — from SHAs alone.
#
# Contract (skills/review/references/delta-re-review.md holds the reasoning):
#   - Everything is SHA-pinned and three-dot: round 1 = `<base>...<round1>`, the fix delta =
#     `<round1>...HEAD`. Never a PR-files listing (capped) and never a judgement.
#   - Decision, first match wins:
#       none              HEAD == round1 — no fix commits, no round 2, no round spent
#       full: history-rewritten   round1 is not an ancestor of HEAD (a rebase moved the patch)
#       full: new-file <path>     the delta touches a file round 1 never changed (renames are
#                                 matched on BOTH the source and the destination path)
#       full: delta <n> of <m> lines (> T%)   the delta rewrote more than --threshold of
#                                 round 1's changed lines — the fixes ARE new work
#       delta             otherwise: the engine is reading fixes to a diff it already read
#   - Prints ONE JSON line with the numbers the step-8 report needs. Exit 0 always on a
#     decision; 2 on usage error (a RESULT-shaped line is still printed).
#
# Usage: rereview-scope.sh --base <ref> --round1 <sha> [--threshold 0.5]
set -u
BASE=""; R1=""; T="0.5"
need() { [ $# -ge 2 ] || { echo "{\"scope\":\"usage-error\",\"error\":\"$1 needs a value\"}"; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --base) need "$@"; BASE="$2"; shift 2 ;;
    --round1) need "$@"; R1="$2"; shift 2 ;;
    --threshold) need "$@"; T="$2"; shift 2 ;;
    -h|--help) awk 'NR>1 && !/^#/{exit} NR>1{print}' "$0"; exit 0 ;;
    *) echo "{\"scope\":\"usage-error\",\"error\":\"unknown argument: $1\"}"; exit 2 ;;
  esac
done
[ -n "$BASE" ] && [ -n "$R1" ] || { echo '{"scope":"usage-error","error":"--base and --round1 are required"}'; exit 2; }
case "$T" in ''|*[!0-9.]*) echo '{"scope":"usage-error","error":"--threshold must be a number"}'; exit 2 ;; esac
command -v python3 >/dev/null 2>&1 || { echo '{"scope":"usage-error","error":"python3 is required"}'; exit 2; }
git rev-parse --verify -q "$BASE^{commit}" >/dev/null || { echo "{\"scope\":\"usage-error\",\"error\":\"unknown ref: $BASE\"}"; exit 2; }
git rev-parse --verify -q "$R1^{commit}" >/dev/null || { echo "{\"scope\":\"usage-error\",\"error\":\"unknown ref: $R1\"}"; exit 2; }
HEAD_SHA="$(git rev-parse HEAD)"; R1_SHA="$(git rev-parse "$R1^{commit}")"
export S_BASE="$BASE" S_R1="$R1_SHA" S_HEAD="$HEAD_SHA" S_T="$T"
python3 - <<'PY'
import json, os, subprocess, sys
E = os.environ; BASE, R1, HEAD, T = E["S_BASE"], E["S_R1"], E["S_HEAD"], float(E["S_T"])
def git(*a): return subprocess.run(["git"] + list(a), capture_output=True, text=True).stdout
def numstat(a, b):
    """entries as (source, destination) — equal for a plain path, both sides for a rename —
    plus added+deleted lines and bytes; three-dot, SHA-pinned."""
    entries, lines = [], 0
    for row in git("diff", "--numstat", "-M", "%s...%s" % (a, b)).splitlines():
        parts = row.split("\t")
        if len(parts) < 3: continue
        add, dele, path = parts[0], parts[1], parts[2]
        if "{" in path and "=>" in path:   # a/{old => new}/x.md
            pre, _, rest = path.partition("{"); inner, _, post = rest.partition("}")
            old, _, new = inner.partition(" => "); entries.append((pre + old.strip() + post, pre + new.strip() + post))
        elif " => " in path:
            old, _, new = path.partition(" => "); entries.append((old, new))
        else: entries.append((path, path))
        for v in (add, dele):
            if v.isdigit(): lines += int(v)
    nbytes = len(git("diff", "%s...%s" % (a, b)).encode("utf-8"))
    return entries, lines, nbytes
out = {"scope": None, "reason": None, "round1": None, "delta": None, "newFiles": [], "threshold": T, "round1Head": R1, "head": HEAD}
r1_entries, r1_lines, r1_bytes = numstat(BASE, R1)
r1_files = {p for e in r1_entries for p in e}   # a round-1 rename counts under both names
out["round1"] = {"files": len(r1_entries), "lines": r1_lines, "bytes": r1_bytes}
if HEAD == R1:
    out.update(scope="none", reason="no fix commits: HEAD is the round-1 head", delta={"files": 0, "lines": 0, "bytes": 0})
elif subprocess.run(["git", "merge-base", "--is-ancestor", R1, HEAD]).returncode != 0:
    d_entries, d_lines, d_bytes = numstat(BASE, HEAD)
    out.update(scope="full", reason="history-rewritten: the round-1 head is not an ancestor of HEAD", delta={"files": len(d_entries), "lines": d_lines, "bytes": d_bytes})
else:
    d_entries, d_lines, d_bytes = numstat(R1, HEAD)
    out["delta"] = {"files": len(d_entries), "lines": d_lines, "bytes": d_bytes}
    # A delta entry is NEW only when neither its source nor its destination was a round-1 file:
    # renaming a file round 1 changed is still round 1's file, under a new name.
    new = sorted(dst for (src, dst) in d_entries if src not in r1_files and dst not in r1_files)
    out["newFiles"] = new
    if new: out.update(scope="full", reason="new-file %s" % new[0] + (" (+%d more)" % (len(new) - 1) if len(new) > 1 else ""))
    elif r1_lines > 0 and d_lines > T * r1_lines: out.update(scope="full", reason="delta %d of %d lines (> %d%%)" % (d_lines, r1_lines, int(T * 100)))
    else: out.update(scope="delta", reason="the fixes stay inside round 1's files and under %d%% of its lines" % int(T * 100))
print(json.dumps(out, separators=(",", ":")))
PY
