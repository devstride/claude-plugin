#!/bin/bash
# Tests for the Needs-you list (skills/build-item/references/needs-you.md): the registry and the
# generated schema carry its three keys and no other, each skill that has an owner fork cites the
# contract exactly once, the contract keeps the parts the skills rely on (both markers, never
# waiting, owner-only answers, failing open, hard stops), its "Cited by" list names the real
# citers, and a config with the keys validates while a wrong type or a stray key is reported.
# No network; nothing here talks to a tracker.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; VAL="$ROOT/skills/doctor/scripts/validate-config.py"
SCHEMA="$ROOT/schemas/ds-config.schema.json"; FIX="$ROOT/scripts/tests/fixtures/config"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

python3 - "$ROOT" > "$WORK/out" <<'PY'
import glob, json, os, re, sys
root = sys.argv[1]
rel = "skills/build-item/references/needs-you.md"
ref = "`${CLAUDE_PLUGIN_ROOT}/%s`" % rel
def check(label, good, detail=""):
    print(("  ok   " if good else "  FAIL ") + label + ("" if good else "  " + str(detail)))
def read(path):
    with open(os.path.join(root, path), encoding="utf-8") as f:
        return f.read()

# (1) the registry: an object and three string keys, nothing else under it
reg = {e["key"]: e for e in json.load(open(os.path.join(root, "schemas/seam-registry.json")))["settings"]}
mine = sorted(k for k in reg if k == "needsYou" or k.startswith("needsYou."))
want = ["needsYou", "needsYou.fallbackItem", "needsYou.label", "needsYou.view"]
check("(1) the registry holds needsYou and its three keys, and no other", mine == want
      and reg["needsYou"]["type"] == "object" and all(reg[k]["type"] == "string" for k in want[1:])
      and not any("default" in reg[k] or reg[k].get("required") for k in want)
      and rel in reg["needsYou"]["description"], mine)

# (2) the generated schema: a closed object of three optional strings
node = json.load(open(os.path.join(root, "schemas/ds-config.schema.json")))["properties"].get("needsYou", {})
props = node.get("properties", {})
check("(2) the schema carries the same three keys as optional strings in a closed object",
      set(props) == {"label", "view", "fallbackItem"} and all(v.get("type") == "string" for v in props.values())
      and node.get("additionalProperties") is False and not node.get("required"), node)

# (3) the citing skills: exactly once each, in the body, naming the switch
citers = {"build-item": "`needsYou.label` set", "ultracode-build": "`needsYou.label` is set",
          "review": "`needsYou.label` is set", "release": "`needsYou.label` set", "doctor": "**`needsYou`**"}
problems = []
for skill, switch in citers.items():
    body = read("skills/%s/SKILL.md" % skill)
    if body.count(ref) != 1:
        problems.append("%s cites it %d times" % (skill, body.count(ref)))
        continue
    at = body.index(ref)
    para = body[body.rfind("\n- ", 0, at):body.find("\n- ", at) if body.find("\n- ", at) > 0 else len(body)]
    if switch not in para:
        problems.append("%s: its citation does not name %s" % (skill, switch))
    if skill != "doctor" and not re.search(r"[Rr]ead\s+$", body[:at]):
        problems.append("%s: not in the 'Read <path> when' form" % skill)
check("(3) build-item, ultracode-build, review, release and doctor each cite the contract exactly once, naming the switch",
      not problems, problems)

# (4) nobody else's body cites it, and no skill restates the markers
real = sorted(os.path.basename(os.path.dirname(p)) for p in glob.glob(os.path.join(root, "skills/*/SKILL.md"))
              if ref in open(p, encoding="utf-8").read())
restated = [os.path.basename(os.path.dirname(p)) for p in glob.glob(os.path.join(root, "skills/*/SKILL.md"))
            if "Needs you: " in open(p, encoding="utf-8").read()]
check("(4) only those five bodies cite it, and none restates the contract's markers",
      real == sorted(citers) and not restated, (real, restated))

# (5) the contract's own shape
text = read(rel)
check("(5) the contract is load: contract and ends with a Cited by list",
      text.startswith("---\nload: contract\n---\n") and text.count("\n## Cited by\n") == 1
      and text.rstrip().rsplit("\n## ", 1)[1].startswith("Cited by"))

# (6) the Cited by list names exactly the real citers
cited = sorted(set(re.findall(r"^- `([a-z-]+)` SKILL\.md", text.split("\n## Cited by\n", 1)[1], re.M)))
check("(6) the Cited by list matches the bodies that really cite it", cited == real, (cited, real))

# (7) the parts the skills rely on
body = text.split("\n## Cited by\n", 1)[0]
flat = " ".join(body.split())
parts = {
    "the open marker as the comment's last paragraph": "as the LAST paragraph: `Needs you: open`",
    "the answered marker": "`Needs you: answered`",
    "never waiting": "Never wait on a queued question, never poll it, never notify again.",
    "the gated-item skip": "skipped exactly as a gated item is",
    "owner-only answers": "Only the owner's own words count",
    "no relayed answers": "never an answer relayed",
    "for that question only": "for that question only",
    "one bounded search": "ONE `search_items` on the tag",
    "exactly once": "Queue it — exactly once per question",
    "failing open": "fall back to stopping and asking",
    "never losing the question": "Never lose the question",
    "the hard stop": "a thread answer never stands in for the yes that rule requires",
    "off when the label is absent": "Absent → the feature is OFF",
    "attended runs unchanged": "An attended, interactive run asks in the conversation",
    "the tag resolved to its id and read back": "read the item back and confirm the tag is there",
    "the rich comment form": "`add_comment` in the `{ html }` form",
    "auto-release unchanged": "`epicIntegrationBranches.autoRelease`",
    "doctor's warning": "no such tag → WARN",
}
missing = [name for name, needle in parts.items() if needle not in flat]
check("(7) the contract keeps both markers, never-wait, owner-only answers, fail-open, the hard stop and doctor's warning",
      not missing, missing)

# (8) the three keys are the only needsYou keys the shipped text cites
corpus = [text] + [open(p, encoding="utf-8").read() for p in
                   glob.glob(os.path.join(root, "skills/*/SKILL.md")) + glob.glob(os.path.join(root, "skills/*/references/*.md"))
                   + [os.path.join(root, "README.md")]]
used = sorted(set(re.findall(r"needsYou\.[A-Za-z]+", "\n".join(corpus))))
check("(8) the shipped text cites only needsYou.label, needsYou.view and needsYou.fallbackItem",
      used == ["needsYou.fallbackItem", "needsYou.label", "needsYou.view"], used)

# (9) the release keeps its notification beside the queue
auto = " ".join(read("skills/release/references/auto-start.md").split())
check("(9) the unattended release stop still sends its PushNotification, queues beside it and still waits for the yes",
      "sends ONE `PushNotification`" in auto and "With `needsYou.label` set it also queues the question" in auto
      and "a thread answer is never the yes" in auto and "Then it waits for the yes" in auto)
PY
OUT="$(cat "$WORK/out")"
printf '%s\n' "$OUT"; printf '%s\n' "$OUT" | grep -q '^  FAIL' && FAIL=1
[ "$(printf '%s\n' "$OUT" | grep -c '^  ok')" = 9 ] || bad "(1-9) expected nine results, got: $OUT"

# (10)-(14) the config shape, through the validator doctor and setup run
run() { RES="$(python3 "$VAL" "$1" --schema "$SCHEMA" 2>&1)"; RC=$?; }
cfg() { printf '%s\n' "$1" > "$WORK/c.json"; run "$WORK/c.json"; }
CLEAN="^CONFIG: 0 error(s), 0 warning(s) against schema "
run "$FIX/full.json"
[ "$RC" = 0 ] && printf '%s\n' "$RES" | head -1 | grep -q "$CLEAN" && grep -q '"needsYou"' "$FIX/full.json" \
  && ok "(10) the full-coverage fixture carries the block and is clean" || bad "(10) exit $RC: $RES"
cfg '{"needsYou": {"label": "needs you"}}'
[ "$RC" = 0 ] && printf '%s\n' "$RES" | head -1 | grep -q "$CLEAN" \
  && ok "(11) the label alone is clean: the view and the fallback item are optional" || bad "(11) exit $RC: $RES"
cfg '{}'
[ "$RC" = 0 ] && printf '%s\n' "$RES" | head -1 | grep -q "$CLEAN" \
  && ok "(12) no block at all is clean: the feature is simply off" || bad "(12) exit $RC: $RES"
cfg '{"needsYou": {"label": 7, "view": ["a"], "fallbackItem": 20100}}'
[ "$RC" = 1 ] && printf '%s\n' "$RES" | head -1 | grep -q "^CONFIG: 3 error(s)" \
  && printf '%s\n' "$RES" | grep -q "^ERROR needsYou.label" && printf '%s\n' "$RES" | grep -q "^ERROR needsYou.view" \
  && printf '%s\n' "$RES" | grep -q "^ERROR needsYou.fallbackItem" \
  && ok "(13) a label, a view and a fallback item of the wrong type are three ERRORs" || bad "(13) exit $RC: $RES"
cfg '{"needsYou": "needs you"}'
[ "$RC" = 1 ] && printf '%s\n' "$RES" | grep -q "^ERROR needsYou" \
  && ok "(14) a bare string in place of the block is an ERROR" || bad "(14) exit $RC: $RES"
cfg '{"needsYou": {"label": "needs you", "lable": "x"}}'
[ "$RC" = 0 ] && printf '%s\n' "$RES" | grep -q "^WARN needsYou.lable: unknown key; did you mean needsYou.label?$" \
  && ok "(15) a misspelled key is reported with the likely key" || bad "(15) exit $RC: $RES"

exit "$FAIL"
