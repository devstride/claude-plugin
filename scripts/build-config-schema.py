#!/usr/bin/env python3
"""scripts/build-config-schema.py — generate the config schema and its readable table from the
one seam registry, schemas/seam-registry.json.

Two files are generated, and neither is ever edited by hand:

  schemas/ds-config.schema.json                 JSON Schema (draft 2020-12) for a consuming
                                                repository's .claude/ds-config.json. Its $id names
                                                the release tag, so each tag publishes its own copy.
  skills/setup/references/seam-registry.md      the same registry as two readable tables.

The schema uses ONLY the keyword subset skills/doctor/scripts/validate-config.py implements
(VALIDATION_KEYWORDS below) plus the annotations in ANNOTATIONS; scripts/tests/seam-registry.sh
fails the moment the generator emits anything else, because the validator would silently ignore it.

Registry rules the generator applies:
  - every key is a dotted path; `name[]` steps into the items of the array `name`;
  - every parent of a key is registered before the key (an object, or an `object[]` array);
  - objects are closed (additionalProperties: false), except for keys starting with `_` (the
    readme convention) and, at the top level, `$schema`;
  - a hook whose shape is `provider-or-commands` becomes a oneOf: null, the provider shape (every
    registered child except `commands`) or the commands shape (only `commands`, plus the children
    the hook's optional `sharedKeys` list names, which both shapes accept);
  - a `deprecated` setting becomes an x-severity annotation carrying its message.
  - an object setting's `setTogether` list becomes `x-setTogether`: those children are all set
    (non-null) or all unset, never one alone (the validator's own keyword; JSON Schema has none
    that treats null as unset).
  - a setting's `warnMinimum` / `warnMaximum` become `x-warnMinimum` / `x-warnMaximum`: a value
    outside them is ignored by its reader, which keeps its default, so the validator WARNs rather
    than errs (the validator's own keywords; `minimum`, `exclusiveMinimum` and `maximum` stay errors);
  - an object setting's `values` (a type plus optional bounds) types every entry of a map whose
    keys are the user's own (`additionalProperties` carrying that schema instead of false);
  - a hook a step skill runs carries `step` (the skill's directory) and `stepVerdict` (the
    verdict lines its `## Verdict` section spells); scripts/tests/step-skills.sh compares them.

Usage: build-config-schema.py --write | --check [--release [--base <ref>]]
  --write     regenerate both files
  --check     regenerate in memory; exit 1 naming each file that differs from its committed copy
  --release   with --check: when .claude-plugin/plugin.json's version differs from the one at
              <base> (default origin/main), also fail on any registry entry still `unreleased`
Exit codes: 0 ok, 1 drift / registry fault / unreleased entry, 2 usage or unreadable input.
"""
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REGISTRY = "schemas/seam-registry.json"
SCHEMA = "schemas/ds-config.schema.json"
TABLE = "skills/setup/references/seam-registry.md"
ID_FORMAT = "https://raw.githubusercontent.com/devstride/claude-plugin/devstride--v{}/schemas/ds-config.schema.json"

VALIDATION_KEYWORDS = {"type", "properties", "patternProperties", "additionalProperties",
                       "required", "enum", "items", "oneOf", "minimum", "exclusiveMinimum", "maximum",
                       "x-setTogether", "x-warnMinimum", "x-warnMaximum"}
ANNOTATIONS = {"$schema", "$id", "title", "description", "default", "x-severity"}
BOUNDS = (("minimum", "minimum"), ("exclusiveMinimum", "exclusiveMinimum"), ("maximum", "maximum"),
          ("warnMinimum", "x-warnMinimum"), ("warnMaximum", "x-warnMaximum"))
HOOK_FIELDS = ["key", "shape", "valueType", "nullable", "payload", "verdict", "calledBy",
               "unset", "contract", "since"]
SETTING_FIELDS = ["key", "type", "description", "since"]
SHAPES = {"skill", "command", "provider-or-commands"}
TYPES = {"string", "boolean", "integer", "number", "object", "array", "null", "any",
         "string[]", "object[]"}


def fail(code, message):
    print("config-schema: " + message, file=sys.stderr)
    sys.exit(code)


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
        return f.read()


def lint(registry):
    """Structural faults in the registry itself, as one string each."""
    problems, seen = [], set()
    if not isinstance(registry, dict) or not isinstance(registry.get("hooks"), list) \
            or not isinstance(registry.get("settings"), list):
        return ["the registry must be an object with `hooks` and `settings` arrays"]
    for kind, fields in (("hooks", HOOK_FIELDS), ("settings", SETTING_FIELDS)):
        for e in registry[kind]:
            key = e.get("key") if isinstance(e, dict) else None
            if not isinstance(key, str) or not key:
                problems.append("%s entry without a key: %r" % (kind, e))
                continue
            if key in seen:
                problems.append("duplicate key %s" % key)
            seen.add(key)
            for f in fields:
                if f not in e:
                    problems.append("%s %s lacks %s" % (kind, key, f))
            if kind == "hooks":
                if e.get("shape") not in SHAPES:
                    problems.append("hook %s has an unknown shape %r" % (key, e.get("shape")))
                if e.get("shape") in ("skill", "provider-or-commands") and not e.get("modes"):
                    problems.append("hook %s is a %s hook without modes" % (key, e.get("shape")))
                shared = e.get("sharedKeys", [])
                if not isinstance(shared, list) or not all(isinstance(k, str) and k for k in shared) \
                        or (shared and e.get("shape") != "provider-or-commands"):
                    problems.append("hook %s: sharedKeys is a list of child names on a "
                                    "provider-or-commands hook" % key)
                if not isinstance(e.get("calledBy"), list) or not e.get("calledBy"):
                    problems.append("hook %s needs a non-empty calledBy list" % key)
                if "step" in e or "stepVerdict" in e:
                    sv = e.get("stepVerdict")
                    if not isinstance(e.get("step"), str) or not e.get("step"):
                        problems.append("hook %s needs step, the step skill's directory name" % key)
                    if not isinstance(sv, list) or not sv or not all(isinstance(v, str) and v for v in sv):
                        problems.append("hook %s needs stepVerdict, the step's verdict lines" % key)
            t = e.get("valueType" if kind == "hooks" else "type")
            for one in (t if isinstance(t, list) else [t]):
                if one not in TYPES:
                    problems.append("%s has an unknown type %r" % (key, one))
            values = e.get("values")
            if values is not None and (not isinstance(values, dict) or t != "object"
                                       or values.get("type") not in TYPES):
                problems.append("%s: values belongs on an object setting and names a type" % key)
            since = e.get("since")
            if not isinstance(since, str) or not since:
                problems.append("%s has no since" % key)
    return problems


def apply_bounds(node, spec):
    """Copy a registry entry's bounds onto its schema node, under their schema names."""
    for field, keyword in BOUNDS:
        if field in spec:
            node[keyword] = spec[field]
    return node


def allowed(spec):
    """The table's Allowed cell for an entry's enum or bounds (a map's are its values')."""
    if "enum" in spec:
        return cell(spec["enum"])
    parts = []
    if "minimum" in spec:
        parts.append(">= %s" % spec["minimum"])
    if "exclusiveMinimum" in spec:
        parts.append("> %s" % spec["exclusiveMinimum"])
    if "maximum" in spec:
        parts.append("<= %s" % spec["maximum"])
    if "warnMinimum" in spec or "warnMaximum" in spec:
        parts.append("%s..%s, else warned and the default stands" % (
            spec.get("warnMinimum", ""), spec.get("warnMaximum", "")))
    if isinstance(spec.get("values"), dict):
        inner = allowed(spec["values"])
        return "each value %s%s" % (spec["values"]["type"], "" if inner == "—" else ", " + inner)
    return ", ".join(parts) or "—"


def closed_object():
    return {"type": "object", "properties": {}, "patternProperties": {"^_": {}},
            "additionalProperties": False}


def node_for(type_, nullable=False):
    types = type_ if isinstance(type_, list) else [type_]
    if nullable and "null" not in types:
        types = types + ["null"]
    if types == ["object"] or (len(types) == 2 and "object" in types and "null" in types):
        node = closed_object()
        if len(types) == 2:
            node["type"] = ["object", "null"]
        return node
    if types == ["string[]"]:
        return {"type": "array", "items": {"type": "string"}}
    if types == ["object[]"]:
        return {"type": "array", "items": closed_object()}
    if types == ["any"]:
        return {}
    plain = [t for t in types if t not in ("any",)]
    return {"type": plain[0] if len(plain) == 1 else plain}


def build_schema(registry, version):
    root = closed_object()
    root.update({"$schema": "https://json-schema.org/draft/2020-12/schema",
                 "$id": ID_FORMAT.format(version),
                 "title": "DevStride delivery-loop repository config (.claude/ds-config.json)"})
    root = {k: root[k] for k in ("$schema", "$id", "title", "type", "properties",
                                 "patternProperties", "additionalProperties")}
    root["properties"]["$schema"] = {"type": "string"}
    entries = [dict(e, _hook=True) for e in registry["hooks"]] + list(registry["settings"])
    # parents first: a shorter path is placed before any path under it
    entries.sort(key=lambda e: e["key"].count("."))
    providers = []
    for e in entries:
        segs = e["key"].split(".")
        parent = root
        for seg in segs[:-1]:
            name = seg[:-2] if seg.endswith("[]") else seg
            props = parent.get("properties")
            if props is None or name not in props:
                fail(1, "%s: its parent %s is not registered as an object" % (e["key"], name))
            parent = props[name]
            if seg.endswith("[]"):
                parent = parent.get("items")
                if not isinstance(parent, dict) or "properties" not in parent:
                    fail(1, "%s: %s is not registered as object[]" % (e["key"], name))
        if "properties" not in parent:
            fail(1, "%s: its parent is not an object" % e["key"])
        leaf = segs[-1]
        if e.get("deprecated"):
            node = {"x-severity": e["deprecated"]["severity"],
                    "description": e["deprecated"]["message"]}
        else:
            if e.get("_hook"):
                node = node_for(e["valueType"], e.get("nullable") is True)
            else:
                node = node_for(e["type"])
            if "enum" in e:
                node["enum"] = e["enum"]
            if "setTogether" in e:
                node["x-setTogether"] = e["setTogether"]
            apply_bounds(node, e)
            if isinstance(e.get("values"), dict):
                node["additionalProperties"] = apply_bounds(node_for(e["values"]["type"]),
                                                            e["values"])
            if "default" in e:
                node["default"] = e["default"]
            node["description"] = e["description"] if not e.get("_hook") else \
                "%s hook — %s" % (e["shape"], e["payload"])
        parent["properties"][leaf] = node
        if e.get("required"):
            parent.setdefault("required", []).append(leaf)
        if e.get("_hook") and e["shape"] == "provider-or-commands":
            providers.append((parent, leaf, e.get("sharedKeys", [])))
    for parent, leaf, shared in providers:
        node = parent["properties"][leaf]
        props, req = node["properties"], node.get("required", [])
        provider = closed_object()
        provider["properties"] = {k: v for k, v in props.items() if k != "commands"}
        provider["required"] = [r for r in req if r != "commands"]
        commands = closed_object()
        commands["properties"] = {"commands": props.get("commands", {})}
        for k in shared:
            if k not in props:
                fail(1, "%s: sharedKeys names %s, which is not registered under it" % (leaf, k))
            commands["properties"][k] = props[k]
        commands["required"] = ["commands"]
        parent["properties"][leaf] = {"description": node.get("description", ""),
                                      "oneOf": [{"type": "null"}, provider, commands]}
    return root


def cell(value):
    if isinstance(value, list):
        value = ", ".join("`%s`" % json.dumps(v) if not isinstance(v, str) else v for v in value)
    elif not isinstance(value, str):
        value = "`%s`" % json.dumps(value)
    return value.replace("|", "\\|").replace("\n", " ")


def build_table(registry, version):
    out = ["---", "load: contract", "---",
           "# The seam registry — every hook the plugin calls, and every other config key", "",
           "Generated from `schemas/seam-registry.json` by `scripts/build-config-schema.py --write`;",
           "never edit it by hand. The same registry generates `schemas/ds-config.schema.json`, which",
           "`${CLAUDE_PLUGIN_ROOT}/skills/doctor/scripts/validate-config.py` checks a repository's",
           "`.claude/ds-config.json` against. Schema version: %s." % version, "",
           "A key written `a[].b` is the field `b` of each entry in the array `a`. `since` is the first",
           "release that carries the key, `pre-registry` for every key older than the registry, and",
           "`unreleased` until the next release names it. Keys under a `repoLocalKeys` prefix, keys",
           "starting with `_` and `$schema` are never reported as unknown.", "",
           "## Hooks", "",
           "| Key | Shape | Value | Modes | Payload | Verdict | Called by | When unset | Contract | Since |",
           "|---|---|---|---|---|---|---|---|---|---|"]
    for h in registry["hooks"]:
        value = cell(h["valueType"]) + (" or null" if h.get("nullable") else "")
        if h.get("required"):
            value = "**Required.** " + value
        out.append("| `%s` | %s | %s | %s | %s | %s | %s | %s | `%s` | %s |" % (
            h["key"], h["shape"], value, cell(h.get("modes", [])) or "—", cell(h["payload"]),
            cell(h["verdict"]), cell(h["calledBy"]), cell(h["unset"]), h["contract"], h["since"]))
    out += ["", "## Settings", "",
            "| Key | Type | Allowed | Default | Meaning | Since |", "|---|---|---|---|---|---|"]
    for s in registry["settings"]:
        meaning = s["description"]
        if s.get("deprecated"):
            meaning = "**Deprecated (%s):** %s" % (s["deprecated"]["severity"],
                                                    s["deprecated"]["message"])
        if s.get("required"):
            meaning = "**Required.** " + meaning
        out.append("| `%s` | %s | %s | %s | %s | %s |" % (
            s["key"], cell(s["type"]), allowed(s),
            cell(s["default"]) if "default" in s else "—", cell(meaning), s["since"]))
    out += ["", "## Cited by", "",
            "- `doctor` SKILL.md — §4, the config shape check (runs the validator).",
            "- `skills/setup/references/validation-checklist.md` — check 0, config shape.", ""]
    return "\n".join(out)


def plugin_version(text):
    try:
        return json.loads(text)["version"]
    except Exception:
        return None


def main(argv):
    mode, release, base = None, False, "origin/main"
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--write", "--check"):
            if mode:
                fail(2, "pass exactly one of --write and --check")
            mode = a[2:]
        elif a == "--release":
            release = True
        elif a == "--base":
            if i + 1 >= len(argv):
                fail(2, "--base needs a value")
            base = argv[i + 1]
            i += 1
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            fail(2, "unknown argument: %s" % a)
        i += 1
    if not mode or (release and mode != "check"):
        fail(2, "usage: build-config-schema.py --write | --check [--release [--base <ref>]]")
    try:
        registry = json.loads(read(REGISTRY))
        version = plugin_version(read(".claude-plugin/plugin.json"))
    except (OSError, ValueError) as exc:
        fail(2, "cannot read the registry or plugin.json: %s" % exc)
    if not version:
        fail(2, ".claude-plugin/plugin.json has no version")
    problems = lint(registry)
    if problems:
        for p in problems:
            print("REGISTRY " + p)
        return 1
    schema = json.dumps(build_schema(registry, version), indent=2, ensure_ascii=False) + "\n"
    table = build_table(registry, version)
    if mode == "write":
        for rel, text in ((SCHEMA, schema), (TABLE, table)):
            with open(os.path.join(ROOT, rel), "w", encoding="utf-8") as f:
                f.write(text)
        print("SCHEMA: wrote %s and %s (version %s)" % (SCHEMA, TABLE, version))
        return 0
    bad = 0
    for rel, text in ((SCHEMA, schema), (TABLE, table)):
        try:
            committed = read(rel)
        except OSError:
            committed = None
        if committed != text:
            print("DRIFT %s: differs from what the registry generates; run "
                  "scripts/build-config-schema.py --write" % rel)
            bad = 1
    if release:
        shown = subprocess.run(["git", "-C", ROOT, "show", "%s:.claude-plugin/plugin.json" % base],
                               capture_output=True, text=True)
        if shown.returncode != 0:
            fail(2, "cannot read .claude-plugin/plugin.json at %s" % base)
        if plugin_version(shown.stdout) != version:
            for kind in ("hooks", "settings"):
                for e in registry[kind]:
                    if e.get("since") == "unreleased":
                        print("UNRELEASED %s: set since to %s for this release" % (e["key"], version))
                        bad = 1
    if not bad:
        print("SCHEMA: ok (%d hooks, %d settings, version %s)" % (
            len(registry["hooks"]), len(registry["settings"]), version))
    return bad


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
