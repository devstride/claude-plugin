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

# (3) the orchestrators call the steps they own
missing=""
need() {  # <skill> <step>...
  local skill="$1"; shift
  for s in "$@"; do grep -q "\`$s" "$ROOT/skills/$skill/SKILL.md" || missing="$missing $skill→$s"; done
}
need release classify-release pre-ship pre-merge-check post-deploy update-docs sync-knowledge-base write-release-notes
need build-item lease-checkout return-checkout update-docs
need pr pre-ship
need branch-hotfix local-environment
[ -z "$missing" ] && ok "(3) release, build-item, pr and branch-hotfix name every step they call" || bad "(3) not called:$missing"

# (4) moved needles live in a step or its contract, and no longer in the orchestrator body
moved=""
moved() {  # <needle> <new home> <old body>
  grep -qF -- "$1" "$ROOT/$2" || moved="$moved [absent from $2: $1]"
  ! grep -qF -- "$1" "$ROOT/$3" || moved="$moved [still in $3: $1]"
}
moved "Run each selected entry UNCONDITIONALLY" skills/pre-ship/SKILL.md skills/release/SKILL.md
moved "SHA-pinned three-dot local diff" skills/pre-ship/SKILL.md skills/pr/SKILL.md
moved "renames on BOTH source and destination" skills/pre-ship/SKILL.md skills/pr/SKILL.md
moved "| \`FAIL\` | **STOP.**" skills/release/references/post-deploy-check.md skills/release/SKILL.md
moved "| \`NOT RUN\` | Report it as this-run degradation" skills/release/references/post-deploy-check.md skills/release/SKILL.md
moved "owns the pages" skills/update-docs/SKILL.md skills/release/SKILL.md
moved "\`/devstride:setup docs\` (it scaffolds the skill)" skills/update-docs/SKILL.md skills/build-item/SKILL.md
[ -z "$moved" ] && ok "(4) moved text lives in its step or contract and left the orchestrator" || bad "(4)$moved"

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
