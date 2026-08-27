#!/usr/bin/env python3
"""Group review findings into verifier work — deterministic, dependency-free.

Contract (skills/ultracode-build/references/review-fanout.md holds the reasoning):

  stdin  {"findings":[{"id":"F1","file":"src/a.ts","line":12,"lens":"correctness","claim":"…"}, …],
          "authBoundaryFiles":["src/auth/login.ts", "src/auth/"], "grouping":"per-file|per-finding",
          "maxFindings":5, "maxFiles":3}
  stdout {"groups":[{"id":"G1","files":[…],"findings":["F1","F4"]}], "perFinding":["F7"],
          "verifiers":<G+A>, "counts":{"findings":N,"groups":G,"authBoundary":A}}

  - `id`, `file` and `lens` are mandatory on every finding; ids are unique. `lens` is normalised
    (case, surrounding space; a list means any of its entries) and must be one of correctness,
    security, contract, tests, cleanup — a misspelt lens is an error, never "not security".
  - Paths are normalised on both sides (`./`, redundant separators, a trailing `:line` on the
    anchor). An `authBoundaryFiles` entry ending in `/` is a directory prefix.
  - A finding is AUTH-BOUNDARY iff its lens is `security` or its file is in `authBoundaryFiles`.
    It is never grouped: it goes to `perFinding` (one verifier each) under every grouping.
  - The rest are bucketed by file; a bucket with more than maxFindings splits in id order; buckets
    are packed largest-first (first-fit, preferring a group holding a file from the same
    directory) into groups of <= maxFindings findings and <= maxFiles files.
  - `grouping: per-finding` makes every non-auth finding its own group.
  - Output ordering is sorted, so the same input in any order yields byte-identical output.
  - Any malformed input is an error on stderr (`group-findings: …`) with exit 1 — never a
    traceback, never a silently degraded grouping.
"""
import json
import posixpath
import re
import sys

LENSES = ("correctness", "security", "contract", "tests", "cleanup")


def fail(msg):
    sys.stderr.write("group-findings: %s\n" % msg)
    sys.exit(1)


def id_key(fid):
    m = re.fullmatch(r"([A-Za-z]*)(\d{1,9})", fid)
    return (m.group(1), int(m.group(2))) if m else ("~" + fid, 0)


def norm_path(p):
    p = re.sub(r":\d+(-\d+)?$", "", p.strip())          # a `file:line` anchor
    trailing = p.endswith("/")
    p = posixpath.normpath(p)
    if p.startswith("./"):
        p = p[2:]
    return p + ("/" if trailing and not p.endswith("/") else "")


def norm_lens(raw, fid):
    vals = raw if isinstance(raw, list) else [raw]
    out = []
    for v in vals:
        if not isinstance(v, str) or not v.strip():
            fail("finding %s has no lens — every merged finding carries its finder's lens" % fid)
        v = v.strip().lower()
        if v not in LENSES:
            fail("finding %s has lens %r; expected one of %s" % (fid, v, ", ".join(LENSES)))
        out.append(v)
    if not out:
        fail("finding %s has no lens — every merged finding carries its finder's lens" % fid)
    return out


def int_option(spec, key, default):
    v = spec.get(key, default)
    if isinstance(v, bool) or not isinstance(v, int):
        fail("%s must be an integer >= 1, got %r" % (key, v))
    if v < 1:
        fail("%s must be >= 1, got %r" % (key, v))
    return v


def main():
    try:
        spec = json.load(sys.stdin)
    except ValueError as e:
        fail("stdin is not JSON: %s" % e)
    if not isinstance(spec, dict):
        fail("stdin must be a JSON object")
    findings = spec.get("findings")
    if not isinstance(findings, list):
        fail("`findings` must be a list")
    seen = set()
    clean = []
    for i, f in enumerate(findings):
        if not isinstance(f, dict):
            fail("finding at index %d is not an object" % i)
        fid = f.get("id")
        if not isinstance(fid, str) or not fid:
            fail("finding at index %d has no id (file=%r line=%r) — ids are mandatory" % (i, f.get("file"), f.get("line")))
        if fid in seen:
            fail("duplicate id %s" % fid)
        seen.add(fid)
        if not isinstance(f.get("file"), str) or not f["file"].strip():
            fail("finding %s has no file" % fid)
        clean.append({"id": fid, "file": norm_path(f["file"]), "lens": norm_lens(f.get("lens"), fid)})
    raw_auth = spec.get("authBoundaryFiles", [])
    if not isinstance(raw_auth, list) or not all(isinstance(p, str) and p.strip() for p in raw_auth):
        fail("`authBoundaryFiles` must be a list of non-empty path strings")
    auth_files = {norm_path(p) for p in raw_auth}
    auth_dirs = tuple(p for p in auth_files if p.endswith("/"))
    grouping = spec.get("grouping", "per-file")
    if grouping not in ("per-file", "per-finding"):
        fail("`grouping` must be per-file or per-finding, got %r" % grouping)
    max_findings = int_option(spec, "maxFindings", 5)
    max_files = int_option(spec, "maxFiles", 3)

    clean.sort(key=lambda f: id_key(f["id"]))

    def is_auth(f):
        return "security" in f["lens"] or f["file"] in auth_files or f["file"].startswith(auth_dirs)

    per_finding = [f["id"] for f in clean if is_auth(f)]
    rest = [f for f in clean if not is_auth(f)]

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
        # pack largest-first (first-fit decreasing), preferring a group from the same directory
        pieces.sort(key=lambda p: (-len(p[1]), p[0]))
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
        "counts": {"findings": len(clean), "groups": len(out_groups), "authBoundary": len(per_finding)},
    }
    print(json.dumps(out, separators=(",", ":"), sort_keys=True))


if __name__ == "__main__":
    main()
