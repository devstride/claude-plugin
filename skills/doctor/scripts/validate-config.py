#!/usr/bin/env python3
"""validate-config.py — check a repository's .claude/ds-config.json against the plugin's schema.

Usage: validate-config.py <config path> [--schema <path>] [--json]

The schema defaults to ${CLAUDE_PLUGIN_ROOT}/schemas/ds-config.schema.json (the plugin root this
script ships in when the variable is unset). It is generated from schemas/seam-registry.json, and
this validator implements exactly the keyword subset the generator emits — type (a list included),
properties, patternProperties, additionalProperties, required, enum, items, oneOf, minimum,
exclusiveMinimum — plus
the x-severity annotation for deprecated keys. No JSON Schema library is needed.

Output: the first line is
    CONFIG: <n> error(s), <m> warning(s) against schema <version>
then one line per finding, `ERROR <path>: <message>` or `WARN <path>: <message>`. With --json, one
JSON document instead (`schemaVersion`, `errors`, `warnings`, `findings`; on exit 2 the counts are
null and `fatal` carries the one-line reason). An unknown key is a WARN (with the closest registered key when one is
similar enough); a wrong type, a value outside its enum, a missing required key, both shapes of a
one-of, and a deprecated key marked `error` are ERRORs. Keys starting with `_`, the top-level
`$schema`, and keys at or under a prefix listed in the config's own `repoLocalKeys` are silent.

The schema checks SHAPE only. Whether a command resolves on PATH or a branch exists stays with
doctor's own checks. The script reads two local files, writes nothing and calls no network.

Exit codes: 0 no errors, 1 errors, 2 the config or schema could not be read or parsed (never a
fallback to defaults).
"""
import difflib
import json
import os
import re
import sys

SUGGEST_CUTOFF = 0.75


def type_of(value):
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, int):
        return "integer"
    if isinstance(value, float):
        # draft 2020-12: a number with a zero fractional part (2.0) is an integer
        return "integer" if value.is_integer() else "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    return "object"


def type_ok(value, wanted):
    actual = type_of(value)
    for t in (wanted if isinstance(wanted, list) else [wanted]):
        if t == actual or (t == "number" and actual == "integer"):
            return True
    return False


def same(a, b):
    """JSON equality: true is not 1, and 1 is 1.0."""
    return type_of(a) == type_of(b) and a == b or \
        (type_of(a) in ("integer", "number") and type_of(b) in ("integer", "number") and a == b)


def show(value):
    return json.dumps(value)


def join(path, key):
    return "%s.%s" % (path, key) if path else key


def registered_paths(schema, prefix="", out=None):
    """Every dotted path the schema names, arrays written `[]`, for suggestions."""
    out = [] if out is None else out
    if not isinstance(schema, dict):
        return out
    for key, sub in (schema.get("properties") or {}).items():
        if key == "$schema":
            continue
        path = join(prefix, key)
        out.append(path)
        registered_paths(sub, path, out)
    if isinstance(schema.get("items"), dict):
        registered_paths(schema["items"], prefix + "[]", out)
    for branch in schema.get("oneOf") or []:
        registered_paths(branch, prefix, out)
    return out


class Validator:
    def __init__(self, schema, local_prefixes):
        self.findings = []
        self.local = local_prefixes
        self.known = sorted(set(registered_paths(schema)))

    def add(self, severity, path, message):
        self.findings.append((severity, path or "(root)", message))

    def suggest(self, path):
        generic = re.sub(r"\[\d+\]", "[]", path)
        best, score = None, 0.0
        for k in self.known:
            r = difflib.SequenceMatcher(None, generic, k).ratio()
            if r > score:
                best, score = k, r
        return best if score > SUGGEST_CUTOFF else None

    def is_local(self, path):
        generic = re.sub(r"\[\d+\]", "", path)
        return any(generic == p or generic.startswith(p + ".") for p in self.local)

    def walk(self, value, schema, path, strict=False):
        """Validate value against schema; findings go to self.findings. In strict mode (a oneOf
        branch being tried) an unknown key counts as an error, so a closed branch can fail."""
        if not isinstance(schema, dict):
            return
        if "x-severity" in schema:
            self.add("ERROR" if schema["x-severity"] == "error" else "WARN", path,
                     "deprecated — %s" % schema.get("description", "remove it"))
            return
        if "type" in schema and not type_ok(value, schema["type"]):
            wanted = schema["type"]
            wanted = " or ".join(wanted) if isinstance(wanted, list) else wanted
            self.add("ERROR", path, "expected %s, found %s %s" % (wanted, type_of(value), show(value)))
            return
        if "enum" in schema and not any(same(value, e) for e in schema["enum"]):
            self.add("ERROR", path, "%s is not one of %s" % (
                show(value), ", ".join(show(e) for e in schema["enum"])))
        if "minimum" in schema and type_of(value) in ("integer", "number") \
                and value < schema["minimum"]:
            self.add("ERROR", path, "%s is below the minimum %s" % (show(value), schema["minimum"]))
        if "exclusiveMinimum" in schema and type_of(value) in ("integer", "number") \
                and value <= schema["exclusiveMinimum"]:
            self.add("ERROR", path, "%s must be greater than %s" % (
                show(value), schema["exclusiveMinimum"]))
        if "oneOf" in schema:
            self.one_of(value, schema["oneOf"], path)
        if isinstance(value, dict) and ("properties" in schema or "additionalProperties" in schema):
            props = schema.get("properties") or {}
            patterns = schema.get("patternProperties") or {}
            for req in schema.get("required") or []:
                if req not in value:
                    self.add("ERROR", path, "missing required key `%s`" % req)
            for key, sub in value.items():
                child = join(path, key)
                if key in props:
                    self.walk(sub, props[key], child, strict)
                    continue
                matched = [p for p in patterns if re.search(p, key)]
                if matched:
                    for p in matched:
                        self.walk(sub, patterns[p], child, strict)
                    continue
                if schema.get("additionalProperties") is False:
                    if strict:
                        self.add("ERROR", child, "not part of this shape")
                    elif not self.is_local(child):
                        hint = self.suggest(child)
                        self.add("WARN", child, "unknown key" + (
                            "; did you mean %s?" % hint if hint else ""))
        if isinstance(value, list) and isinstance(schema.get("items"), dict):
            for i, item in enumerate(value):
                self.walk(item, schema["items"], "%s[%d]" % (path, i), strict)

    def one_of(self, value, branches, path):
        passing = []
        for b in branches:
            trial = Validator.__new__(Validator)
            trial.findings, trial.local, trial.known = [], self.local, self.known
            trial.walk(value, b, path, strict=True)
            if not any(f[0] == "ERROR" for f in trial.findings):
                passing.append(b)
        if len(passing) == 1:
            self.walk(value, passing[0], path)
            return
        keyed = [b for b in branches if b.get("required")]
        if isinstance(value, dict):
            present = [b for b in keyed if all(r in value for r in b["required"])]
            if len(present) > 1:
                names = [r for b in present for r in b["required"]]
                self.add("ERROR", path, "sets both %s; exactly one is allowed" % " and ".join(
                    "`%s`" % n for n in names))
                return
            if len(present) == 1:
                # the shape it names, reported in full: an unknown key there stays a WARN
                self.walk(value, present[0], path)
                return
            names = [r for b in keyed for r in b["required"]]
            self.add("ERROR", path, "set exactly one of %s" % " or ".join("`%s`" % n for n in names))
            return
        if not passing:
            kinds = [b.get("type") for b in branches if b.get("type")]
            self.add("ERROR", path, "expected %s, found %s %s" % (
                " or ".join(k if isinstance(k, str) else "/".join(k) for k in kinds),
                type_of(value), show(value)))
        else:
            self.add("ERROR", path, "matches more than one allowed shape")


def schema_version(schema):
    m = re.search(r"devstride--v(\d+\.\d+\.\d+)", str(schema.get("$id", "")))
    return m.group(1) if m else "unknown"


def main(argv):
    as_json = "--json" in argv
    usage = "usage: validate-config.py <config> [--schema <path>] [--json]"

    def fatal(message):
        """Exit 2 with one line, or with one JSON document under --json."""
        if as_json:
            print(json.dumps({"schemaVersion": None, "errors": None, "warnings": None,
                              "fatal": message, "findings": []}, indent=2))
        else:
            print("CONFIG: " + message)
        return 2

    config_path, schema_path = None, None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--schema":
            if i + 1 >= len(argv):
                return fatal(usage)
            schema_path = argv[i + 1]
            i += 1
        elif a == "--json":
            pass
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        elif config_path is None:
            config_path = a
        else:
            return fatal(usage)
        i += 1
    if not config_path:
        return fatal(usage)
    if not schema_path:
        root = os.environ.get("CLAUDE_PLUGIN_ROOT") or os.path.dirname(os.path.dirname(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
        schema_path = os.path.join(root, "schemas", "ds-config.schema.json")
    for label, p in (("schema", schema_path), ("config", config_path)):
        try:
            with open(p, encoding="utf-8") as f:
                loaded = json.load(f)
        except OSError as exc:
            return fatal("cannot read the %s %s: %s" % (label, p, exc.strerror or exc))
        except ValueError as exc:
            return fatal("cannot parse the %s %s: %s" % (label, p, exc))
        if label == "schema":
            schema = loaded
        else:
            config = loaded
    if not isinstance(schema, dict):
        return fatal("cannot parse the schema %s: not a JSON object" % schema_path)
    local = config.get("repoLocalKeys") if isinstance(config, dict) else None
    local = [p for p in local if isinstance(p, str) and p] if isinstance(local, list) else []
    v = Validator(schema, local)
    v.walk(config, schema, "")
    errors = [f for f in v.findings if f[0] == "ERROR"]
    warns = [f for f in v.findings if f[0] == "WARN"]
    version = schema_version(schema)
    if as_json:
        print(json.dumps({"schemaVersion": version, "errors": len(errors), "warnings": len(warns),
                          "findings": [{"severity": s, "path": p, "message": m}
                                       for s, p, m in errors + warns]}, indent=2))
    else:
        print("CONFIG: %d error(s), %d warning(s) against schema %s" % (len(errors), len(warns), version))
        for s, p, m in errors + warns:
            print("%s %s: %s" % (s, p, m))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
