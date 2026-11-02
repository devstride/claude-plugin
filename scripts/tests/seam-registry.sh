#!/bin/bash
# Tests for schemas/seam-registry.json and scripts/build-config-schema.py: the registry is well
# formed and points at real files and skills, the committed schema and table are exactly what it
# generates, the schema uses only the keywords the validator implements, and a release cannot
# ship an entry still marked "unreleased". Mutations run on a scratch copy, never the checkout.
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
        if not os.path.isfile(os.path.join(root, "skills", skill, "SKILL.md")):
            problems.append("CALLER %s -> %s" % (h["key"], caller))
print("\n".join(problems) or "clean %d %d" % (len(reg["hooks"]), len(reg["settings"])))
PY
)"
case "$OUT" in clean*) ok "(1-4) every hook carries its fields, keys are unique, contracts exist, callers are real skills ($OUT)";;
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
gen --check --release --base no-such-ref
[ "$RC" = 2 ] && ok "(17) an unreadable base is exit 2" || bad "(17) exit $RC: $OUT"

gen --write --check
[ "$RC" = 2 ] && ok "(18) --write with --check is a usage error" || bad "(18) exit $RC: $OUT"

exit "$FAIL"
