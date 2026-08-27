#!/bin/bash
# Tests for scripts/measure-cost.sh. Each case prints one line; the script exits non-zero on any failure.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; MC="$ROOT/scripts/measure-cost.sh"; BUD="$ROOT/scripts/cost-budgets.json"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# (a) --check against the committed budgets exits 0
if /bin/bash "$MC" --check >/dev/null; then ok "(a) --check exits 0 on committed budgets"; else bad "(a) --check should exit 0"; fi

# (b) a lowered budget for pr is reported OVER, exit 1
python3 -c "import json,sys; d=json.load(open('$BUD')); d['bodies']['pr']=100; json.dump(d,open('$TMP/low.json','w'))"
OUT="$(/bin/bash "$MC" --check --budgets "$TMP/low.json")"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "^OVER skills/pr/SKILL.md"; then ok "(b) lowered budget → exit 1 with OVER skills/pr/SKILL.md"; else bad "(b) expected exit 1 + OVER line, got rc=$RC: $OUT"; fi

# (c) growing pr's body past its rounding headroom fails --check in a temp copy of the repo
cp -R "$ROOT" "$TMP/repo" && rm -rf "$TMP/repo/.git"
python3 -c "open('$TMP/repo/skills/pr/SKILL.md','a').write('x'*1200)"
if /bin/bash "$TMP/repo/scripts/measure-cost.sh" --check >/dev/null 2>&1; then bad "(c) +1,200 bytes (+400 tokens) on pr should fail --check"; else ok "(c) +400 tokens on pr → exit 1"; fi

# (d) a body with no budget entry → MISSING-BUDGET
mkdir -p "$TMP/repo/skills/zz-test" && printf -- '---\nname: zz-test\ndescription: test only\n---\nbody\n' > "$TMP/repo/skills/zz-test/SKILL.md"
OUT="$(/bin/bash "$TMP/repo/scripts/measure-cost.sh" --check --budgets "$BUD" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "^MISSING-BUDGET zz-test"; then ok "(d) unbudgeted body → MISSING-BUDGET zz-test, exit 1"; else bad "(d) expected MISSING-BUDGET zz-test rc=1, got rc=$RC: $OUT"; fi

# (d2) a budget with no body → STALE-BUDGET
python3 -c "import json; d=json.load(open('$BUD')); d['bodies']['ghost']=100; json.dump(d,open('$TMP/stale.json','w'))"
OUT="$(/bin/bash "$MC" --check --budgets "$TMP/stale.json")"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "^STALE-BUDGET ghost"; then ok "(d2) budget without a body → STALE-BUDGET ghost, exit 1"; else bad "(d2) expected STALE-BUDGET, got rc=$RC"; fi

# (d3) an unparsable budgets file fails loudly
echo '{ not json' > "$TMP/broken.json"
if /bin/bash "$MC" --check --budgets "$TMP/broken.json" >/dev/null 2>&1; then bad "(d3) broken budgets file should fail"; else ok "(d3) unparsable budgets → exit 1"; fi

# (e) --json parses and lists every body
N="$(/bin/bash "$MC" --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["bodies"]))')"
EXPECT="$(ls -d "$ROOT"/skills/*/SKILL.md | wc -l | tr -d ' ')"
if [ "$N" = "$EXPECT" ]; then ok "(e) --json lists $N bodies (= skills/*/SKILL.md count)"; else bad "(e) --json listed $N bodies, expected $EXPECT"; fi

# (f) --table --since HEAD shows zero Δ on every body row
DELTAS="$(/bin/bash "$MC" --table --since HEAD | grep '^| skills/' | awk -F'|' '{gsub(/ /,"",$7); print $7}' | sort -u)"
if [ "$DELTAS" = "+0" ]; then ok "(f) --table --since HEAD: every Δ is +0"; else bad "(f) expected only +0 deltas, got: $DELTAS"; fi

# (g) runs under /bin/bash explicitly (macOS 3.2), not only a newer bash
if /bin/bash "$MC" --check >/dev/null; then ok "(g) runs under /bin/bash $(/bin/bash -c 'echo $BASH_VERSION')"; else bad "(g) failed under /bin/bash"; fi

exit $FAIL
