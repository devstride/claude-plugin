#!/bin/bash
# Tests for skills/setup/scripts/check-review-engine.sh — no network, no codex binary needed:
# the checker parses the command string, it never runs the engine.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; SC="$ROOT/skills/setup/scripts/check-review-engine.sh"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export CODEX_HOME="$TMP/codex"; mkdir -p "$CODEX_HOME"   # no config.toml unless a case writes one
chk() { /bin/bash "$SC" "$@" 2>&1; }

# (1) the catalogued context-mode Codex template passes
OUT="$(chk --command 'codex exec --ephemeral --sandbox read-only -c model_reasoning_effort="<effort>" -c mcp_servers.devstride.enabled=false <context>')"; RC=$?
if [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q '^PASS .*--sandbox read-only'; then ok "(1) codex exec with --sandbox read-only → PASS"; else bad "(1) rc=$RC $OUT"; fi

# (2) the shape the field run actually had: a hand-written codex review with no sandbox flag
printf 'model = "gpt-5"\nsandbox_mode = "danger-full-access"\n' > "$CODEX_HOME/config.toml"
OUT="$(chk --command 'codex review --base <base> -c model_reasoning_effort="xhigh"')"; RC=$?
if [ $RC -eq 1 ] && printf '%s' "$OUT" | grep -q '^FAIL .*MISSING READ-ONLY FLAG' \
   && printf '%s' "$OUT" | grep -q 'danger-full-access' && printf '%s' "$OUT" | grep -q 'Fix: add `-c sandbox_mode=read-only`'; then
  ok "(2) codex review without the flag → FAIL, names the machine default it ran under, exact fix"; else bad "(2) rc=$RC $OUT"; fi
rm -f "$CODEX_HOME/config.toml"

# (3) codex review with its own flag passes; the exec flag is NOT accepted there
OUT="$(chk --command 'codex review --base <base> -c sandbox_mode=read-only -c mcp_servers.devstride.enabled=false')"; RC=$?
if [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q '^PASS'; then ok "(3) codex review with -c sandbox_mode=read-only → PASS"; else bad "(3) rc=$RC $OUT"; fi
OUT="$(chk --command 'codex review --sandbox read-only --base <base>')"; RC=$?
if [ $RC -eq 1 ] && printf '%s' "$OUT" | grep -q 'MISSING READ-ONLY FLAG'; then ok "(3b) codex review with the exec-only flag → FAIL (the parser refuses it)"; else bad "(3b) rc=$RC $OUT"; fi

# (4) the legacy `codex exec review` form: -s read-only counts only BEFORE the subcommand
OUT="$(chk --command 'codex exec review --sandbox read-only --base <base>')"; RC=$?
if [ $RC -eq 1 ] && printf '%s' "$OUT" | grep -q 'never took effect'; then ok "(4) exec review with --sandbox after the subcommand → FAIL, says it never took effect"; else bad "(4) rc=$RC $OUT"; fi
OUT="$(chk --command 'codex exec -s read-only review --base <base>')"; RC=$?
if [ $RC -eq 0 ]; then ok "(4b) exec -s read-only review → PASS"; else bad "(4b) rc=$RC $OUT"; fi
OUT="$(chk --command 'codex exec review --base <base> -c sandbox_mode=read-only')"; RC=$?
if [ $RC -eq 0 ]; then ok "(4c) exec review with -c sandbox_mode=read-only → PASS"; else bad "(4c) rc=$RC $OUT"; fi

# (5) a disabler or a widened sandbox fails whatever the engine
for c in 'codex exec --dangerously-bypass-approvals-and-sandbox <context>' 'codex exec --sandbox workspace-write <context>' 'codex review -c sandbox_mode=danger-full-access --base <base>' 'somecli --full-auto <context>'; do
  OUT="$(chk --command "$c")"; RC=$?
  if [ $RC -eq 1 ] && printf '%s' "$OUT" | grep -q 'can write to the tree it reviews'; then ok "(5) $c → FAIL"; else bad "(5) $c rc=$RC $OUT"; fi
done

# (6) an uncatalogued engine is UNVERIFIABLE, never FAIL, and exit 0
OUT="$(chk --command 'gemini -p - --sandbox')"; RC=$?
if [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q '^UNVERIFIABLE .*held to the contract only'; then ok "(6) uncatalogued engine → UNVERIFIABLE, exit 0"; else bad "(6) rc=$RC $OUT"; fi

# (7) config mode: null is a PASS, a missing assist key is silent, both keys are checked
mkdir -p "$TMP/repo/.claude"
printf '{"review":{"localCommand":null}}' > "$TMP/repo/.claude/ds-config.json"
OUT="$(chk --config "$TMP/repo/.claude/ds-config.json")"; RC=$?
if [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q '^PASS review.localCommand: null'; then ok "(7) localCommand null → PASS (legal empty roster)"; else bad "(7) rc=$RC $OUT"; fi
printf '{"review":{"localCommand":"codex exec --sandbox read-only <context>","localAssistCommand":"codex exec <context>"}}' > "$TMP/repo/.claude/ds-config.json"
OUT="$(chk --config "$TMP/repo/.claude/ds-config.json")"; RC=$?
if [ $RC -eq 1 ] && printf '%s' "$OUT" | grep -q '^PASS review.localCommand' && printf '%s' "$OUT" | grep -q '^FAIL review.localAssistCommand'; then ok "(7b) both keys checked; the assist command without the flag fails the run"; else bad "(7b) rc=$RC $OUT"; fi
OUT="$(chk --config "$TMP/repo/.claude/missing.json")"; RC=$?
if [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q '^UNVERIFIABLE: no config'; then ok "(7c) no config → UNVERIFIABLE, exit 0"; else bad "(7c) rc=$RC $OUT"; fi

# (8) --json carries the same verdicts
J="$(chk --json --command 'codex exec <context>')"
if printf '%s' "$J" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["failed"] and d["results"][0]["verdict"]=="FAIL" else 1)'; then ok "(8) --json"; else bad "(8) $J"; fi

# (9) every command template the catalogue ships must pass its own check — the catalogue can
#     never again publish a template that runs the reviewer with write access. The generic
#     `<cli> …` shape is uncatalogued by construction and may be UNVERIFIABLE, never FAIL.
N=0
while IFS= read -r cmd; do
  N=$((N + 1)); OUT="$(chk --command "$cmd")"; RC=$?
  if [ $RC -eq 0 ]; then ok "(9.$N) catalogue template passes: ${cmd:0:60}…"; else bad "(9.$N) catalogue template FAILS its own check: $cmd → $OUT"; fi
done < <(python3 - "$ROOT/skills/setup/references/review-engines.md" <<'PY'
import json, re, sys
text = open(sys.argv[1]).read()
for m in re.finditer(r'"local(?:Assist)?Command"\s*:\s*("(?:[^"\\]|\\.)*")', text):
    print(json.loads(m.group(1)))
PY
)
[ "$N" -ge 3 ] && ok "(9) $N catalogue templates found" || bad "(9) expected at least 3 catalogue templates, found $N"
exit $FAIL
