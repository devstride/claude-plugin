#!/bin/bash
# scripts/tests/step-skills.sh — the ten step skills keep their shape (name, short description,
# small body, the pointer to the shared rule, a verdict that matches the registry), the
# orchestrators call them, the text moved out of the orchestrators lives in a step or its contract
# and nowhere else, and no existing skill was removed or renamed.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

STEPS="update-docs sync-knowledge-base write-release-notes pre-ship post-deploy local-environment lease-checkout return-checkout classify-release pre-merge-check"

# (1) structure, and (2) each Verdict section equals the registry's stepVerdict for its seam
python3 - "$ROOT" $STEPS > "$WORK/structure.txt" 2>&1 <<'PY'
import json, math, os, re, sys
root, steps = sys.argv[1], sys.argv[2:]
reg = json.load(open(os.path.join(root, "schemas/seam-registry.json")))
pointer = "${CLAUDE_PLUGIN_ROOT}/skills/release/references/step-skills.md"
problems = []
for n in steps:
    path = os.path.join(root, "skills", n, "SKILL.md")
    if not os.path.isfile(path):
        problems.append("MISSING %s" % n); continue
    raw = open(path, "rb").read(); text = raw.decode("utf-8")
    m = re.match(r"---\n(.*?)\n---\n", text, re.S)
    if not m:
        problems.append("FRONTMATTER %s" % n); continue
    fm = dict(re.findall(r"^(\w[\w-]*):\s*(.*)$", m.group(1), re.M))
    if fm.get("name") != n:
        problems.append("NAME %s is %r" % (n, fm.get("name")))
    desc = fm.get("description", "").strip().strip(chr(34))
    if not desc or len(desc.split()) > 25:
        problems.append("DESCRIPTION %s has %d words" % (n, len(desc.split())))
    tokens = math.ceil(len(raw) / 3)  # the plugin's own measure (scripts/measure-cost.sh)
    if tokens > 1200:
        problems.append("BODY %s is %d tokens" % (n, tokens))
    if pointer not in text:
        problems.append("POINTER %s does not open with the step-skills.md pointer" % n)
    sec = re.search(r"^## Verdict\n(.*?)(?=^## |\Z)", text, re.S | re.M)
    if not sec:
        problems.append("VERDICT %s has no ## Verdict section" % n); continue
    said = re.findall(r"`([^`]+)`", sec.group(1))
    hooks = [h for h in reg["hooks"] if h.get("step") == n]
    if not hooks:
        problems.append("REGISTRY no hook names step %s" % n)
    for h in hooks:
        if h.get("stepVerdict") != said:
            problems.append("VERDICT %s says %r, registry %s has %r" % (n, said, h["key"], h.get("stepVerdict")))
print("\n".join(problems) or "clean")
PY
OUT="$(cat "$WORK/structure.txt")"
[ "$OUT" = clean ] && ok "(1-2) ten steps: name = directory, description <= 25 words, body <= 1,200 tokens, the pointer, and a Verdict equal to the registry's stepVerdict" \
  || bad "(1-2) $OUT"

# (3) each orchestrator calls each step at its call site: the step's name, with the mode that site
# uses, inside the section that runs it (a mention elsewhere in the body does not count)
python3 - "$ROOT" > "$WORK/calls.txt" 2>&1 <<'PY2'
import re, sys
root = sys.argv[1]
SITES = [  # skill, the heading the section starts with, the call it must contain
    ("release", "## 0. ", "`classify-release`"),
    ("release", "## 2. ", "`pre-ship release select`"),
    ("release", "## 2b. ", "`classify-release`"),
    ("release", "## 2b. ", "`pre-ship release run`"),
    ("release", "## 4. ", "`pre-merge-check`"),
    ("release", "### 5a. ", "`post-deploy check`"),
    ("release", "### 5c. ", "`update-docs update`"),
    ("release", "### 5c. ", "`sync-knowledge-base sync`"),
    ("release", "### 5d. ", "`post-deploy close-out`"),
    ("release", "### 5e. ", "`write-release-notes`"),
    ("build-item", "## 0. ", "`lease-checkout`"),
    ("build-item", "## 0. ", "`return-checkout`"),  # every exit from step 0 returns the lease
    ("build-item", "## 7. ", "`return-checkout`"),
    ("build-item", "## 8. ", "`update-docs update`"),
    ("pr", "## 2. ", "`pre-ship pr select`"),
    ("pr", "## 2b. ", "`pre-ship pr run`"),
    ("branch-hotfix", "## The local environment", "`local-environment recreate`"),
    ("branch-hotfix", "## The local environment", "`local-environment migrate`"),
]
def section(text, head):
    lines = text.splitlines(); level = len(head) - len(head.lstrip("#"))
    out, on = [], False
    for line in lines:
        m = re.match(r"(#+) ", line)
        if on and m and len(m.group(1)) <= level:
            break
        if line.startswith(head):
            on = True
        if on:
            out.append(line)
    return " ".join(" ".join(out).split())
missing = []
for skill, head, call in SITES:
    body = open("%s/skills/%s/SKILL.md" % (root, skill), encoding="utf-8").read()
    sec = section(body, head)
    if not sec:
        missing.append("%s has no section %r" % (skill, head.strip()))
    elif call not in sec:
        missing.append("%s %s does not call %s" % (skill, head.strip(), call))
print("\n".join(missing) or "clean %d" % len(SITES))
PY2
OUT="$(cat "$WORK/calls.txt")"
case "$OUT" in
  clean*) ok "(3) every orchestrator calls each step, with its mode, inside the section that runs it (${OUT#clean } call sites)" ;;
  *) bad "(3) $OUT" ;;
esac

# (4) text that really stood in an orchestrator before the split now lives in a step (whitespace and
# line wraps collapsed before matching) and no longer in that orchestrator. The base is PINNED to the
# last release before the split, never the moving main, which holds the split bodies once merged.
BASE="${STEP_SPLIT_BASE:-devstride--v3.19.0}"
flat() { tr -s ' \t\n' '   '; }
if ! git -C "$ROOT" rev-parse --verify -q "$BASE^{commit}" >/dev/null; then
  # a shallow or tagless clone: fetch just that tag, quietly, before deciding
  git -C "$ROOT" fetch -q --depth=1 origin tag "$BASE" >/dev/null 2>&1 || :
fi
if ! git -C "$ROOT" rev-parse --verify -q "$BASE^{commit}" >/dev/null; then
  bad "(4) the base $BASE is not in this clone and could not be fetched: run \`git fetch origin tag $BASE\` (or set STEP_SPLIT_BASE to a ref that holds the pre-split bodies) — never skipped, or this test proves nothing"
else
  moved=""
  moved() {  # <needle> <new home> <orchestrator>
    local n="$1" home="$2" orch="$3"
    git -C "$ROOT" show "$BASE:skills/$orch/SKILL.md" 2>/dev/null | flat | grep -qF -- "$n" || moved="$moved [never in $orch at $BASE: $n]"
    flat < "$ROOT/skills/$home/SKILL.md" | grep -qF -- "$n" || moved="$moved [absent from $home: $n]"
    ! flat < "$ROOT/skills/$orch/SKILL.md" | grep -qF -- "$n" || moved="$moved [still in $orch: $n]"
  }
  moved "Run each selected entry UNCONDITIONALLY" pre-ship release
  moved "SHA-pinned three-dot local diff" pre-ship pr
  moved "renames on BOTH source and destination" pre-ship pr
  moved "never \`gh pr view --json files\`" pre-ship pr
  moved "a foreground kill looks like a clean pass" pre-ship pr
  moved "a foreground kill looks like a clean pass" pre-ship release
  moved "owns the pages" update-docs release
  moved "no \`.claude/skills/<name>/SKILL.md\`" update-docs build-item
  [ -z "$moved" ] && ok "(4) eight passages that stood in an orchestrator at $BASE live in their step and left it" || bad "(4)$moved"
fi

# (5) every new reference is a contract with a Cited by list
refs=""
for f in skills/release/references/step-skills.md skills/release/references/release-safety-hooks.md \
         skills/build-item/references/checkout-pool-commands.md; do
  head -3 "$ROOT/$f" | grep -q '^load: ' && grep -q '^## Cited by' "$ROOT/$f" || refs="$refs $f"
done
[ -z "$refs" ] && ok "(5) the three new contracts carry load: frontmatter and a Cited by list" || bad "(5)$refs"

# (6) no skill directory that existed before the steps was removed or renamed
BEFORE="branch-feature branch-hotfix build-item ci-audit comprehend-plan create-defect create-story doctor insert-defect insert-story plan pr push rationalize-gantt rebalance release review setup ultracode-build update"
gone=""; for s in $BEFORE; do [ -f "$ROOT/skills/$s/SKILL.md" ] || gone="$gone $s"; done
[ -z "$gone" ] && ok "(6) the twenty existing skills are all still present" || bad "(6) removed or renamed:$gone"

exit "$FAIL"
