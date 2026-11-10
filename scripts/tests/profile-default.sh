#!/bin/bash
# Consistency test for the shipped default delivery profile.
#
# The default is named in several files: the contract, every skill that resolves a profile, setup,
# doctor, the config registry and the README. This test stops it changing in one and not another.
# It also pins the two things that must NOT follow the default: an unknown or retired value still
# falls back to `standard`, and the shape targets stay a soft table rather than knobs.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; FAIL=0
ok() { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; FAIL=1; }
has() { grep -qF -- "$2" "$ROOT/$1"; }
CONTRACT=skills/plan/references/delivery-profiles.md

# (1) The knob table header marks exactly one profile "(default)", and it is extended.
header="$(grep -E '^\| Knob \|' "$ROOT/$CONTRACT")"
marks="$(printf '%s\n' "$header" | grep -o '(default)' | wc -l | tr -d ' ')"
if [ "$marks" = "1" ] && printf '%s\n' "$header" | grep -qF '`extended` (default)'; then
  ok "(1) the contract's table marks extended, and only extended, as the default"
else bad "(1) table header default drifted: $header"; fi

# (2) Resolution-order item 4 names extended.
if grep -qE '^4\. `extended` — the shipped default' "$ROOT/$CONTRACT"; then
  ok "(2) resolution-order item 4 is extended"
else bad "(2) resolution-order item 4 does not name extended"; fi

# (3) The retired-profile fallback still names standard, not the shipped default.
if has "$CONTRACT" 'back to `standard` — never to the shipped default'; then
  ok "(3) the retired/unknown fallback is still standard"
else bad "(3) the retired/unknown fallback no longer names standard"; fi

# (4) The Shape targets section exists, with all three profiles and a data row for each measure
#     carrying three ranges (the measure names also appear in the section's prose, so the rows
#     themselves are matched).
section="$(awk '/^## Shape targets \(soft\)/{on=1; next} on && /^## /{exit} on' "$ROOT/$CONTRACT")"
range='[0-9]+–[0-9]+'
row() { printf '%s\n' "$section" | grep -qE "^\| $1 [^|]*\| $range \| $range \| $range \|$"; }
if [ -n "$section" ] &&
   printf '%s\n' "$section" | grep -qF '| Measure | `prototype` | `standard` | `extended` |' &&
   row 'Stories per epic' && row 'Epics per capability' &&
   printf '%s\n' "$section" | grep -qF 'never enforced'; then
  ok "(4) the soft Shape targets table has a three-range row for each measure"
else bad "(4) Shape targets section missing, or a measure's row lost its three ranges"; fi

# (5) Shape targets are not override keys. The override vocabulary is the knob table plus the
#     registry's profileOverrides.* keys: neither may name a shape target, and the section must
#     still say profileOverrides does not accept them. Each source must be found, or the check
#     has nothing to look at and fails.
knobs="$(awk '/^\| Knob \|/{on=1} on && !/^\|/{exit} on' "$ROOT/$CONTRACT")"
okeys="$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print("\n".join(s["key"] for s in d["settings"] if s["key"].startswith("profileOverrides.")))' "$ROOT/schemas/seam-registry.json" 2>/dev/null)"
shape_re='per ?epic|per ?capability|per ?release ?unit|per ?grouping|leaves ?per|release ?units ?per|shape'
if [ -z "$knobs" ] || [ -z "$okeys" ]; then
  bad "(5) cannot read the knob table or the registry's profileOverrides keys"
elif printf '%s\n%s\n' "$knobs" "$okeys" | grep -qiE "$shape_re"; then
  bad "(5) a shape target is a knob or a profileOverrides key"
elif ! printf '%s\n' "$section" | grep -qF '`profileOverrides` does not accept them'; then
  bad "(5) the Shape targets section no longer says profileOverrides does not accept them"
else ok "(5) shape targets are not knobs or override keys"; fi

# (6) Doctor's absent-key line names extended and the shipped default on one line.
if grep -E 'key absent, shipped default' "$ROOT/skills/doctor/SKILL.md" | grep -qF 'profile: extended'; then
  ok "(6) doctor reports profile: extended — key absent, shipped default"
else bad "(6) doctor's absent-key line does not name extended"; fi
if grep -qF 'profile: standard — key absent' "$ROOT/skills/doctor/SKILL.md"; then
  bad "(6b) doctor still reports standard for an absent key"
else ok "(6b) doctor no longer reports standard for an absent key"; fi

# (7) config-defaults no longer says an absent key reads as standard.
if has skills/setup/references/config-defaults.md 'an absent key reads as `standard`'; then
  bad "(7) config-defaults still reads an absent key as standard"
elif has skills/setup/references/config-defaults.md 'an absent key reads as `extended`'; then
  ok "(7) config-defaults reads an absent key as extended"
else bad "(7) config-defaults does not say what an absent key reads as"; fi

# (8) Setup offers extended first, as the default.
if has skills/setup/SKILL.md 'asking): `extended` (default, first'; then
  ok "(8) setup offers extended first, as the default"
else bad "(8) setup's profile question does not lead with extended as the default"; fi

# (9) Every skill that writes the chain out falls back to extended when config has none, AND says
#     that an unknown word still reads as standard: before, falling off the end of the chain gave
#     standard by accident; now it would give extended, so the clause must be explicit.
for pair in 'skills/build-item/SKILL.md|config `profile` → `extended`; an unknown word → `standard`' \
            'skills/release/SKILL.md|else config `profile` (unknown: `standard`), else `extended`' \
            'skills/rebalance/SKILL.md|else config `profile` (unknown: `standard`),' \
            'skills/rebalance/SKILL.md|else `extended`. On a whole-root run'; do
  f="${pair%%|*}"; n="${pair#*|}"
  if has "$f" "$n"; then ok "(9) $f: extended by default, unknown → standard"; else bad "(9) $f: missing '$n'"; fi
done
if grep -A1 -F 'full-view root marker → config `profile` →' "$ROOT/skills/review/SKILL.md" |
   grep -qF '`extended`; an unknown word → `standard`, said so'; then
  ok "(9) skills/review/SKILL.md: extended by default, unknown → standard"
else bad "(9) skills/review/SKILL.md: chain does not end extended with the unknown → standard clause"; fi

# (9b) Every other file that states the unknown/retired fallback still names standard.
for pair in 'skills/doctor/SKILL.md|back to `standard` and say so' \
            'skills/setup/references/config-defaults.md|a retired or unknown value still reads as `standard`' \
            'skills/ultracode-build/SKILL.md|the retired `enterprise` alone is read as `standard`' \
            'skills/setup/SKILL.md|`enterprise` → `standard`'; do
  f="${pair%%|*}"; n="${pair#*|}"
  if has "$f" "$n"; then ok "(9b) $f: unknown → standard"; else bad "(9b) $f: missing '$n'"; fi
done

# (10) The config registry, and the schema and table generated from it, carry the same default.
reg="$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(next(s["default"] for s in d["settings"] if s["key"]=="profile"))' "$ROOT/schemas/seam-registry.json" 2>/dev/null)"
sch="$(python3 -c 'import json,sys
print(json.load(open(sys.argv[1]))["properties"]["profile"]["default"])' "$ROOT/schemas/ds-config.schema.json" 2>/dev/null)"
if [ "$reg" = "extended" ] && [ "$sch" = "extended" ] &&
   has skills/setup/references/seam-registry.md '| `profile` | string | prototype, standard, extended | extended |'; then
  ok "(10) registry, schema and registry table default to extended"
else bad "(10) registry/schema default drifted (registry=$reg schema=$sch)"; fi

# (11) The README states the default once, on extended.
readme_marks="$(grep -c '(default)' "$ROOT/README.md")"
if [ "$readme_marks" = "1" ] && grep -qF '| `extended` (default) |' "$ROOT/README.md"; then
  ok "(11) the README states the default once, on extended"
else bad "(11) README default drifted ($readme_marks '(default)' marks)"; fi

[ "$FAIL" -eq 0 ]
