#!/usr/bin/env python3
"""validate-config.py — check a repository's .claude/ds-config.json against the plugin's schema.

Usage: validate-config.py <config path> [--schema <path>] [--json]

The schema defaults to ${CLAUDE_PLUGIN_ROOT}/schemas/ds-config.schema.json (the plugin root this
script ships in when the variable is unset). It is generated from schemas/seam-registry.json, and
this validator implements exactly the keyword subset the generator emits — type (a list included),
properties, patternProperties, additionalProperties (false, or the schema every other key's value
must meet), required, enum, items, oneOf, minimum, exclusiveMinimum, its own x-setTogether
(children set all together or not at all; null is unset) and its own x-warnMinimum /
x-warnMaximum (a value outside them is ignored by its reader, which keeps its default: a WARN) —
plus
the x-severity annotation for deprecated keys. No JSON Schema library is needed.

Output: the first line is
    CONFIG: <n> error(s), <m> warning(s) against schema <version>
then one line per finding, `ERROR <path>: <message>`, `WARN <path>: <message>` or (uncounted)
`NOTE <path>: <message>` — a NOTE is the legacy `supportTrain` name (carrying both it and
`releaseTrain` is an ERROR) or a current deferred container title also listed as a legacy one; an
empty deferred container title is a WARN. With --json, one
JSON document instead (`schemaVersion`, `errors`, `warnings`, `findings`; on exit 2 the counts are
null and `fatal` carries the one-line reason). An unknown key is a WARN (with the closest registered key when one is
similar enough); a wrong type, a value outside its enum, a missing required key, both shapes of a
one-of, one key of a set-together group set without the others, and a deprecated key marked
`error` are ERRORs; a number outside an x-warnMinimum / x-warnMaximum range is a WARN. Keys
starting with `_`, the top-level `$schema`, and keys at or under a prefix listed in the config's own `repoLocalKeys` are silent.

The schema checks SHAPE only. Whether a command resolves on PATH or a branch exists stays with
doctor's own checks. The script reads two local files, writes nothing and calls no network.

Exit codes: 0 no errors, 1 errors, 2 the config or schema could not be read or parsed (never a
fallback to defaults).
"""
import datetime
import difflib
import importlib.util
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


def deferred_container_checks(v, config):
    """What the schema cannot say about the deferred container's titles: an empty title matches
    nothing (WARN), and a current title that is also listed as a legacy one is redundant (NOTE).
    A wrong type is already the schema's ERROR."""
    defects = config.get("defects") if isinstance(config, dict) else None
    if not isinstance(defects, dict):
        return
    title = defects.get("deferredContainerTitle")
    if isinstance(title, str) and not title.strip():
        v.add("WARN", "defects.deferredContainerTitle", "an empty title matches no container; "
              "remove it to use the default")
    legacy = defects.get("deferredContainerLegacyTitles")
    if isinstance(legacy, list):
        for i, entry in enumerate(legacy):
            if isinstance(entry, str) and not entry.strip():
                v.add("WARN", "defects.deferredContainerLegacyTitles[%d]" % i, "an empty title matches nothing")
        norm = lambda t: " ".join(t.split()).casefold()
        effective = title if isinstance(title, str) and title.strip() else ("Deferred" if title is None else "")
        if effective and norm(effective) in {norm(t) for t in legacy if isinstance(t, str)}:
            v.add("NOTE", "defects.deferredContainerLegacyTitles", "lists the current title too; "
                  "the current title is matched already")


def pre_ship_checks(v, config):
    """What the schema cannot say: `runAt` belongs only to a `releaseOnly` entry, and never with `onlyWhenTouched`."""
    entries = config.get("preShipChecks") if isinstance(config, dict) else None
    if not isinstance(entries, list):
        return
    for i, entry in enumerate(entries):
        if isinstance(entry, dict) and "runAt" in entry and entry.get("when") != "releaseOnly":
            v.add("ERROR", "preShipChecks[%d].runAt" % i, "is only valid on an entry whose `when` is \"releaseOnly\"")
        elif isinstance(entry, dict) and "runAt" in entry and entry.get("onlyWhenTouched") is True:
            v.add("ERROR", "preShipChecks[%d].runAt" % i, "cannot be combined with `onlyWhenTouched: true`: a train check is skipped only by same-snapshot train evidence, never by path")


def real_date(value):
    if not (isinstance(value, str) and re.match(r"^\d{4}-\d{2}-\d{2}$", value)):
        return False
    try:
        return datetime.date.fromisoformat(value) <= datetime.date.today()
    except ValueError:
        return False


def auto_start_checks(v, config):
    """`release.autoStart.enabled` needs a claims store; the standing yes needs a classify skill."""
    release = config.get("release") if isinstance(config, dict) else None
    if not isinstance(release, dict):
        return
    auto = release.get("autoStart")
    if isinstance(auto, dict) and auto.get("enabled") is True and not isinstance(config.get("claims"), dict):
        v.add("ERROR", "release.autoStart.enabled", "needs a `claims` block: without a one-winner release-train claim two sessions could start the same release")
    light = release.get("lightRelease")
    if isinstance(light, dict) and light.get("standingYes") is True and not release.get("classifySkill"):
        v.add("WARN", "release.lightRelease.standingYes", "has no effect without `release.classifySkill`: no release is ever classified LIGHT")
    if isinstance(light, dict) and light.get("standingYes") is True and not release.get("clearance"):
        v.add("WARN", "release.lightRelease.standingYes", "has no effect without `release.clearance`: no tower status can show the release On final")
    full = release.get("fullRelease")
    if not (isinstance(full, dict) and full.get("standingYes") is True):
        return
    key = "release.fullRelease.standingYes"
    if not release.get("clearance"):
        v.add("WARN", key, "has no effect without `release.clearance`: no tower status can show the release On final")
    if not real_date(full.get("ownerDecision")):
        v.add("WARN", key, "has no effect without `release.fullRelease.ownerDecision` (YYYY-MM-DD, a real date not after today, the day the owner wrote the yes)")
    globs = full.get("migrationGlobs")
    if not (isinstance(globs, list) and globs):
        v.add("WARN", key, "has no effect without `release.fullRelease.migrationGlobs`: no migration could be told apart")
    entries = full.get("approvedMigrations")
    for i, entry in enumerate(entries if isinstance(entries, list) else []):
        ok = (isinstance(entry, dict) and isinstance(entry.get("blob"), str) and re.match(r"^[0-9a-f]{40}([0-9a-f]{24})?$", entry["blob"])
              and isinstance(entry.get("path"), str) and entry["path"].strip()
              and isinstance(entry.get("item"), str) and re.match(r"^I\d+$", entry["item"]) and real_date(entry.get("approved")))
        if not ok:
            v.add("ERROR", "release.fullRelease.approvedMigrations[%d]" % i, "needs blob (a full git blob id), path, item (I#####) and approved (a real YYYY-MM-DD, not after today): a malformed entry makes every full release ask")


def backstop_checks(v, config):
    """`release.backstop` needs a claims store and a release train: the rules are backstop.py's own
    `problems`, imported from the plugin copy this validator ships in, so doctor and the check agree."""
    path = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
                        "release/scripts/backstop.py")
    try:
        spec = importlib.util.spec_from_file_location("backstop", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        found = module.problems(config)
    except Exception as exc:  # a broken copy is reported, never a traceback
        v.add("WARN", "release.backstop", "its checks could not run: %s" % exc)
        return
    for severity, where, message in found:
        v.add(severity, where, message)


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
        if type_of(value) in ("integer", "number"):
            low, high = schema.get("x-warnMinimum"), schema.get("x-warnMaximum")
            if (low is not None and value < low) or (high is not None and value > high):
                self.add("WARN", path, "%s is outside %s..%s; ignored, the default stands" % (
                    show(value), "" if low is None else low, "" if high is None else high))
        if "oneOf" in schema:
            self.one_of(value, schema["oneOf"], path)
        if "x-setTogether" in schema and isinstance(value, dict):
            group = schema["x-setTogether"]
            present = [k for k in group if value.get(k) is not None]
            if present and len(present) != len(group):
                missing = [k for k in group if k not in present]
                self.add("ERROR", path, "sets %s without %s; set them together or not at all" % (
                    " and ".join("`%s`" % join(path, k) for k in present),
                    " and ".join("`%s`" % join(path, k) for k in missing)))
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
                if isinstance(schema.get("additionalProperties"), dict):
                    self.walk(sub, schema["additionalProperties"], child, strict)
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
    if isinstance(config, dict) and config.get("releaseTrain") is not None and config.get("supportTrain") is not None:
        v.add("ERROR", "supportTrain", "supportTrain is the old name of releaseTrain and both are set; "
              "keep releaseTrain only")
    elif isinstance(config, dict) and config.get("supportTrain") is not None:
        v.add("NOTE", "supportTrain", "supportTrain is the old name of releaseTrain; rename it")
    deferred_container_checks(v, config)
    pre_ship_checks(v, config)
    auto_start_checks(v, config)
    if isinstance(config, dict):
        backstop_checks(v, config)
    errors = [f for f in v.findings if f[0] == "ERROR"]
    warns = [f for f in v.findings if f[0] == "WARN"]
    notes = [f for f in v.findings if f[0] == "NOTE"]
    version = schema_version(schema)
    if as_json:
        print(json.dumps({"schemaVersion": version, "errors": len(errors), "warnings": len(warns),
                          "findings": [{"severity": s, "path": p, "message": m}
                                       for s, p, m in errors + warns + notes]}, indent=2))
    else:
        print("CONFIG: %d error(s), %d warning(s) against schema %s" % (len(errors), len(warns), version))
        for s, p, m in errors + warns + notes:
            print("%s %s: %s" % (s, p, m))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
