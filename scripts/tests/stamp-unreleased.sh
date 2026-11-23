#!/bin/bash
# scripts/tests/stamp-unreleased.sh — the release stamp: `unreleased` in the seam registry, the
# step-contract catalog and a built-in workflow becomes the version; every other byte is left
# alone; a second run changes nothing; a malformed file stops the run with nothing written.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; STAMP="$ROOT/scripts/stamp-unreleased.py"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
sum() { ( cd "$1" && find . -type f | LC_ALL=C sort | while read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done ); }

# A small plugin directory. The odd spacing, the key order, the CRLF line and the look-alike
# values are deliberate: each is something a rewrite through a JSON library would lose or a loose
# pattern would stamp.
make() {
  rm -rf "$1"; mkdir -p "$1/schemas" "$1/workflows" "$1/skills/demo"
  printf '%s\n' '{' \
    '  "$comment": "a key is \"since\": \"unreleased\" until a release names it",' \
    '  "hooks": [' \
    '    { "key": "a.hook", "since": "1.0.0",   "description": "unreleased" },' \
    '    { "since":"unreleased", "key": "b.hook" }' \
    '  ],' \
    '  "settings": [' \
    '    {"key": "c.key", "since" :  "unreleased", "default": "unreleased", "minPluginVersion": "unreleased"},' \
    '    {"key": "d.key", "sinceWhen": "unreleased", "since": "unreleased-soon"}' \
    '  ]' \
    '}' > "$1/schemas/seam-registry.json"
  printf '{\n  "schema": 1,\r\n  "since": "unreleased",\n  "contracts": { "x@1": { "since": "unreleased", "summary": "s" }, "y@1": { "since": "2.0.0" } }\n}' > "$1/schemas/step-contracts.json"
  printf '{\n  "name": "build",\n  "minPluginVersion": "unreleased",\n  "since": "unreleased",\n  "phases": []\n}\n' > "$1/workflows/build.json"
  printf '{ "name": "old", "minPluginVersion": "3.0.0" }\n' > "$1/workflows/old.json"
  printf '{ "since": "unreleased", "minPluginVersion": "unreleased" }\n' > "$1/skills/demo/other.json"
  printf 'since: unreleased\n' > "$1/workflows/notes.md"
}

# (1) every marked value is stamped and reported; nothing else in the directory changes.
P="$WORK/p"; make "$P"; make "$WORK/before"
OUT="$(python3 "$STAMP" 4.9.0 --root "$P" 2>&1)"; RC=$?
[ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q '^STAMPED schemas/seam-registry.json: 2 since$' \
  && printf '%s\n' "$OUT" | grep -q '^STAMPED schemas/step-contracts.json: 2 since$' \
  && printf '%s\n' "$OUT" | grep -q '^STAMPED workflows/build.json: 1 minPluginVersion$' \
  && [ "$(printf '%s\n' "$OUT" | tail -n 1)" = "STAMP: 5 value(s) set to 4.9.0 in 3 file(s)" ] \
  && [ "$(printf '%s\n' "$OUT" | grep -c '^STAMPED ')" = 3 ] \
  && ok "(1) the registry, the contract catalog and the workflow are stamped and reported" || bad "(1) exit $RC: $OUT"

# (2) byte for byte: the stamped files equal the originals with only those five values replaced.
make "$WORK/want"
python3 - "$WORK/want" <<'PY'
import sys
root = sys.argv[1]
def swap(path, pairs):
    data = open(path, "rb").read()
    for old, new, times in pairs:
        assert data.count(old) == times, (path, old, data.count(old))
        data = data.replace(old, new)
    open(path, "wb").write(data)
swap(root + "/schemas/seam-registry.json", [(b'"since":"unreleased"', b'"since":"4.9.0"', 1),
                                           (b'"since" :  "unreleased"', b'"since" :  "4.9.0"', 1)])
swap(root + "/schemas/step-contracts.json", [(b'"since": "unreleased"', b'"since": "4.9.0"', 2)])
swap(root + "/workflows/build.json", [(b'"minPluginVersion": "unreleased"', b'"minPluginVersion": "4.9.0"', 1)])
PY
[ "$(sum "$P")" = "$(sum "$WORK/want")" ] && ok "(2) every other byte is unchanged (spacing, order, the CRLF line, look-alike values, other files)" \
  || bad "(2) $(diff <(sum "$P") <(sum "$WORK/want"))"
grep -q '"description": "unreleased"' "$P/schemas/seam-registry.json" && grep -q '"default": "unreleased", "minPluginVersion": "unreleased"' "$P/schemas/seam-registry.json" \
  && grep -q '"sinceWhen": "unreleased", "since": "unreleased-soon"' "$P/schemas/seam-registry.json" && grep -q '\\"since\\": \\"unreleased\\"' "$P/schemas/seam-registry.json" \
  && grep -q '"since": "unreleased",' "$P/workflows/build.json" && grep -q '"since": "unreleased", "minPluginVersion": "unreleased"' "$P/skills/demo/other.json" \
  && ok "(2b) another field's unreleased, a registry minPluginVersion, a workflow since and a file elsewhere are not stamped" || bad "(2b) a look-alike was stamped"
python3 -c "import json,sys; [json.load(open(sys.argv[1] + f)) for f in ('/schemas/seam-registry.json', '/schemas/step-contracts.json', '/workflows/build.json')]" "$P" \
  && ok "(2c) the stamped files still parse" || bad "(2c) a stamped file no longer parses"

# (3) idempotent: a second run, with the same or another version, changes nothing.
BEFORE="$(sum "$P")"
OUT="$(python3 "$STAMP" 4.9.0 --root "$P" 2>&1)"; RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "STAMP: nothing to stamp" ] && [ "$(sum "$P")" = "$BEFORE" ] && ok "(3) a second run changes nothing" || bad "(3) exit $RC: $OUT"
OUT="$(python3 "$STAMP" 5.0.0 --root "$P" 2>&1)"; RC=$?
[ "$RC" = 0 ] && [ "$(sum "$P")" = "$BEFORE" ] && ok "(3b) a later version never re-stamps a released value" || bad "(3b) exit $RC: $OUT"

# (4) a malformed file fails the run, is named, and nothing is written anywhere.
for broken in schemas/seam-registry.json schemas/step-contracts.json workflows/build.json; do
  make "$P"; printf '{ "since": "unreleased", "minPluginVersion": "unreleased", \n' > "$P/$broken"; BEFORE="$(sum "$P")"
  OUT="$(python3 "$STAMP" 4.9.0 --root "$P" 2>&1)"; RC=$?
  [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q "^stamp-unreleased: $broken: not valid JSON" && printf '%s' "$OUT" | grep -q 'nothing was changed' \
    && ! printf '%s' "$OUT" | grep -q '^STAMP' && [ "$(sum "$P")" = "$BEFORE" ] \
    && ok "(4) malformed $broken: exit 1, named, no file written" || bad "(4) $broken exit $RC: $OUT"
done

# (5) no contract catalog and no workflows: the registry alone is stamped.
make "$P"; rm -rf "$P/schemas/step-contracts.json" "$P/workflows"
OUT="$(python3 "$STAMP" 4.9.0 --root "$P" 2>&1)"; RC=$?
[ "$RC" = 0 ] && [ "$(printf '%s\n' "$OUT" | tail -n 1)" = "STAMP: 2 value(s) set to 4.9.0 in 1 file(s)" ] && ok "(5) the catalog and the workflows are optional" || bad "(5) exit $RC: $OUT"

# (6) usage: no version, a bad version, an unknown flag, a missing registry — exit 2, nothing written.
make "$P"; BEFORE="$(sum "$P")"; n=0
for args in "" "v4.9.0" "4.9" "unreleased" "4.9.0 4.9.1" "4.9.0 --bogus" "4.9.0 --root" "4.9.0 --root $WORK/absent"; do
  n=$((n + 1))
  # shellcheck disable=SC2086
  if [ "$n" -le 6 ]; then OUT="$(python3 "$STAMP" $args --root "$P" 2>&1)"; else OUT="$(python3 "$STAMP" $args 2>&1)"; fi; RC=$?
  [ "$RC" = 2 ] && printf '%s' "$OUT" | grep -q '^stamp-unreleased: ' && [ "$(sum "$P")" = "$BEFORE" ] && ok "(6.$n) usage error for '$args'" || bad "(6.$n) '$args' exit $RC: $OUT"
done
rm "$P/schemas/seam-registry.json"
OUT="$(python3 "$STAMP" 4.9.0 --root "$P" 2>&1)"; RC=$?
[ "$RC" = 2 ] && printf '%s' "$OUT" | grep -q 'no schemas/seam-registry.json' && ok "(6.9) a directory with no registry is refused" || bad "(6.9) exit $RC: $OUT"

# (7) the shipped tree: today nothing is marked, so a run by its default root leaves it untouched
# (run on a copy, so a tree that does carry a mark is never edited by its own test).
mkdir -p "$WORK/real/scripts" && cp -R "$ROOT/schemas" "$ROOT/workflows" "$WORK/real/" && cp "$STAMP" "$WORK/real/scripts/"
BEFORE="$(sum "$WORK/real")"
OUT="$(cd "$WORK" && python3 "$WORK/real/scripts/stamp-unreleased.py" 999.0.0 2>&1)"; RC=$?
MARKED="$(grep -l -E '"(since|minPluginVersion)"[[:space:]]*:[[:space:]]*"unreleased"' "$ROOT"/schemas/seam-registry.json "$ROOT"/schemas/step-contracts.json "$ROOT"/workflows/*.json 2>/dev/null | wc -l | tr -d ' ')"
if [ "$MARKED" = 0 ]; then
  [ "$RC" = 0 ] && [ "$OUT" = "STAMP: nothing to stamp" ] && [ "$(sum "$WORK/real")" = "$BEFORE" ] && ok "(7) the shipped files hold nothing to stamp and are left alone" || bad "(7) exit $RC: $OUT"
else
  [ "$RC" = 0 ] && ! grep -q -E '"(since|minPluginVersion)"[[:space:]]*:[[:space:]]*"unreleased"' "$WORK"/real/schemas/seam-registry.json "$WORK"/real/workflows/*.json \
    && ok "(7) the shipped files' $MARKED marked file(s) stamp cleanly, found by the default root" || bad "(7) exit $RC: $OUT"
fi
exit $FAIL
