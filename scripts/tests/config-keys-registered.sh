#!/bin/bash
# Tests for scripts/check-config-keys.py: every config key the shipped text cites is registered in
# schemas/seam-registry.json. Runs once on the real corpus, then on small scratch corpora (--root)
# built per case, so a miss is proved to be caught with its file and line.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; SCAN="$ROOT/scripts/check-config-keys.py"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

OUT="$(python3 "$SCAN" 2>&1)"; RC=$?
[ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q "^CONFIG KEYS: ok ([0-9]* tokens)$" \
  && ok "(1) the shipped corpus cites only registered keys ($OUT)" || bad "(1) exit $RC: $OUT"

# scratch corpus: a two-key registry, an ignore file, a README and one skill with a reference
corpus() {
  rm -rf "$WORK/r"; mkdir -p "$WORK/r/schemas" "$WORK/r/scripts" "$WORK/r/skills/demo/references"
  cat > "$WORK/r/schemas/seam-registry.json" <<'JSON'
{"hooks": [{"key": "review.localCommand", "valueType": "string"}],
 "settings": [{"key": "epicIntegrationBranches.fastStoryMerges.enabled", "type": "boolean"},
              {"key": "preShipChecks[].command", "type": "string"},
              {"key": "release.clearance.phaseBudgetMinutes", "type": "any"}]}
JSON
  printf '# reason\nuser.login   the GitHub API field, not a config key\n' > "$WORK/r/scripts/config-key-scan.ignore"
  printf 'Set `review.localCommand`.\n' > "$WORK/r/README.md"
  printf 'Read `release.clearance` and `fastStoryMerges.enabled`.\n' > "$WORK/r/skills/demo/SKILL.md"
  printf 'Nothing here.\n' > "$WORK/r/skills/demo/references/notes.md"
}
scan() { OUT="$(python3 "$SCAN" --root "$WORK/r" 2>&1)"; RC=$?; }

corpus; scan
[ "$RC" = 0 ] && ok "(2) exact keys, object prefixes and segment-boundary suffixes pass" || bad "(2) exit $RC: $OUT"

corpus; printf 'line one\nThe claim lasts `claims.expiryMinutes` minutes.\n' >> "$WORK/r/skills/demo/SKILL.md"; scan
[ "$RC" = 1 ] && printf '%s' "$OUT" | grep -qx "UNREGISTERED skills/demo/SKILL.md:3: claims.expiryMinutes" \
  && ok "(3) an unregistered key fails with its file and line" || bad "(3) exit $RC: $OUT"

corpus; printf 'Read `user.login`, `package.json`, `head_commit.id` and `a.b c`.\n' >> "$WORK/r/skills/demo/references/notes.md"; scan
[ "$RC" = 0 ] && ok "(4) ignored tokens, file names, underscored fields and non-token spans are skipped" || bad "(4) exit $RC: $OUT"

corpus; printf 'Set `Merges.enabled`.\n' >> "$WORK/r/README.md"; scan
[ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q "UNREGISTERED README.md:2: Merges.enabled" \
  && ok "(5) a suffix must start at a segment boundary" || bad "(5) exit $RC: $OUT"

corpus; printf 'Set `fastStoryMerges.disabled`.\n' >> "$WORK/r/README.md"; scan
[ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q "UNREGISTERED README.md:2: fastStoryMerges.disabled" \
  && ok "(6) a suffix form passes only when a registered key ends with it" || bad "(6) exit $RC: $OUT"

corpus; cat >> "$WORK/r/skills/demo/references/notes.md" <<'MD'
Example:
```json
{
  "review": { "localCommand": "codex exec", "_why": "skipped" },
  "release": { "clearance": { "phaseBudgetMinutes": { "anyKnob": 5 } } },
  "preShipChecks": [{ "command": "make check" }]
}
```
MD
scan
[ "$RC" = 0 ] && ok "(7) a JSON fence of registered keys passes (_ keys and opaque values skipped)" || bad "(7) exit $RC: $OUT"

corpus; cat >> "$WORK/r/skills/demo/references/notes.md" <<'MD'
```json
{
  "review": {
    "localCommand": "codex exec",
    "localComand": "typo"
  }
}
```
MD
scan
[ "$RC" = 1 ] && printf '%s' "$OUT" | grep -qx "UNREGISTERED skills/demo/references/notes.md:6: review.localComand" \
  && ok "(8) a JSON fence with an unknown nested key fails at its line" || bad "(8) exit $RC: $OUT"

corpus; printf '```json\n{ "review": { "localComand": 1 } }\n```\n' >> "$WORK/r/skills/demo/SKILL.md"; scan
[ "$RC" = 0 ] && ok "(9) JSON fences are walked in references only, not in a SKILL.md body" || bad "(9) exit $RC: $OUT"

corpus; cat >> "$WORK/r/skills/demo/references/notes.md" <<'MD'
```json
{
  "review": { "localCommand": "codex exec" },
  "reviewers": ["codex"]
}
```
MD
scan
[ "$RC" = 1 ] && printf '%s' "$OUT" | grep -qx "UNREGISTERED skills/demo/references/notes.md:5: reviewers" \
  && ok "(9a) in a config fence, an unregistered top-level key fails at its line" || bad "(9a) exit $RC: $OUT"

corpus; cat >> "$WORK/r/skills/demo/references/notes.md" <<'MD'
```json
{ "release": { "clearance": null }, "user": { "login": "x" }, "_readme": "skipped", "$schema": "x" }
```
```json
{ "hooks": { "SessionStart": [] }, "permissions": { "allow": [] } }
```
MD
printf 'user   a foreign top-level key in a fence, listed on purpose\n' >> "$WORK/r/scripts/config-key-scan.ignore"
scan
[ "$RC" = 0 ] && ok "(9b) an ignore-listed top-level key, _ keys and \$schema pass; a fence that is not a config is not checked" || bad "(9b) exit $RC: $OUT"

corpus; rm "$WORK/r/schemas/seam-registry.json"; scan
[ "$RC" = 2 ] && ok "(10) a missing registry is exit 2" || bad "(10) exit $RC: $OUT"

exit "$FAIL"
