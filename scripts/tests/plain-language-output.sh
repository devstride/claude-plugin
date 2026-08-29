#!/bin/bash
# Deterministic contract test for human-facing output loading and recap ownership.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REFERENCE="skills/build-item/references/plain-language-output.md"
FAIL=0

ok() { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; FAIL=1; }
has() { [ -f "$ROOT/$1" ] && grep -qF -- "$2" "$ROOT/$1"; }

# Match exact prose while ignoring Markdown-only line wrapping.
has_normalized_once() {
  python3 - "$ROOT/$1" "$2" <<'PY'
import re
import sys

path, expected = sys.argv[1:]
with open(path, encoding="utf-8") as source:
    actual = re.sub(r"\s+", " ", source.read()).strip()
expected = re.sub(r"\s+", " ", expected).strip()
raise SystemExit(0 if actual.count(expected) == 1 else 1)
PY
}

if [ -s "$ROOT/$REFERENCE" ]; then
  ok "(1) canonical simplest-accurate-words reference exists"
else
  bad "(1) missing or empty $REFERENCE"
fi

POINTER='**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.'
MISSING_POINTERS=""
for skill in "$ROOT"/skills/*/SKILL.md; do
  relative="${skill#"$ROOT/"}"
  if ! has_normalized_once "$relative" "$POINTER"; then
    MISSING_POINTERS="${MISSING_POINTERS}${MISSING_POINTERS:+, }$relative"
  fi
done
if [ -z "$MISSING_POINTERS" ]; then
  ok "(2) every user-invocable skill loads human output once per top-level run"
else
  bad "(2) missing, changed, or repeated runtime pointer: $MISSING_POINTERS"
fi

if has "$REFERENCE" '**After building one item**' &&
   has "$REFERENCE" 'Built' &&
   has "$REFERENCE" 'Checked' &&
   has "$REFERENCE" 'Next'; then
  ok "(3) build-item recap keeps built, checked, and next markers"
else
  bad "(3) build-item recap markers missing from $REFERENCE"
fi

if has skills/ultracode-build/SKILL.md '**Human recap.**'; then
  ok "(4) ultracode handback has an explicit human recap"
else
  bad "(4) ultracode human recap marker missing"
fi

if has "$REFERENCE" 'Merged / Released' &&
   has skills/release/SKILL.md '**Human recap.**'; then
  ok "(5) release recap has an explicit merged/released outcome"
else
  bad "(5) release recap markers missing"
fi

if has "$REFERENCE" '**For doctor**' &&
   has "$REFERENCE" 'Found:' &&
   has "$REFERENCE" 'Why it matters:' &&
   has "$REFERENCE" 'Fix:' &&
   has "$REFERENCE" 'Changed:' &&
   has "$REFERENCE" 'Result:' &&
   has skills/doctor/SKILL.md '**Human recap.**'; then
  ok "(6) doctor recap preserves finding, impact, fix, change, and result"
else
  bad "(6) doctor recap markers missing"
fi

if has skills/build-item/SKILL.md '**Human recap.**' &&
   has skills/pr/SKILL.md '**Human recap.**' &&
   has skills/review/SKILL.md '**Human recap.**'; then
  ok "(7) build-item, PR, and review own explicit terminal recaps"
else
  bad "(7) build-item, PR, or review human recap marker missing"
fi

if has skills/build-item/SKILL.md 'After a direct pull-request merge' &&
   has skills/build-item/SKILL.md 'Merged / Released'; then
  ok "(8) direct pull-request merges own the merge recap"
else
  bad "(8) direct pull-request merge recap is missing"
fi

RAW_CONTRADICTIONS=""
for phrase in 'relay its verdict and fix verbatim' 'Relay exactly what it reports' \
  'relay what it reports' 'relays what they report' 'reports what it printed'; do
  if grep -R -qF -- "$phrase" "$ROOT/skills"; then
    RAW_CONTRADICTIONS="${RAW_CONTRADICTIONS}${RAW_CONTRADICTIONS:+, }$phrase"
  fi
done
if [ -z "$RAW_CONTRADICTIONS" ]; then
  ok "(9) no skill requires raw agent or tool prose"
else
  bad "(9) raw-output instructions remain: $RAW_CONTRADICTIONS"
fi

if has_normalized_once "$REFERENCE" 'number at most three related decisions' &&
   has skills/plan/SKILL.md 'no more than three' &&
   has skills/setup/SKILL.md 'asked in dependency order'; then
  ok "(10) planning and setup questions follow the short, plain decision contract"
else
  bad "(10) a high-volume question flow contradicts the human-output contract"
fi

exit "$FAIL"
