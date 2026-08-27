#!/usr/bin/env python3
"""Group review findings into verifier work — deterministic, dependency-free.

Contract (skills/ultracode-build/references/review-fanout.md holds the reasoning):

  stdin  {"findings":[{"id":"F1","file":"src/a.ts","line":12,"lens":"correctness","claim":"…"}, …],
          "authBoundaryFiles":["src/auth/…"], "grouping":"per-file|per-finding",
          "maxFindings":5, "maxFiles":3}
  stdout {"groups":[{"id":"G1","files":[…],"findings":["F1","F4"]}], "perFinding":["F7"],
          "verifiers":<G+A>, "counts":{"findings":N,"fileGroups":G,"authBoundary":A}}

  - A finding is AUTH-BOUNDARY iff its lens is `security` or its file is in `authBoundaryFiles`.
    It is never grouped: it goes to `perFinding` (one verifier each) under every grouping.
  - The rest are bucketed by file; a bucket with more than maxFindings splits in id order; buckets
    are packed greedily, smallest first, into groups of <= maxFindings findings and <= maxFiles
    files, preferring files from one directory so a verifier holds related code.
  - `grouping: per-finding` makes every finding its own group.
  - Ids are mandatory and unique; a finding without one is an error (exit 1, naming it).
  - Output ordering is sorted, so the same input in any order yields byte-identical output.
"""
import json
import posixpath
import re
import sys


def id_key(fid):
    m = re.fullmatch(r"([A-Za-z]*)(\d+)", fid)
    return (m.group(1), int(m.group(2))) if m else ("~" + fid, 0)


def fail(msg):
    sys.stderr.write("group-findings: %s\n" % msg)
    sys.exit(1)


def main():
    try:
        spec = json.load(sys.stdin)
    except ValueError as e:
        fail("stdin is not JSON: %s" % e)
    findings = spec.get("findings")
    if not isinstance(findings, list):
        fail("`findings` must be a list")
    seen = set()
    for i, f in enumerate(findings):
        fid = f.get("id") if isinstance(f, dict) else None
        if not isinstance(fid, str) or not fid:
            fail("finding at index %d has no id (file=%r line=%r) — ids are mandatory" % (i, f.get("file") if isinstance(f, dict) else None, f.get("line") if isinstance(f, dict) else None))
        if fid in seen:
            fail("duplicate id %s" % fid)
        seen.add(fid)
        if not isinstance(f.get("file"), str) or not f["file"]:
            fail("finding %s has no file" % fid)
    auth_files = set(spec.get("authBoundaryFiles") or [])
    grouping = spec.get("grouping") or "per-file"
    if grouping not in ("per-file", "per-finding"):
        fail("`grouping` must be per-file or per-finding, got %r" % grouping)
    max_findings = int(spec.get("maxFindings") or 5)
    max_files = int(spec.get("maxFiles") or 3)
    if max_findings < 1 or max_files < 1:
        fail("maxFindings and maxFiles must be >= 1")

    findings = sorted(findings, key=lambda f: id_key(f["id"]))
    per_finding = [f["id"] for f in findings if f.get("lens") == "security" or f["file"] in auth_files]
    rest = [f for f in findings if f["id"] not in set(per_finding)]

    groups = []  # each: {"files": set, "findings": list}
    if grouping == "per-finding":
        for f in rest:
            groups.append({"files": {f["file"]}, "findings": [f["id"]]})
    else:
        buckets = {}
        for f in rest:
            buckets.setdefault(f["file"], []).append(f["id"])
        # split oversized buckets in id order (ids are already sorted)
        pieces = []
        for path in sorted(buckets):
            ids = buckets[path]
            for start in range(0, len(ids), max_findings):
                pieces.append((path, ids[start:start + max_findings]))
        # pack greedily, smallest first; same-directory groups preferred
        pieces.sort(key=lambda p: (len(p[1]), p[0]))
        for path, ids in pieces:
            d = posixpath.dirname(path)
            fits = [g for g in groups
                    if len(g["findings"]) + len(ids) <= max_findings
                    and len(g["files"] | {path}) <= max_files]
            same_dir = [g for g in fits if any(posixpath.dirname(p) == d for p in g["files"])]
            target = (same_dir or fits or [None])[0]
            if target is None:
                groups.append({"files": {path}, "findings": list(ids)})
            else:
                target["files"].add(path)
                target["findings"].extend(ids)

    # deterministic presentation: sort inside each group, then order groups by their first id
    for g in groups:
        g["findings"].sort(key=id_key)
        g["files"] = sorted(g["files"])
    groups.sort(key=lambda g: id_key(g["findings"][0]))
    out_groups = [{"id": "G%d" % (n + 1), "files": g["files"], "findings": g["findings"]} for n, g in enumerate(groups)]
    out = {
        "groups": out_groups,
        "perFinding": per_finding,
        "verifiers": len(out_groups) + len(per_finding),
        "counts": {"findings": len(findings), "fileGroups": len(out_groups), "authBoundary": len(per_finding)},
    }
    print(json.dumps(out, separators=(",", ":"), sort_keys=True))


if __name__ == "__main__":
    main()
