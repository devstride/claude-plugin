#!/bin/bash
# scripts/tests/orchestrator-key-parity.sh — CONTRIBUTING's key walk, made mechanical: every dotted
# config key an orchestrator body cited at the base ref is still cited by the new body, or by a step
# skill or contract that body now points to. A paragraph moved into a step must not drop a key.
#
# Undotted top-level keys (`preShipChecks`, `baseBranch` …) count too when the registry registers
# them. SEAM_BASE_REF names the base (default origin/main); without that ref the walk is skipped
# with a note locally, and FAILS when CI is set: a CI run that cannot see the base proves nothing.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
BASE="${SEAM_BASE_REF:-origin/main}"

if ! git -C "$ROOT" rev-parse --verify -q "$BASE^{commit}" >/dev/null; then
  if [ -n "${CI:-}" ]; then
    bad "(1) no $BASE in this clone; CI must fetch the base ref (or set SEAM_BASE_REF) so the walk runs"
  else
    ok "(1) skipped: no $BASE in this clone (set SEAM_BASE_REF to a base ref to run the walk)"
  fi
  exit "$FAIL"
fi

for n in release build-item pr branch-hotfix doctor; do
  git -C "$ROOT" show "$BASE:skills/$n/SKILL.md" > "$WORK/$n.base" 2>/dev/null || : > "$WORK/$n.base"
done

python3 - "$ROOT" "$WORK" release build-item pr branch-hotfix doctor > "$WORK/out.txt" 2>&1 <<'PY'
import os, re, sys
root, work, names = sys.argv[1], sys.argv[2], sys.argv[3:]
KEY = re.compile(r"`([A-Za-z]+(?:\.[A-Za-z]+)+)`")
FILE_EXT = {"md", "json", "sh", "py", "yaml", "yml", "txt", "toml"}
POINTER = re.compile(r"\$\{CLAUDE_PLUGIN_ROOT\}/([A-Za-z0-9_./-]+)")
# the step skills an orchestrator may hand a paragraph to (never another orchestrator)
steps = ["update-docs", "sync-knowledge-base", "write-release-notes", "pre-ship", "post-deploy",
         "local-environment", "lease-checkout", "return-checkout", "classify-release", "pre-merge-check"]
import json
reg = json.load(open(os.path.join(root, "schemas/seam-registry.json"), encoding="utf-8"))
TOP = {re.sub(r"\[\]$", "", e["key"].split(".")[0]) for e in reg["hooks"] + reg["settings"]}
BARE = re.compile(r"`([A-Za-z]+)`")
def keys(text):
    dotted = {k for k in KEY.findall(text) if k.rsplit(".", 1)[-1] not in FILE_EXT}
    return dotted | {k for k in BARE.findall(text) if k in TOP}
def read(rel):
    p = os.path.join(root, rel)
    return open(p, encoding="utf-8").read() if os.path.isfile(p) else ""
problems, counts = [], []
for n in names:
    before = keys(open(os.path.join(work, n + ".base"), encoding="utf-8").read())
    body = read("skills/%s/SKILL.md" % n)
    reach = [body]
    called = [s for s in steps if s != n and re.search(r"`%s[` ]" % re.escape(s), body)]
    for s in called:
        reach.append(read("skills/%s/SKILL.md" % s))
    for text in list(reach):
        for rel in POINTER.findall(text):
            reach.append(read(rel))
    after = set().union(*(keys(t) for t in reach))
    lost = sorted(before - after)
    counts.append("%s %d" % (n, len(before)))
    problems += ["LOST %s: %s" % (n, k) for k in lost]
print("\n".join(problems) or "clean " + ", ".join(counts))
PY
OUT="$(cat "$WORK/out.txt")"
case "$OUT" in
  clean*) ok "(1) every key (dotted, or a registered top-level name) the five orchestrators cited at $BASE is still cited by them or by what they point to (${OUT#clean })" ;;
  *) bad "(1) $OUT" ;;
esac
exit "$FAIL"
