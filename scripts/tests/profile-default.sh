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

# (4) The Shape targets section exists, with all three profiles and both measures.
section="$(awk '/^## Shape targets \(soft\)/{on=1; next} on && /^## /{exit} on' "$ROOT/$CONTRACT")"
if [ -n "$section" ] &&
   printf '%s\n' "$section" | grep -qF '| Measure | `prototype` | `standard` | `extended` |' &&
   printf '%s\n' "$section" | grep -qiF 'stories per epic' &&
   printf '%s\n' "$section" | grep -qiF 'epics per capability' &&
   printf '%s\n' "$section" | grep -qF 'never enforced'; then
  ok "(4) the soft Shape targets table covers three profiles and both measures"
else bad "(4) Shape targets section missing or incomplete"; fi

# (5) Shape targets are not override keys: the override vocabulary never names them.
if awk '/^## Overrides/{on=1; next} on && /^## /{exit} on' "$ROOT/$CONTRACT" | grep -qiE 'stories per epic|epics per capability|shape target'; then
  bad "(5) the Overrides section names a shape target as a key"
else ok "(5) shape targets are not override keys"; fi

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

# (9) Every skill that resolves a profile falls back to extended when config has none.
for pair in 'skills/build-item/SKILL.md|config `profile` → `extended`' \
            'skills/release/SKILL.md|else config `profile`, else `extended`' \
            'skills/rebalance/SKILL.md|else `extended`. On a whole-root run'; do
  f="${pair%%|*}"; n="${pair#*|}"
  if has "$f" "$n"; then ok "(9) $f falls back to extended"; else bad "(9) $f: missing '$n'"; fi
done
if grep -A1 -F 'full-view root marker → config `profile` →' "$ROOT/skills/review/SKILL.md" | grep -qF '`extended` ('; then
  ok "(9) skills/review/SKILL.md falls back to extended"
else bad "(9) skills/review/SKILL.md does not fall back to extended"; fi

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
