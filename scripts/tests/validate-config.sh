#!/bin/bash
# Tests for skills/doctor/scripts/validate-config.py — the config shape check doctor and setup run —
# against the committed schema, using the synthetic configs in scripts/tests/fixtures/config/
# (none is a real repository's) and scratch configs written per case.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; VAL="$ROOT/skills/doctor/scripts/validate-config.py"
SCHEMA="$ROOT/schemas/ds-config.schema.json"; FIX="$ROOT/scripts/tests/fixtures/config"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
run() { OUT="$(python3 "$VAL" "$@" --schema "$SCHEMA" 2>&1)"; RC=$?; }
cfg() { printf '%s\n' "$1" > "$WORK/c.json"; run "$WORK/c.json"; }
# expect LABEL EXIT FIRST-LINE-PATTERN [BODY-PATTERN]
expect() {
  if [ "$RC" = "$2" ] && printf '%s\n' "$OUT" | head -1 | grep -q -- "$3" \
     && { [ -z "${4:-}" ] || printf '%s\n' "$OUT" | grep -q -- "$4"; }; then ok "$1"; else bad "$1 — exit $RC: $OUT"; fi
}
CLEAN="^CONFIG: 0 error(s), 0 warning(s) against schema [0-9]*\.[0-9]*\.[0-9]*$"

run "$FIX/minimal.json"; expect "(1) a minimal config is clean, and the first line names the schema version" 0 "$CLEAN"
run "$FIX/full.json"; expect "(2) the full-coverage config is clean" 0 "$CLEAN"
run "$FIX/commands-clearance.json"; expect "(3) the commands shape of release.clearance is clean" 0 "$CLEAN"
run "$ROOT/.claude/ds-config.json"; expect "(4) this repository's own config is clean" 0 "$CLEAN"

# (5) the full-coverage fixtures name every registered key (deprecated ones aside)
MISSING="$(python3 - "$ROOT" <<'PY'
import json, sys
root = sys.argv[1]
reg = json.load(open(root + "/schemas/seam-registry.json"))
keys = [e["key"] for e in reg["hooks"]] + [e["key"] for e in reg["settings"] if not e.get("deprecated")]
def paths(o, p=""):
    if isinstance(o, dict):
        for k, v in o.items():
            q = p + "." + k if p else k
            yield q
            yield from paths(v, q)
    elif isinstance(o, list):
        for x in o:
            yield from paths(x, p + "[]")
have = set()
for f in ("full.json", "commands-clearance.json"):
    have |= set(paths(json.load(open(root + "/scripts/tests/fixtures/config/" + f))))
print(" ".join(k for k in keys if k not in have))
PY
)"
[ -z "$MISSING" ] && ok "(5) the full-coverage fixtures name every registered key" || bad "(5) not covered: $MISSING"

cfg '{"review": {"localComand": "x"}}'
expect "(6) a misspelled key is a WARN with the likely key" 0 "^CONFIG: 0 error(s), 1 warning(s)" "^WARN review.localComand: unknown key; did you mean review.localCommand?$"

cfg '{"_readme": "x", "$schema": "y", "review": {"_localCommand_readme": "z"}, "preShipChecks": [{"_why": 1, "command": "c", "when": "perPr"}]}'
expect "(7) keys starting with _ and \$schema are silent" 0 "$CLEAN"

cfg '{"repoLocalKeys": ["mergePath", "review.teamExtras"], "mergePath": {"anything": 1}, "review": {"teamExtras": {"x": 1}}}'
expect "(8a) keys at a repoLocalKeys prefix are silent, top-level or nested" 0 "$CLEAN"
cfg '{"repoLocalKeys": ["mergePath"], "mergePath": {"anything": 1}, "mergePathX": 1}'
expect "(8b) a prefix covers its own subtree only, not a longer name" 0 "^CONFIG: 0 error(s), 1 warning(s)" "^WARN mergePathX: unknown key"

cfg '{"verify": {"test": ["make", "test"]}}'
expect "(9) verify.test as a list is an ERROR" 1 "^CONFIG: 1 error(s), 0 warning(s)" "^ERROR verify.test: expected string or null, found array"

cfg '{"release": {"clearance": {"provider": "github", "commands": {"claim": "c", "status": "s", "heartbeat": "h", "release": "r", "adopt": "a"}}}}'
expect "(10) release.clearance with both shapes is an ERROR" 1 "^CONFIG: 1 error(s)" "^ERROR release.clearance: sets both \`provider\` and \`commands\`"

cfg '{"release": {"clearance": {"provider": "gitlab"}}}'
expect "(11) a clearance provider other than github is an ERROR" 1 "^CONFIG: 1 error(s)" '^ERROR release.clearance.provider: "gitlab" is not one of "github"$'

cfg '{"release": {"clearance": {"commands": {"claim": "c", "status": "s"}}}}'
expect "(12) a commands clearance missing a verb is an ERROR naming it" 1 "^CONFIG: 3 error(s)" "^ERROR release.clearance.commands: missing required key \`heartbeat\`"

cfg '{"release": {"clearance": {}}}'
expect "(13) a clearance object naming neither shape is an ERROR" 1 "^CONFIG: 1 error(s)" "set exactly one of \`provider\` or \`commands\`"

cfg '{"release": {"clearance": null}}'
expect "(14) a null clearance is clean" 0 "$CLEAN"

cfg '{"release": {"docsRepo": {"path": "../docs"}}}'
expect "(15) release.docsRepo is an ERROR naming the migration" 1 "^CONFIG: 1 error(s)" "^ERROR release.docsRepo: deprecated — .*/devstride:setup docs"

cfg '{"ci": {"freezeBaseWhileReleasePrReady": true}}'
expect "(16) the retired freeze switch is a WARN, not an ERROR" 0 "^CONFIG: 0 error(s), 1 warning(s)" "^WARN ci.freezeBaseWhileReleasePrReady: deprecated"

cfg '{"verify": {"typecheck": "make typecheck"}}'
expect "(17) verify.typecheck as a string is an ERROR" 1 "^CONFIG: 1 error(s)" "^ERROR verify.typecheck: expected array, found string"

for v in true false '"ask"'; do
  cfg "{\"epicIntegrationBranches\": {\"autoRelease\": $v}}"
  expect "(18) autoRelease $v is legal" 0 "$CLEAN"
done
cfg '{"epicIntegrationBranches": {"autoRelease": "sometimes"}}'
expect "(19) any other autoRelease value is an ERROR" 1 "^CONFIG: 1 error(s)" '^ERROR epicIntegrationBranches.autoRelease: "sometimes" is not one of true, false, "ask"$'

cfg '{"profile": "enterprize"}'
expect "(20) an unknown profile is an ERROR" 1 "^CONFIG: 1 error(s)" '^ERROR profile: "enterprize" is not one of'

cfg '{"review": {"mandatoryLenses": [{"name": "x", "paths": ["a/**"]}]}}'
expect "(21) a lens without its question is an ERROR naming the entry" 1 "^CONFIG: 1 error(s)" "^ERROR review.mandatoryLenses\[0\]: missing required key \`question\`"

cfg '{"ci": {"expectedRunsPerPullRequest": 1.5}}'
expect "(22) an integer key given a fraction is an ERROR" 1 "^CONFIG: 1 error(s)" "^ERROR ci.expectedRunsPerPullRequest: expected integer, found number"

cfg '{"verify": {"testSingle": true}}'
expect "(23) a boolean is not a string" 1 "^CONFIG: 1 error(s)" "^ERROR verify.testSingle: expected string or null, found boolean"

cfg '["not", "an", "object"]'
expect "(24) a config that is not an object is an ERROR at the root" 1 "^CONFIG: 1 error(s)" "^ERROR (root): expected object"

cfg '{"localCommand": "x"}'
expect "(25) a misplaced key suggests where it belongs" 0 "^CONFIG: 0 error(s), 1 warning(s)" "did you mean review.localCommand?"

# pre-ship checks: an entry without `when` is never selected, one without `command` runs nothing
cfg '{"preShipChecks": [{"name": "db", "command": "make db"}]}'
expect "(33a) a pre-ship check without when is an ERROR" 1 "^CONFIG: 1 error(s)" "^ERROR preShipChecks\[0\]: missing required key \`when\`"
cfg '{"preShipChecks": [{"name": "db", "when": "perPr"}]}'
expect "(33b) a pre-ship check without command is an ERROR" 1 "^CONFIG: 1 error(s)" "^ERROR preShipChecks\[0\]: missing required key \`command\`"
cfg '{"preShipChecks": [{"command": "make db", "when": "perPr"}]}'
expect "(33c) name is optional" 0 "$CLEAN"

# slow cloud suites: a closed object with its mapping required
cfg '{"verify": {"skipDuringStoryBuilds": [{"name": "e2e", "ciChecksByBase": {"baseBranch": ["e2e"]}, "runWhenChangedPaths": ["web/**"]}]}}'
expect "(34a) a minimal slow-suite entry is clean" 0 "$CLEAN"
cfg '{"verify": {"skipDuringStoryBuilds": [{"name": "e2e"}]}}'
expect "(34b) a slow-suite entry without ciChecksByBase is an ERROR" 1 "^CONFIG: 1 error(s)" "missing required key \`ciChecksByBase\`"
cfg '{"verify": {"skipDuringStoryBuilds": [{"name": "e2e", "ciChecksByBase": {"develop": ["e2e"]}, "runWhenChangedPath": ["x/**"]}]}}'
expect "(34c) unknown slow-suite fields and roles are WARNs" 0 "^CONFIG: 0 error(s), 2 warning(s)" "did you mean verify.skipDuringStoryBuilds\[\].runWhenChangedPaths?"
cfg '{"verify": {"skipDuringStoryBuilds": ["e2e"]}}'
expect "(34d) a slow-suite entry that is a bare name is an ERROR" 1 "^CONFIG: 1 error(s)" "^ERROR verify.skipDuringStoryBuilds\[0\]: expected object"

# cloud reviewers: a name-only entry requests nothing, silently
cfg '{"review": {"automatedReviewers": [{"name": "Copilot"}]}}'
expect "(35a) a name-only reviewer is an ERROR for each missing identifier" 1 "^CONFIG: 4 error(s)" "missing required key \`graphqlBotId\`"
cfg '{"review": {"automatedReviewers": [{"name": "X", "how": "mention", "bot": "x[bot]", "value": "x[bot]", "graphqlBotId": "BOT_x"}]}}'
expect "(35b) a how the review flow does not implement is an ERROR" 1 "^CONFIG: 1 error(s)" '^ERROR review.automatedReviewers\[0\].how: "mention" is not one of "requested_reviewer"$'

# reviewer wait: greater than zero, fractions allowed
cfg '{"review": {"pollTimeoutMinutes": 0}}'
expect "(36a) pollTimeoutMinutes 0 is an ERROR" 1 "^CONFIG: 1 error(s)" "^ERROR review.pollTimeoutMinutes: 0 must be greater than 0"
cfg '{"review": {"pollTimeoutMinutes": 0.5}}'
expect "(36b) pollTimeoutMinutes 0.5 is clean" 0 "$CLEAN"

# integers: 2.0 is an integer (draft 2020-12), true never is
cfg '{"ci": {"expectedRunsPerPullRequest": 2.0}}'
expect "(37a) an integral float satisfies integer" 0 "$CLEAN"
cfg '{"ci": {"expectedRunsPerPullRequest": true}}'
expect "(37b) true is not an integer" 1 "^CONFIG: 1 error(s)" "^ERROR ci.expectedRunsPerPullRequest: expected integer, found boolean"

# blocks read null-tolerantly accept null; others do not
cfg '{"supportTrain": null, "hierarchyRoles": null, "localEnvironment": null, "session": null}'
expect "(38a) supportTrain, hierarchyRoles, localEnvironment and session accept null" 0 "$CLEAN"
cfg '{"plugin": null}'
expect "(38b) a null plugin block is an ERROR (the session-start check reads it as invalid)" 1 "^CONFIG: 1 error(s)" "^ERROR plugin: expected object, found null"

# exit 2 paths: one line each, never a fallback to defaults
OUT="$(python3 "$VAL" "$WORK/absent.json" --schema "$SCHEMA" 2>&1)"; RC=$?
[ "$RC" = 2 ] && [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ] && printf '%s' "$OUT" | grep -q "^CONFIG: cannot read the config" \
  && ok "(26) an unreadable config → exit 2, one line" || bad "(26) exit $RC: $OUT"
printf '{"review": ' > "$WORK/broken.json"
OUT="$(python3 "$VAL" "$WORK/broken.json" --schema "$SCHEMA" 2>&1)"; RC=$?
[ "$RC" = 2 ] && [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ] && printf '%s' "$OUT" | grep -q "^CONFIG: cannot parse the config" \
  && ok "(27) invalid JSON → exit 2, one line" || bad "(27) exit $RC: $OUT"
OUT="$(python3 "$VAL" "$FIX/minimal.json" --schema "$WORK/no-schema.json" 2>&1)"; RC=$?
[ "$RC" = 2 ] && [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ] && printf '%s' "$OUT" | grep -q "^CONFIG: cannot read the schema" \
  && ok "(28) a missing schema → exit 2, one line" || bad "(28) exit $RC: $OUT"

# the default schema is the plugin root's, from CLAUDE_PLUGIN_ROOT or from the script's own location
OUT="$(env -u CLAUDE_PLUGIN_ROOT python3 "$VAL" "$FIX/minimal.json" 2>&1)"; RC=$?
[ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q "$CLEAN" && ok "(29) with no --schema and no CLAUDE_PLUGIN_ROOT, the shipped schema is used" || bad "(29) exit $RC: $OUT"
OUT="$(CLAUDE_PLUGIN_ROOT="$WORK" python3 "$VAL" "$FIX/minimal.json" 2>&1)"; RC=$?
[ "$RC" = 2 ] && printf '%s' "$OUT" | grep -q "$WORK/schemas/ds-config.schema.json" && ok "(30) CLAUDE_PLUGIN_ROOT decides the default schema" || bad "(30) exit $RC: $OUT"

# --json carries the same counts
OUT="$(python3 "$VAL" "$FIX/scratch-dod.json" --schema "$SCHEMA" --json 2>&1)"; RC=$?
COUNTS="$(printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["errors"], d["warnings"], len(d["findings"]))' 2>/dev/null)"
[ "$RC" = 1 ] && [ "$COUNTS" = "2 1 3" ] && ok "(31) --json: 2 errors, 1 warning, 3 findings, exit 1" || bad "(31) exit $RC counts '$COUNTS': $OUT"

# the acceptance scratch config: one misspelled key, one wrong shape, both clearance shapes → exactly those three
run "$FIX/scratch-dod.json"
N="$(printf '%s\n' "$OUT" | grep -c '^\(ERROR\|WARN\) ')"
[ "$RC" = 1 ] && [ "$N" = 3 ] && printf '%s\n' "$OUT" | grep -q "^WARN review.localComand" \
  && printf '%s\n' "$OUT" | grep -q "^ERROR verify.test" && printf '%s\n' "$OUT" | grep -q "^ERROR release.clearance: sets both" \
  && ok "(32) the acceptance config reports exactly its three findings" || bad "(32) exit $RC: $OUT"

exit "$FAIL"
