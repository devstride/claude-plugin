#!/bin/bash
# Tests for schemas/seam-registry.json and scripts/build-config-schema.py: the registry is well
# formed and points at real files, skills and hook scripts, the committed schema and table are exactly what it
# generates, the schema uses only the keywords the validator implements, and a release cannot
# ship an entry, or a step contract, still marked "unreleased". Mutations run on a scratch copy,
# never the checkout.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; GEN="scripts/build-config-schema.py"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# (1)-(4) the registry's own shape, against the checkout
OUT="$(python3 - "$ROOT" <<'PY'
import json, os, sys
root = sys.argv[1]
reg = json.load(open(os.path.join(root, "schemas/seam-registry.json")))
need = ["key", "shape", "valueType", "payload", "verdict", "calledBy", "unset", "contract", "since"]
problems = []
for h in reg["hooks"]:
    for f in need:
        if f not in h:
            problems.append("FIELD %s lacks %s" % (h.get("key"), f))
    if h.get("shape") in ("skill", "provider-or-commands") and not h.get("modes"):
        problems.append("FIELD %s lacks modes" % h.get("key"))
keys = [e["key"] for e in reg["hooks"] + reg["settings"]]
for k in sorted({k for k in keys if keys.count(k) > 1}):
    problems.append("DUP %s" % k)
for h in reg["hooks"]:
    c = h.get("contract")
    if c and not os.path.exists(os.path.join(root, c.split("#")[0])):
        problems.append("CONTRACT %s -> %s" % (h["key"], c))
    for caller in h.get("calledBy") or []:
        skill = caller.split()[0]
        if skill.startswith("hooks/"):  # a hook script calls it directly: the script must exist
            if not os.path.isfile(os.path.join(root, skill)):
                problems.append("CALLER %s -> %s" % (h["key"], caller))
        elif not os.path.isfile(os.path.join(root, "skills", skill, "SKILL.md")):
            problems.append("CALLER %s -> %s" % (h["key"], caller))
print("\n".join(problems) or "clean %d %d" % (len(reg["hooks"]), len(reg["settings"])))
PY
)"
case "$OUT" in clean*) ok "(1-4) every hook carries its fields, keys are unique, contracts exist, callers are real skills or hook scripts ($OUT)";;
  *) bad "(1-4) $OUT";; esac

# (5) the committed schema and table are current
OUT="$(cd "$ROOT" && python3 "$GEN" --check 2>&1)"; RC=$?
[ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q "^SCHEMA: ok ([0-9]* hooks, [0-9]* settings, version " \
  && ok "(5) --check is clean on the checkout" || bad "(5) exit $RC: $OUT"

# (6) the schema's \$id carries plugin.json's version
V="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ROOT/.claude-plugin/plugin.json")"
ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["$id"])' "$ROOT/schemas/ds-config.schema.json")"
case "$ID" in *"/devstride--v$V/schemas/ds-config.schema.json") ok "(6) \$id names v$V";; *) bad "(6) \$id $ID, plugin.json $V";; esac

# (7) only the keywords the validator implements, plus annotations (property names are not keywords)
OUT="$(python3 - "$ROOT" <<'PY'
import importlib.util, json, os, sys
root = sys.argv[1]
spec = importlib.util.spec_from_file_location("gen", os.path.join(root, "scripts/build-config-schema.py"))
gen = importlib.util.module_from_spec(spec); spec.loader.exec_module(gen)
allowed = gen.VALIDATION_KEYWORDS | gen.ANNOTATIONS
used = set()
def walk(node):
    if not isinstance(node, dict):
        return
    for k, v in node.items():
        used.add(k)
        if k in ("properties", "patternProperties"):
            for sub in v.values():
                walk(sub)
        elif k in ("items", "additionalProperties"):
            walk(v)
        elif k == "oneOf":
            for sub in v:
                walk(sub)
walk(json.load(open(os.path.join(root, "schemas/ds-config.schema.json"))))
print(" ".join(sorted(used - allowed)))
PY
)"
[ -z "$OUT" ] && ok "(7) the schema uses only implemented keywords and annotations" || bad "(7) unimplemented: $OUT"

# (7b) and every keyword in that subset is one the validator actually reads
OUT="$(python3 - "$ROOT" <<'PY'
import importlib.util, os, sys
root = sys.argv[1]
spec = importlib.util.spec_from_file_location("gen", os.path.join(root, "scripts/build-config-schema.py"))
gen = importlib.util.module_from_spec(spec); spec.loader.exec_module(gen)
src = open(os.path.join(root, "skills/doctor/scripts/validate-config.py")).read()
print(" ".join(sorted(k for k in gen.VALIDATION_KEYWORDS | {"x-severity"} if '"%s"' % k not in src)))
PY
)"
[ -z "$OUT" ] && ok "(7b) the validator reads every keyword the generator may emit" || bad "(7b) the validator never reads: $OUT"

# a scratch copy of what the generator reads and writes, as its own git repository
copy() {
  rm -rf "$WORK/r"; mkdir -p "$WORK/r/scripts" "$WORK/r/schemas" "$WORK/r/.claude-plugin" "$WORK/r/skills/setup/references"
  cp "$ROOT/$GEN" "$WORK/r/scripts/"; cp "$ROOT/schemas/"*.json "$WORK/r/schemas/"
  cp "$ROOT/.claude-plugin/plugin.json" "$WORK/r/.claude-plugin/"
  cp "$ROOT/skills/setup/references/seam-registry.md" "$WORK/r/skills/setup/references/"
  git -C "$WORK/r" init -q -b main && git -C "$WORK/r" add -A \
    && git -C "$WORK/r" -c user.name=t -c user.email=t@example.invalid commit -qm base
}
edit() { python3 - "$WORK/r/$1" "$2" <<'PY'
import json, sys
path, expr = sys.argv[1], sys.argv[2]
d = json.load(open(path)); exec(expr); open(path, "w").write(json.dumps(d, indent=2) + "\n")
PY
}
gen() { OUT="$(python3 "$WORK/r/$GEN" "$@" 2>&1)"; RC=$?; }

copy; printf '\n' >> "$WORK/r/schemas/ds-config.schema.json"; gen --check
[ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q "^DRIFT schemas/ds-config.schema.json:" && ! printf '%s' "$OUT" | grep -q "DRIFT skills" \
  && ok "(8) a hand-edited schema is DRIFT naming the schema file" || bad "(8) exit $RC: $OUT"

copy; sed -i.bak 's/| `verify.test` |/| `verify.tests` |/' "$WORK/r/skills/setup/references/seam-registry.md"; gen --check
[ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q "^DRIFT skills/setup/references/seam-registry.md:" \
  && ok "(9) a hand-edited table is DRIFT naming the table" || bad "(9) exit $RC: $OUT"

copy; edit schemas/seam-registry.json 'd["settings"][0]["description"] += " (changed)"'; gen --check
[ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q "^DRIFT schemas/ds-config.schema.json" \
  && printf '%s' "$OUT" | grep -q "^DRIFT skills/setup/references/seam-registry.md" \
  && ok "(10) a registry edit without --write is DRIFT in both outputs" || bad "(10) exit $RC: $OUT"
gen --write; gen --check
[ "$RC" = 0 ] && ok "(11) --write brings both outputs current" || bad "(11) exit $RC: $OUT"

copy; edit schemas/seam-registry.json 'd["settings"].append(dict(d["settings"][0]))'; gen --check
[ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q "^REGISTRY .*duplicate" && ok "(12) a duplicate key is a REGISTRY finding" || bad "(12) exit $RC: $OUT"
copy; edit schemas/seam-registry.json 'del d["hooks"][0]["modes"]'; gen --check
[ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q "^REGISTRY .*modes" && ok "(13) a skill hook without modes is a REGISTRY finding" || bad "(13) exit $RC: $OUT"
copy; edit schemas/seam-registry.json 'd["settings"][0]["type"] = "text"'; gen --check
[ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q "^REGISTRY " && ok "(14) an unknown type is a REGISTRY finding" || bad "(14) exit $RC: $OUT"

# (15)-(17) --release: an "unreleased" entry blocks only a version that differs from the base
copy; edit schemas/seam-registry.json 'd["settings"][0]["since"] = "unreleased"'; gen --write >/dev/null
git -C "$WORK/r" add -A && git -C "$WORK/r" -c user.name=t -c user.email=t@example.invalid commit -qm unreleased
gen --check --release --base main
[ "$RC" = 0 ] && ok "(15) same version as the base: an unreleased entry is fine" || bad "(15) exit $RC: $OUT"
edit .claude-plugin/plugin.json 'd["version"] = "99.0.0"'; gen --write >/dev/null; gen --check --release --base main
[ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q "^UNRELEASED .*: set since to 99.0.0" \
  && ok "(16) a version bump with an unreleased entry is refused, naming the version" || bad "(16) exit $RC: $OUT"
copy; edit schemas/step-contracts.json '[c.__setitem__("since", "1.0.0") for c in list(d["contracts"].values()) + list(d.get("features", {}).values()) if "since" in c]; d["contracts"]["claim@1"]["since"] = "unreleased"'
git -C "$WORK/r" add -A && git -C "$WORK/r" -c user.name=t -c user.email=t@example.invalid commit -qm unreleased-contract
gen --check --release --base main
[ "$RC" = 0 ] && ok "(16b) same version as the base: an unreleased step contract is fine" || bad "(16b) exit $RC: $OUT"
edit .claude-plugin/plugin.json 'd["version"] = "99.0.0"'; gen --write >/dev/null; gen --check --release --base main
[ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q "^UNRELEASED step contract claim@1: set since to 99.0.0" \
  && ! printf '%s' "$OUT" | grep -q "^UNRELEASED step contract approval@1" \
  && ok "(16c) a version bump with an unreleased step contract is refused, naming it and the version" || bad "(16c) exit $RC: $OUT"
copy; edit schemas/step-contracts.json '[c.__setitem__("since", "1.0.0") for c in list(d["contracts"].values()) + list(d["features"].values()) if "since" in c]; d["features"]["when-manual"]["since"] = "unreleased"'
git -C "$WORK/r" add -A && git -C "$WORK/r" -c user.name=t -c user.email=t@example.invalid commit -qm unreleased-feature
edit .claude-plugin/plugin.json 'd["version"] = "99.0.0"'; gen --write >/dev/null; gen --check --release --base main
[ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q "^UNRELEASED workflow feature when-manual: set since to 99.0.0" \
  && ! printf '%s' "$OUT" | grep -q "^UNRELEASED step contract" \
  && ok "(16d) a version bump with an unreleased workflow feature is refused, naming it and the version" || bad "(16d) exit $RC: $OUT"
gen --check --release --base no-such-ref
[ "$RC" = 2 ] && ok "(17) an unreadable base is exit 2" || bad "(17) exit $RC: $OUT"

# (17b)-(17e) the plugin as a subdirectory of a larger repository: the base's plugin.json is read
# from the plugin directory, and a base that does not hold the plugin yet falls back to the newest
# commit whose subject starts `plugin import`
subcopy() {
  copy; rm -rf "$WORK/big"; mkdir -p "$WORK/big"; git -C "$WORK/big" init -q -b master
  echo host > "$WORK/big/README.md"; git -C "$WORK/big" add -A
  git -C "$WORK/big" -c user.name=t -c user.email=t@example.invalid commit -qm "before the plugin"
  git -C "$WORK/big" checkout -q -b work; mkdir "$WORK/big/claude-plugin"
  tar --exclude=.git -cf - -C "$WORK/r" . | tar -xf - -C "$WORK/big/claude-plugin"
  git -C "$WORK/big" add -A; git -C "$WORK/big" -c user.name=t -c user.email=t@example.invalid commit -qm "$1"
}
subgen() { OUT="$(cd "$WORK" && python3 "$WORK/big/claude-plugin/$GEN" "$@" 2>&1)"; RC=$?; }
subedit() { python3 - "$WORK/big/claude-plugin/$1" "$2" <<'PY'
import json, sys
path, expr = sys.argv[1], sys.argv[2]
d = json.load(open(path)); exec(expr); open(path, "w").write(json.dumps(d, indent=2) + "\n")
PY
}
subcopy "plugin import: test tree"
subedit schemas/seam-registry.json 'd["settings"][0]["since"] = "unreleased"'; subgen --write >/dev/null
subgen --check --release --base work
[ "$RC" = 0 ] && ! printf '%s' "$OUT" | grep -q "^base: plugin import" \
  && ok "(17b) in a subdirectory, same version as a base that holds the plugin: fine, read from the base itself" || bad "(17b) exit $RC: $OUT"
subgen --check --release --base master
[ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q "^base: plugin import commit .* (master does not hold the plugin yet)" && printf '%s' "$OUT" | grep -q "^SCHEMA: ok " \
  && ok "(17c) a base without the plugin falls back to the import commit and says so" || bad "(17c) exit $RC: $OUT"
subedit .claude-plugin/plugin.json 'd["version"] = "99.0.0"'; subgen --write >/dev/null; subgen --check --release --base master
[ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q "^UNRELEASED .*: set since to 99.0.0" \
  && ok "(17d) … and a version above the imported one with an unreleased entry is still refused" || bad "(17d) exit $RC: $OUT"
subcopy "copied by hand"; subgen --check --release --base master
[ "$RC" = 2 ] && ok "(17e) a base without the plugin and no import commit is exit 2" || bad "(17e) exit $RC: $OUT"

# (19) every required field, hook or setting, is marked in the readable table
MISSING="$(python3 - "$ROOT" <<'PYI'
import json, sys
root = sys.argv[1]
reg = json.load(open(root + "/schemas/seam-registry.json"))
table = open(root + "/skills/setup/references/seam-registry.md").read().splitlines()
for e in reg["hooks"] + reg["settings"]:
    if e.get("required"):
        row = [l for l in table if l.startswith("| `%s` |" % e["key"])]
        if not row or "**Required.**" not in row[0]:
            print(e["key"])
PYI
)"
[ -z "$MISSING" ] && ok "(19) every required key is marked Required in the table" || bad "(19) unmarked: $MISSING"

gen --write --check
[ "$RC" = 2 ] && ok "(18) --write with --check is a usage error" || bad "(18) exit $RC: $OUT"

# (20) the step-skill seams are registered as unreleased hooks with a contract, and every hook a step
# runs names its step and verdict lines
OUT="$(python3 - "$ROOT" <<'PYS'
import json, os, sys
root = sys.argv[1]
reg = json.load(open(os.path.join(root, "schemas/seam-registry.json")))
hooks = {h["key"]: h for h in reg["hooks"]}
problems = []
for key in ("docs.knowledgeBaseSyncSkill", "release.classifySkill", "release.preMergeSkill",
            "pool.checkout", "pool.checkin"):
    h = hooks.get(key)
    if not h:
        problems.append("MISSING " + key); continue
    if h.get("since") != "unreleased" and not h.get("since", "").startswith(("3.", "4.")):
        problems.append("SINCE " + key)
    if not os.path.isfile(os.path.join(root, h.get("contract", ""))):
        problems.append("CONTRACT " + key)
for h in reg["hooks"]:
    if "step" in h and not os.path.isfile(os.path.join(root, "skills", h["step"], "SKILL.md")):
        problems.append("STEP %s -> %s" % (h["key"], h["step"]))
print("\n".join(problems) or "clean")
PYS
)"
[ "$OUT" = clean ] && ok "(20) the five step-skill seams are registered with a contract; every step a hook names exists" \
  || bad "(20) $OUT"
copy; edit schemas/seam-registry.json 'd["hooks"][0]["step"] = "update-docs"; d["hooks"][0].pop("stepVerdict", None)'; gen --check
[ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q "^REGISTRY .*stepVerdict" \
  && ok "(21) a hook naming a step without its verdict lines is a REGISTRY finding" || bad "(21) exit $RC: $OUT"

# (22) the workflows switch names the two gate tools, and doctor's workflows check lists both; the
# switch is a setting now, with no hook: the runner sends a run's history itself
OUT="$(python3 - "$ROOT" <<'PYG'
import json, os, sys
root = sys.argv[1]
registry = json.load(open(os.path.join(root, "schemas/seam-registry.json")))
settings = {s["key"]: s for s in registry["settings"]}
doctor = open(os.path.join(root, "skills/doctor/references/workflows-checks.md"), encoding="utf-8").read()
names = ("request_workflow_gate", "get_workflow_gate")
problems = ["SEAM " + n for n in names if "`%s`" % n not in settings["workflows"]["description"]]
problems += ["DOCTOR " + n for n in names if "`%s`" % n not in doctor]
problems += ["HOOK " + h["key"] for h in registry["hooks"] if h["key"] == "workflows" or h["key"].startswith("workflows.")]
print("\n".join(problems) or "clean")
PYG
)"
[ "$OUT" = clean ] && ok "(22) the workflows switch and doctor name request_workflow_gate and get_workflow_gate, and no workflows hook is left" || bad "(22) $OUT"

exit "$FAIL"
