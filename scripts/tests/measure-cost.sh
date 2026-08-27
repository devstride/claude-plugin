#!/bin/bash
# Tests for scripts/measure-cost.sh. Each case prints one line; the script exits non-zero on any failure.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; MC="$ROOT/scripts/measure-cost.sh"; BUD="$ROOT/scripts/cost-budgets.json"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# (a) --check against the committed budgets exits 0
OUT="$(/bin/bash "$MC" --check 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then ok "(a) --check exits 0 on committed budgets"; else bad "(a) --check should exit 0, got $RC:"; printf '%s\n' "$OUT" | sed 's/^/       /'; fi

# (b) a lowered budget for pr is reported OVER, exit 1
python3 -c "import json,sys; d=json.load(open('$BUD')); d['bodies']['pr']=100; json.dump(d,open('$TMP/low.json','w'))"
OUT="$(/bin/bash "$MC" --check --budgets "$TMP/low.json")"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "^OVER skills/pr/SKILL.md"; then ok "(b) lowered budget → exit 1 with OVER skills/pr/SKILL.md"; else bad "(b) expected exit 1 + OVER line, got rc=$RC: $OUT"; fi

# (c) growing pr's body past its rounding headroom fails --check in a temp copy of the repo
mkdir "$TMP/repo" && tar --exclude=.git -cf - -C "$ROOT" . | tar -xf - -C "$TMP/repo" || { bad "(c) could not copy the repo"; exit 1; }
python3 -c "open('$TMP/repo/skills/pr/SKILL.md','a').write('x'*1200)"
OUT="$(/bin/bash "$TMP/repo/scripts/measure-cost.sh" --check 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "^OVER skills/pr/SKILL.md"; then ok "(c) +400 tokens on pr → exit 1 with OVER skills/pr/SKILL.md"; else bad "(c) expected exit 1 + OVER line, got rc=$RC: $OUT"; fi

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
OUT="$(/bin/bash "$MC" --check --budgets "$TMP/broken.json" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "^BAD-BUDGETS"; then ok "(d3) unparsable budgets → exit 1 with BAD-BUDGETS"; else bad "(d3) expected exit 1 + BAD-BUDGETS, got rc=$RC: $OUT"; fi

# (e) --json parses and lists every body
N="$(/bin/bash "$MC" --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["bodies"]))')"
EXPECT="$(ls -d "$ROOT"/skills/*/SKILL.md | wc -l | tr -d ' ')"
if [ "$N" = "$EXPECT" ]; then ok "(e) --json lists $N bodies (= skills/*/SKILL.md count)"; else bad "(e) --json listed $N bodies, expected $EXPECT"; fi

# (f) --table --since HEAD: every body row's Δ equals tokens(now) − tokens(HEAD blob), computed independently
TABLE="$(/bin/bash "$MC" --table --since HEAD)"
if ! printf '%s' "$TABLE" | head -1 | grep -q '^<!-- scripts/measure-cost.sh --table --since HEAD @'; then bad "(f) missing provenance comment"; fi
FBAD=0; ROWS=0
while IFS='|' read -r _ path rb rt nb nt delta _; do
  path="$(echo "$path" | tr -d ' ')"; [ -n "$path" ] || continue; ROWS=$((ROWS+1))
  HB="$(git -C "$ROOT" show "HEAD:$path" 2>/dev/null | wc -c | tr -d ' ')"; NB="$(wc -c < "$ROOT/$path" | tr -d ' ')"
  EXP="$(python3 -c "import math;print('%+d' % (math.ceil($NB/3)-math.ceil($HB/3)))")"; GOT="$(echo "$delta" | tr -d ' ')"
  [ "$GOT" = "$EXP" ] || { FBAD=1; echo "       $path: table Δ $GOT, recomputed $EXP"; }
done <<EOF_ROWS
$(printf '%s\n' "$TABLE" | grep '^| skills/' | grep -v removed)
EOF_ROWS
if [ "$FBAD" -eq 0 ] && [ "$ROWS" -gt 0 ] && printf '%s' "$TABLE" | grep -q '^| alwaysOn.context' && printf '%s' "$TABLE" | grep -q '^| \*\*total'; then ok "(f) --table --since HEAD: $ROWS body rows, every Δ matches an independent recomputation; always-on and totals rows present"; else [ "$FBAD" -eq 0 ] && bad "(f) table shape wrong (rows=$ROWS, always-on/totals rows missing?)" || bad "(f) a Δ disagrees with recomputation"; fi

# (g) runs under /bin/bash explicitly (macOS 3.2), not only a newer bash
OUT="$(/bin/bash "$MC" --check 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then ok "(g) runs under /bin/bash $(/bin/bash -c 'echo $BASH_VERSION')"; else bad "(g) failed under /bin/bash (rc=$RC): $(printf '%s' "$OUT" | head -3)"; fi

# (h) an option with no value is a usage error, never a hang
if perl -e 'alarm 5; exec @ARGV' /bin/bash "$MC" --since >/dev/null 2>&1; then bad "(h) --since with no value should fail"; else RC=$?; [ "$RC" -eq 2 ] && ok "(h) --since with no value → usage error, exit 2" || bad "(h) expected exit 2, got $RC (142 = hung until the alarm)"; fi

# (i) a skill with disable-model-invocation: true is not in the always-on listing
BEFORE="$(/bin/bash "$TMP/repo/scripts/measure-cost.sh" --json --budgets "$BUD" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["alwaysOn"]["context"]["bytes"])')"
printf -- '---\nname: zz-test\ndescription: test only\ndisable-model-invocation: true\n---\nbody\n' > "$TMP/repo/skills/zz-test/SKILL.md"
AFTER="$(/bin/bash "$TMP/repo/scripts/measure-cost.sh" --json --budgets "$BUD" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["alwaysOn"]["context"]["bytes"])')"
if [ "$AFTER" -lt "$BEFORE" ]; then ok "(i) disable-model-invocation skill leaves the always-on listing ($BEFORE → $AFTER bytes)"; else bad "(i) expected always-on bytes to drop when zz-test became user-only ($BEFORE → $AFTER)"; fi

# (j) references are discovered recursively (the setup templates live one level down)
if /bin/bash "$MC" --json | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if any("/references/" in k and k.count("/")>=4 for k in d["references"]) else 1)'; then ok "(j) nested references are measured"; else bad "(j) no nested reference found — discovery is not recursive"; fi

exit $FAIL
