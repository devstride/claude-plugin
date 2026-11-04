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
run "$FIX/commands-clearance.json"; expect "(3) the commands shapes of release.clearance and claims are clean" 0 "$CLEAN"
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
expect "(11) a clearance provider other than github or devstride is an ERROR" 1 "^CONFIG: 1 error(s)" '^ERROR release.clearance.provider: "gitlab" is not one of "github", "devstride"$'

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

# pre-ship runAt: only "train", and only on a releaseOnly entry
cfg '{"preShipChecks": [{"command": "make db", "when": "releaseOnly", "runAt": "train"}]}'
expect "(33d) runAt train on a releaseOnly entry is clean" 0 "$CLEAN"
cfg '{"preShipChecks": [{"command": "make db", "when": "releaseOnly", "runAt": "cut"}]}'
expect "(33e) any other runAt value is an ERROR" 1 "^CONFIG: 1 error(s)" '^ERROR preShipChecks\[0\].runAt: "cut" is not one of "train"$'
cfg '{"preShipChecks": [{"command": "make db", "when": "perPr", "runAt": "train"}]}'
expect "(33f) runAt on an entry that is not releaseOnly is an ERROR" 1 "^CONFIG: 1 error(s)" "^ERROR preShipChecks\[0\].runAt: is only valid"

cfg '{"preShipChecks": [{"command": "make db", "when": "releaseOnly", "runAt": "train", "onlyWhenTouched": true}]}'
expect "(33g) runAt train with onlyWhenTouched is an ERROR" 1 "^CONFIG: 1 error(s)" "^ERROR preShipChecks\\[0\\].runAt: cannot be combined"

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
cfg '{"releaseTrain": null, "hierarchyRoles": null, "localEnvironment": null, "session": null}'
expect "(38a) releaseTrain, hierarchyRoles, localEnvironment and session accept null" 0 "$CLEAN"
cfg '{"plugin": null}'
expect "(38b) a null plugin block is an ERROR (the session-start check reads it as invalid)" 1 "^CONFIG: 1 error(s)" "^ERROR plugin: expected object, found null"

# the train key: the old name is a NOTE, both names together an ERROR
cfg '{"supportTrain": {"branch": "train/support"}}'
expect "(38c) supportTrain alone is a NOTE, not an error" 0 "^CONFIG: 0 error(s), 0 warning(s)" "^NOTE supportTrain: supportTrain is the old name of releaseTrain; rename it$"
cfg '{"supportTrain": {"branch": "train/support"}, "releaseTrain": {"branch": "train/support"}}'
expect "(38d) a config carrying both supportTrain and releaseTrain is an ERROR" 1 "^CONFIG: 1 error(s)" "^ERROR supportTrain: .*both are set"
cfg '{"supportTrain": null, "releaseTrain": {"branch": "train/support"}}'
expect "(38e) a null supportTrain beside releaseTrain is clean" 0 "$CLEAN"
# the deferred container's titles: an empty one is a WARN, the current title listed as legacy a NOTE
cfg '{"defects": {"deferredContainerTitle": "Deferred", "deferredContainerLegacyTitles": ["Deferred defects", "Parked"]}}'
expect "(38f) a title plus extra legacy titles is clean" 0 "$CLEAN"
cfg '{"defects": {"deferredContainerTitle": "  "}}'
expect "(38g) an empty deferred container title is a WARN" 0 "^CONFIG: 0 error(s), 1 warning(s)" "^WARN defects.deferredContainerTitle: an empty title matches no container"
cfg '{"defects": {"deferredContainerLegacyTitles": ["Deferred defects", ""]}}'
expect "(38h) an empty legacy title is a WARN" 0 "^CONFIG: 0 error(s), 1 warning(s)" "^WARN defects.deferredContainerLegacyTitles\\[1\\]: an empty title matches nothing"
cfg '{"defects": {"deferredContainerTitle": "Deferred", "deferredContainerLegacyTitles": ["  deferred "]}}'
expect "(38i) the current title also listed as legacy is a NOTE" 0 "^CONFIG: 0 error(s), 0 warning(s)" "^NOTE defects.deferredContainerLegacyTitles: lists the current title too"
cfg '{"defects": {"deferredContainerLegacyTitles": ["Deferred"]}}'
expect "(38k) the default title listed as legacy is a NOTE when the title key is absent" 0 "^CONFIG: 0 error(s), 0 warning(s)" "^NOTE defects.deferredContainerLegacyTitles: lists the current title too"
cfg '{"defects": {"deferredContainerLegacyTitles": "Deferred defects"}}'
expect "(38j) a legacy-titles string instead of an array is an ERROR" 1 "^CONFIG: 1 error(s)" "^ERROR defects.deferredContainerLegacyTitles: expected array"

# exit 2 under --json: one JSON document, never a plain line
printf '{"review": ' > "$WORK/broken.json"
for case in "$WORK/absent.json|cannot read the config" "$WORK/broken.json|cannot parse the config"; do
  OUT="$(python3 "$VAL" "${case%%|*}" --schema "$SCHEMA" --json 2>&1)"; RC=$?
  F="$(printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["errors"], d["fatal"])' 2>/dev/null)"
  case "$F" in "None ${case##*|}"*) [ "$RC" = 2 ] && ok "(39) --json on an unusable config: a JSON document with fatal, exit 2" || bad "(39) exit $RC";;
    *) bad "(39) not a JSON fatal document (exit $RC): $OUT";; esac
done
OUT="$(python3 "$VAL" "$FIX/minimal.json" --schema "$WORK/no-schema.json" --json 2>&1)"; RC=$?
printf '%s' "$OUT" | python3 -c 'import json,sys; assert json.load(sys.stdin)["fatal"].startswith("cannot read the schema")' 2>/dev/null && [ "$RC" = 2 ] \
  && ok "(39c) --json with a missing schema: a JSON document, exit 2" || bad "(39c) exit $RC: $OUT"

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

# (33)-(34) the step-skill seams: a misspelled pool key is a WARN naming the right one; the new keys
# validate clean
cfg '{"pool": {"checkoutt": "lease <member> <purpose>"}}'
expect "(33) pool.checkoutt is a WARN suggesting pool.checkout" 0 "^CONFIG: 0 error(s), 1 warning(s)" \
  "^WARN pool.checkoutt: unknown key; did you mean pool.checkout?$"
cfg '{"pool": {"checkout": "lease <member> --purpose <purpose>", "checkin": "return <member>"}, "release": {"classifySkill": "classify", "preMergeSkill": null}, "docs": {"knowledgeBaseSyncSkill": "kb-sync"}}'
expect "(34) pool.checkout, pool.checkin, release.classifySkill, release.preMergeSkill and docs.knowledgeBaseSyncSkill validate clean" 0 "$CLEAN"

# (35)-(36) the pool commands are set together or not at all: one alone (absent or null) is an ERROR
cfg '{"pool": {"checkout": "lease <member> <purpose>"}}'
expect "(35) pool.checkout without pool.checkin is an ERROR" 1 "^CONFIG: 1 error(s), 0 warning(s)" \
  "^ERROR pool: sets \`pool.checkout\` without \`pool.checkin\`; set them together or not at all$"
cfg '{"pool": {"checkout": null, "checkin": "return <member>"}}'
expect "(36) pool.checkin with a null pool.checkout is an ERROR" 1 "^CONFIG: 1 error(s), 0 warning(s)" \
  "^ERROR pool: sets \`pool.checkin\` without \`pool.checkout\`"

# (40)-(47) the claims seam: provider or commands, never both; expiry out of range is only a WARN
cfg '{"release": {"clearance": {"provider": "devstride", "credentialsFile": ".devstride/agent.env"}}}'
expect "(40) release.clearance.provider devstride with a credentialsFile is clean" 0 "$CLEAN"
cfg '{"claims": {"provider": "devstride", "expiryMinutes": {"story": 240, "release-tower": 20}}}'
expect "(41) the claims provider form with expiryMinutes is clean" 0 "$CLEAN"
cfg '{"claims": {"commands": {"claim": "c", "heartbeat": "h", "release": "r"}, "expiryMinutes": {"story": 60}}}'
expect "(42) the claims commands form with expiryMinutes is clean" 0 "$CLEAN"
cfg '{"claims": {"provider": "devstride", "commands": {"claim": "c", "heartbeat": "h", "release": "r"}}}'
expect "(43) claims with both provider and commands is an ERROR" 1 "^CONFIG: 1 error(s)" "^ERROR claims: sets both \`provider\` and \`commands\`"
cfg '{"claims": {"provider": "redis"}}'
expect "(44) an unknown claims provider is an ERROR" 1 "^CONFIG: 1 error(s)" '^ERROR claims.provider: "redis" is not one of "devstride"$'
cfg '{"claims": {"commands": {"claim": "c", "release": "r"}}}'
expect "(45) a claims commands block without heartbeat is an ERROR naming it" 1 "^CONFIG: 1 error(s)" "^ERROR claims.commands: missing required key \`heartbeat\`"
cfg '{"claims": {"provider": "devstride", "expiryMinutes": {"story": 0, "release-tower": 2000}}}'
expect "(46) expiryMinutes 0 and 2000 are WARNs, exit 0" 0 "^CONFIG: 0 error(s), 2 warning(s)" \
  "^WARN claims.expiryMinutes.release-tower: 2000 is outside 1..1440; ignored, the default stands$"
printf '%s\n' "$OUT" | grep -q "^WARN claims.expiryMinutes.story: 0 is outside 1..1440" \
  && ok "(46b) the WARN names the kind that stays at its default" || bad "(46b) $OUT"
cfg '{"claims": {"provider": "devstride", "expiryMinutes": {"story": "four hours"}}}'
expect "(47) a non-integer expiry is an ERROR" 1 "^CONFIG: 1 error(s)" "^ERROR claims.expiryMinutes.story: expected integer, found string"
cfg '{"claims": null}'
expect "(48) a null claims block is clean" 0 "$CLEAN"

# (49)-(51) release.clearance.scope: either shape takes it (with phaseBudgetMinutes); any other value is an ERROR
cfg '{"release": {"clearance": {"commands": {"claim": "c", "status": "s", "heartbeat": "h", "release": "r", "adopt": "a"}, "scope": "cut-to-deploy", "phaseBudgetMinutes": {"deploy": 30}}}}'
expect "(49) a commands clearance with scope and phaseBudgetMinutes is clean" 0 "$CLEAN"
cfg '{"release": {"clearance": {"provider": "github", "scope": "release"}}}'
expect "(50) a provider clearance with scope release is clean" 0 "$CLEAN"
cfg '{"release": {"clearance": {"provider": "github", "scope": "deploy-only"}}}'
expect "(51) any other scope is an ERROR" 1 "^CONFIG: 1 error(s)" '^ERROR release.clearance.scope: "deploy-only" is not one of "release", "cut-to-deploy"$'

# (52)-(56) release.autoStart needs a claims block; the standing yes without a classify skill is a WARN
cfg '{"claims": {"provider": "devstride", "expiryMinutes": {"release-train": 30}}, "release": {"autoStart": {"enabled": true}, "classifySkill": "classify", "lightRelease": {"standingYes": true}}}'
expect "(52) autoStart with claims and the standing yes with a classify skill is clean" 0 "$CLEAN"
cfg '{"release": {"autoStart": {"enabled": true}}}'
expect "(53) autoStart enabled without claims is an ERROR" 1 "^CONFIG: 1 error(s)" "^ERROR release.autoStart.enabled: needs a \`claims\` block"
cfg '{"claims": null, "release": {"autoStart": {"enabled": true}}}'
expect "(54) autoStart enabled with a null claims block is an ERROR" 1 "^CONFIG: 1 error(s)" "^ERROR release.autoStart.enabled: needs a \`claims\` block"
cfg '{"release": {"autoStart": {"enabled": false}, "lightRelease": {"standingYes": false}}}'
expect "(55) both switches off is clean" 0 "$CLEAN"
cfg '{"release": {"lightRelease": {"standingYes": true}}}'
expect "(56) the standing yes without release.classifySkill is a WARN, exit 0" 0 "^CONFIG: 0 error(s), 1 warning(s)" \
  "^WARN release.lightRelease.standingYes: has no effect without \`release.classifySkill\`"

exit "$FAIL"
