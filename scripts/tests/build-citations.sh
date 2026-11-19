#!/bin/bash
# scripts/tests/build-citations.sh — the Build loop's steps are step skills now, so nothing under
# skills/ or schemas/ cites build-item by a removed step number (steps 1 to 6.5, 4a, 4b, 5a, 5b),
# no file of build-item's own holds those numbers as a token, the step numbers the loop keeps (0, 7
# and 8) are still its headings, and no seam registry caller names a removed step. Every match is
# anchored on both sides, so another skill's own step 5b or 6.5 never trips it. Both word orders
# count ("build-item step 4a", "step 4a of build-item"). After the check on the real tree, a mutation
# check plants each kind of stale citation in a copy of skills/ and schemas/ and requires the check
# to fail on every one, so a matcher that silently stopped matching cannot pass.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PYTHONDONTWRITEBYTECODE=1
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/check.py" <<'PY'
import json, os, re, sys

ROOT = sys.argv[1]
TEXT = (".md", ".py", ".json", ".sh", ".txt")
REMOVED = r"(?:6\.5|4a|4b|5a|5b|[1-6])"
# build-item, optionally quoted or possessive, optionally "SKILL.md", then "step"/"steps"/"§" or
# nothing, then a removed number that is not the start of a longer one (6.5, 10, 4c)
CITE = re.compile(r"(?<![\w/-])build-item(?:`|'s)?(?: SKILL\.md)?,? (?:steps? |§ ?)?" + REMOVED + r"(?![\w.]|\.\d)"
                  r"|(?<![\w.])(?:steps?|§) ?" + REMOVED + r"(?![\w.]|\.\d) (?:of|in) `?build-item(?![\w-])")
OWN = re.compile(r"(?<![\w.])(?:4a|4b|5a|5b)(?![\w])|(?<![\w])step 6\.5(?![\w.])")
problems = []


def files(top):
    for base, dirs, names in os.walk(os.path.join(ROOT, top)):
        dirs[:] = [d for d in dirs if d != "__pycache__"]
        for name in sorted(names):
            if name.endswith(TEXT):
                yield os.path.join(base, name)


for path in list(files("skills")) + list(files("schemas")):
    rel = os.path.relpath(path, ROOT)
    with open(path, encoding="utf-8") as handle:
        flat = re.sub(r"\s+", " ", handle.read())
    for match in CITE.finditer(flat):
        problems.append("%s cites a removed Build step: %r" % (rel, match.group(0)))
    if rel.startswith("skills/build-item/"):
        for match in OWN.finditer(flat):
            problems.append("%s holds a removed step number: %r" % (rel, flat[max(0, match.start() - 30):match.end() + 10]))

with open(os.path.join(ROOT, "skills/build-item/SKILL.md"), encoding="utf-8") as handle:
    body = handle.read()
for heading in ("## 0. ", "## 7. ", "## 8. "):
    if not re.search(r"^" + re.escape(heading), body, re.M):
        problems.append("skills/build-item/SKILL.md lost the heading %r that callers cite" % heading)

with open(os.path.join(ROOT, "schemas/seam-registry.json"), encoding="utf-8") as handle:
    registry = json.load(handle)
for hook in registry["hooks"]:
    for caller in hook.get("calledBy") or []:
        parts = caller.split()
        if parts[0] == "build-item" and len(parts) > 1 and re.match(r"^\d", parts[1]) and parts[1] not in ("0", "7", "8"):
            problems.append("seam %s: calledBy %r names a removed Build step" % (hook["key"], caller))
        if parts[0] == "ultracode-build" and len(parts) > 1 and parts[1] not in ("1", "2"):
            problems.append("seam %s: calledBy %r names a phase ultracode-build no longer has" % (hook["key"], caller))

for problem in problems:
    print("  FAIL %s" % problem)
if not problems:
    print("  ok   no removed Build step is cited under skills/ or schemas/; build-item keeps ## 0., ## 7. and ## 8.; every registry caller names a live step")
sys.exit(1 if problems else 0)
PY
python3 "$WORK/check.py" "$ROOT"; RC=$?

# the mutation check: every planted stale citation must fail the check
MUTATIONS=(
  "skills/merge-story/SKILL.md|see build-item step 5b for the merge"
  "skills/merge-story/SKILL.md|see step 5a of build-item for the merge"
  'skills/review-story/SKILL.md|as `build-item` 4a says'
  "skills/capture-findings/SKILL.md|steps 6.5 in build-item"
  "skills/build-item/references/progress-table.md|the row for 4b"
  "schemas/step-contracts.json|build-item § 3"
)
for mutation in "${MUTATIONS[@]}"; do
  file="${mutation%%|*}"; text="${mutation#*|}"
  copy="$WORK/copy"; rm -rf "$copy"; mkdir -p "$copy"
  cp -R "$ROOT/skills" "$ROOT/schemas" "$copy/"
  printf '\n%s\n' "$text" >> "$copy/$file"
  if python3 "$WORK/check.py" "$copy" >/dev/null; then
    echo "  FAIL mutation not caught: $text (in $file)"; RC=1
  fi
done
[ $RC -eq 0 ] && echo "  ok   (mutation check: ${#MUTATIONS[@]} planted stale citations, each caught)"
exit $RC
