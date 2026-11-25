#!/usr/bin/env python3
"""scripts/workflow-registry.py — the permanent version record of every built-in workflow and
step contract (workflows/registry.json) and the history page generated from it
(workflows/HISTORY.md). Standard library only.

The registry only ever grows. A workflow has one row per version it shipped with: the plugin
release that first carried it, that release's date, the sha256 of its canonical form (the runner's
own rule, without minPluginVersion, which a release restamps), the minimum plugin version, each
step id with its contract, and one plain sentence on what changed. A step contract has one row
per published revision of each major version. Rows are appended by `record`, named by `stamp`
when a release is prepared, and never edited or deleted by hand.

  record                 append a row for every definition or contract whose fingerprint has no
                         row yet, marked `unreleased`; it never touches a released row, and it
                         refuses a definition that changed without a version bump
  check [--base <ref>]   every rule below; the base is what this branch started from (the newer of
                         its merge bases with origin/train/release and origin/develop, else
                         origin/main or origin/master); `--base none` skips the base comparison
  stamp <version> [--date YYYY-MM-DD] [--changelog <file>]
                         name the release in every `unreleased` row: the version, the date (today
                         in US Central time unless given) and, for a row with no note, the
                         headline of that version's CHANGELOG entry that names it (its file, its
                         `<name> workflow`, its id in backticks, or a hyphenated id), else a neutral
                         sentence ("Revised in <version>."); then rewrite HISTORY.md
  verify-stamp <version> no row is left `unreleased`, every row of <version> carries its date and
                         a note, and HISTORY.md is current
  history [--write|--check]
                         print, write or check the history page

Every command takes `--root <plugin dir>` (default: the folder above this script).

What `check` refuses:
  - a registry that does not match schemas/workflow-registry.schema.json
  - rows out of order: a workflow's versions start at 1 and rise by exactly one; a version repeats
    only on a historical row marked `slip` or when every earlier row at that version is `dormant`
    (every release that carried it had no runner for it). The new row is `dormant` only when this
    plugin cannot run the definition; once a row at a version is not, that version is closed and
    its step ids are permanent. A contract's majors
    rise by at most one, and a major may hold several revisions (the catalog's rule: additive
    within a major)
  - a contract new in this release that the catalog does not write `"since": "unreleased"`, or
    one whose `since` is not the release its first row names
  - a definition or contract whose fingerprint has no row at its version, a definition whose
    version is not its newest row's, a recorded workflow that no longer ships, and a step id that
    a runnable version shipped and the definition dropped or moved to another contract
  - a released row with no date or no note, a note that is not one plain line, or a note the
    public hygiene check flags (scripts/check-public-hygiene.sh, with no allow list)
  - against the base: a released row edited or deleted, an unreleased row with no row left at its
    version, a new row marked `slip`, and a new `dormant` row for a definition this plugin can run
  - a HISTORY.md that is not what `history` writes

Last line of `check`: `REGISTRY: ok (<n> workflow rows, <m> contract rows)` or
`REGISTRY: <n> fault(s)`, after one `REGISTRY FAULT: <reason>` line per fault.
Exit codes: 0 ok, 1 refused or faults, 2 usage or unreadable input.
"""
import datetime
import glob
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

UNRELEASED = "unreleased"
REGISTRY = "workflows/registry.json"
HISTORY = "workflows/HISTORY.md"
SCHEMA = "schemas/workflow-registry.schema.json"
README = ("Append-only. Rows are appended by scripts/workflow-registry.py record and named by the "
          "release's prepare step (scripts/workflow-registry.py stamp); never edit or delete a row "
          "by hand. workflows/HISTORY.md is generated from this file.")
SEMVER = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
ITEM_NUMBER = re.compile(r"\s*\(?\bI[0-9]{4,6}\b\)?")
NOTE_MAX = 400
STEP_LIST_MAX = 12


class Refused(Exception):
    pass


def usage(message):
    print("workflow-registry: %s (see --help)" % message, file=sys.stderr)
    sys.exit(2)


def semver(text):
    match = SEMVER.match(text or "")
    return tuple(int(p) for p in match.groups()) if match else None


def release_order(version):
    """Sort key for a row's pluginVersion: released versions in order, `unreleased` last."""
    return (1, ()) if version == UNRELEASED else (0, semver(version) or ())


class Plugin:
    def __init__(self, root):
        self.root = os.path.abspath(root)
        spec = importlib.util.spec_from_file_location(
            "workflow_report", os.path.join(self.root, "skills/build-item/scripts/workflow_report.py"))
        self.report = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.report)

    def path(self, relative):
        return os.path.join(self.root, relative)

    def load_json(self, relative):
        with open(self.path(relative), encoding="utf-8") as handle:
            return json.load(handle)

    def definitions(self):
        """{workflow id: definition} for every built-in definition in workflows/."""
        out = {}
        for path in sorted(glob.glob(self.path("workflows/*.json"))):
            if os.path.basename(path) == os.path.basename(REGISTRY):
                continue
            with open(path, encoding="utf-8") as handle:
                definition = json.load(handle)
            out[definition["id"]] = definition
        return out

    def catalog(self):
        try:
            return self.load_json("schemas/step-contracts.json")["contracts"]
        except OSError:
            return {}

    def dormant_skills(self):
        """The built-in step skills the catalog lists as not switched on yet (`dormantSkills`)."""
        try:
            listed = self.load_json("schemas/step-contracts.json").get("dormantSkills", {})
        except OSError:
            return set()
        return set(listed) if isinstance(listed, dict) else set()

    def registry(self):
        return self.load_json(REGISTRY)

    def write_registry(self, registry):
        text = dump(registry)
        with open(self.path(REGISTRY), "w", encoding="utf-8", newline="") as handle:
            handle.write(text)

    def plugin_version(self):
        return self.load_json(".claude-plugin/plugin.json").get("version")

    def git(self, *args):
        done = subprocess.run(["git", "-C", self.root] + list(args), capture_output=True, text=True)
        return done.stdout if done.returncode == 0 else None

    # Fingerprints: the runner's canonical form, less the fields a release restamps.
    def workflow_entry(self, definition):
        body = {k: v for k, v in definition.items() if k != "minPluginVersion"}
        return {"version": definition["version"], "sha256": self.report.definition_hash(body),
                "minPluginVersion": definition.get("minPluginVersion", UNRELEASED),
                "steps": {s["id"]: s["contract"] for s in steps_of(definition)}}

    def contract_sha(self, entry):
        # since is the release that stamps it; judgement and ownContext say only where a step agent
        # runs the step (skills/run-workflow/references/step-agents.md), and configSkip only when the
        # runner answers it from the config the step would read: none changes the contract.
        return self.report.definition_hash({k: v for k, v in entry.items()
                                            if k not in ("since", "judgement", "ownContext", "configSkip")})

    def runnable(self, definition, catalog):
        """True when this plugin can run the definition: every contract is in the catalog and
        every built-in step skill exists and is switched on (the catalog's `dormantSkills` lists
        the ones that ship but are not). A definition that is not is dormant."""
        dormant = self.dormant_skills()
        for step in steps_of(definition):
            if step["contract"] not in catalog:
                return False
            run = step.get("run", {})
            if run.get("source") == "builtin" and (
                    run.get("ref") in dormant or not os.path.isfile(self.path("skills/%s/SKILL.md" % run.get("ref")))):
                return False
        return True


def steps_of(definition):
    return [s for p in definition.get("phases", []) for s in p.get("steps", [])]


def split_contract(key):
    name, _, major = key.rpartition("@")
    return name, int(major)


def dump(registry):
    ordered = {"_readme": registry.get("_readme", README), "schema": registry.get("schema", 1),
               "workflows": {k: registry["workflows"][k] for k in sorted(registry.get("workflows", {}))},
               "contracts": {k: registry["contracts"][k] for k in sorted(registry.get("contracts", {}))}}
    return json.dumps(ordered, indent=2, ensure_ascii=False) + "\n"


def workflow_row(entry, dormant):
    row = {"version": entry["version"], "pluginVersion": UNRELEASED, "releasedAt": None,
           "sha256": entry["sha256"], "minPluginVersion": entry["minPluginVersion"],
           "steps": dict(sorted(entry["steps"].items())), "note": ""}
    if dormant:
        row["dormant"] = True
    return row


def shipped_steps(rows):
    """Every step id a runnable (not dormant) version recorded, with its contract."""
    out = {}
    for row in rows:
        if not row.get("dormant"):
            out.update(row.get("steps", {}))
    return out


def step_drift(rows, steps):
    shipped = shipped_steps(rows)
    lost = sorted(i for i in shipped if i not in steps)
    moved = sorted(i for i in shipped if i in steps and steps[i] != shipped[i])
    return lost, moved


# ---------------------------------------------------------------------------------------- record
def record(plugin):
    registry = plugin.registry()
    catalog = plugin.catalog()
    workflows = registry.setdefault("workflows", {})
    contracts = registry.setdefault("contracts", {})
    appended, updated = [], []
    for wid, definition in plugin.definitions().items():
        entry = plugin.workflow_entry(definition)
        dormant = not plugin.runnable(definition, catalog)
        rows = workflows.setdefault(wid, [])
        if any(r["version"] == entry["version"] and r["sha256"] == entry["sha256"] for r in rows) and not (
                not dormant and rows[-1]["version"] == entry["version"] and rows[-1].get("dormant")):
            # Recorded already, unless this tree can run what its newest row says shipped dormant:
            # switched on with its content unchanged, it is recorded again below as runnable, so its
            # step ids are permanent from then on.
            continue
        lost, moved = step_drift(rows, entry["steps"])
        if moved:
            raise Refused("%s: step %s changed contract; give the changed step a new id" % (wid, ", ".join(moved)))
        if lost:
            raise Refused("%s: step %s was shipped and is gone; step ids are permanent" % (wid, ", ".join(lost)))
        same = [r for r in rows if r["version"] == entry["version"]]
        last = rows[-1] if rows else None
        if same and last is same[-1] and last["pluginVersion"] == UNRELEASED:
            # Not released yet, so not history yet: the unreleased row follows the definition.
            last.update({"sha256": entry["sha256"], "minPluginVersion": entry["minPluginVersion"],
                         "steps": dict(sorted(entry["steps"].items()))})
            if dormant:
                last["dormant"] = True
            else:
                last.pop("dormant", None)
            updated.append("%s v%s" % (wid, entry["version"]))
            continue
        if same:
            # A version may be re-recorded only while every release that carried it shipped it
            # dormant (no runner for it), so no running plugin ever saw the earlier content. The new
            # row is dormant only when this tree cannot run it either; a runnable re-record is the
            # first row at that version a plugin can run, and its step ids are permanent from then on.
            if all(r.get("dormant") for r in same) and last is same[-1]:
                rows.append(workflow_row(entry, dormant))
                appended.append("%s v%s (%s)" % (wid, entry["version"], "dormant" if dormant
                                                 else "re-recorded over a version that shipped dormant"))
                continue
            raise Refused("%s changed but its version did not; bump it first" % wid)
        expected = last["version"] + 1 if last else 1
        if entry["version"] != expected:
            raise Refused("%s is version %s but the next version is %s" % (wid, entry["version"], expected))
        rows.append(workflow_row(entry, dormant))
        appended.append("%s v%s" % (wid, entry["version"]))
    for key, body in catalog.items():
        name, major = split_contract(key)
        sha = plugin.contract_sha(body)
        rows = contracts.setdefault(name, [])
        if any(r["major"] == major and r["sha256"] == sha for r in rows):
            continue
        same = [r for r in rows if r["major"] == major]
        if same and same[-1]["pluginVersion"] == UNRELEASED:
            same[-1]["sha256"] = sha
            updated.append(key)
            continue
        if not same and rows and major != max(r["major"] for r in rows) + 1:
            raise Refused("%s: the next major of %s is %s" % (key, name, max(r["major"] for r in rows) + 1))
        rows.append({"major": major, "pluginVersion": UNRELEASED, "releasedAt": None, "sha256": sha, "note": ""})
        rows.sort(key=lambda r: r["major"])
        appended.append(key)
    plugin.write_registry(registry)
    for line in appended:
        print("APPENDED %s" % line)
    for line in updated:
        print("UPDATED unreleased %s" % line)
    print("RECORD: %d appended, %d unreleased row(s) updated" % (len(appended), len(updated)))


# ----------------------------------------------------------------------------------------- schema
def schema_faults(node, schema, where="registry"):
    """A small JSON Schema reader: type, const, enum, pattern, minimum, minLength, maxLength,
    required, properties, additionalProperties, patternProperties, items, minItems."""
    faults = []
    kind = schema.get("type")
    kinds = kind if isinstance(kind, list) else [kind] if kind else []
    checks = {"object": lambda v: isinstance(v, dict), "array": lambda v: isinstance(v, list),
              "string": lambda v: isinstance(v, str), "null": lambda v: v is None,
              "boolean": lambda v: isinstance(v, bool),
              "integer": lambda v: isinstance(v, int) and not isinstance(v, bool)}
    if kinds and not any(checks[k](node) for k in kinds):
        return ["%s: expected %s" % (where, " or ".join(kinds))]
    if "const" in schema and node != schema["const"]:
        faults.append("%s: must be %r" % (where, schema["const"]))
    if "enum" in schema and node not in schema["enum"]:
        faults.append("%s: must be one of %s" % (where, schema["enum"]))
    if isinstance(node, str):
        if "pattern" in schema and not re.search(schema["pattern"], node):
            faults.append("%s: %r does not match %s" % (where, node, schema["pattern"]))
        if len(node) < schema.get("minLength", 0) or len(node) > schema.get("maxLength", len(node)):
            faults.append("%s: length %d is out of range" % (where, len(node)))
    if isinstance(node, int) and not isinstance(node, bool) and node < schema.get("minimum", node):
        faults.append("%s: below %s" % (where, schema["minimum"]))
    if isinstance(node, dict):
        for key in schema.get("required", []):
            if key not in node:
                faults.append("%s: missing %s" % (where, key))
        props, patterns = schema.get("properties", {}), schema.get("patternProperties", {})
        for key, value in node.items():
            sub = props.get(key)
            if sub is None:
                sub = next((s for p, s in patterns.items() if re.search(p, key)), None)
            if sub is None:
                if schema.get("additionalProperties", True) is False:
                    faults.append("%s: unexpected key %s" % (where, key))
                elif isinstance(schema.get("additionalProperties"), dict):
                    faults += schema_faults(value, schema["additionalProperties"], "%s.%s" % (where, key))
                continue
            faults += schema_faults(value, sub, "%s.%s" % (where, key))
    if isinstance(node, list):
        if len(node) < schema.get("minItems", 0):
            faults.append("%s: fewer than %d item(s)" % (where, schema["minItems"]))
        for i, value in enumerate(node):
            faults += schema_faults(value, schema.get("items", {}), "%s[%d]" % (where, i))
    return faults


# ------------------------------------------------------------------------------------------ check
def order_faults(registry, plugin_version):
    faults = []
    for wid, rows in registry["workflows"].items():
        seen = set()
        for i, row in enumerate(rows):
            tag = "%s v%s" % (wid, row["version"])
            twins = [r for r in rows[:i] if (r["version"], r["sha256"]) == (row["version"], row["sha256"])]
            # The one fingerprint recorded twice is a definition switched on unchanged: shipped
            # dormant, then recorded once more as runnable, from which release its step ids hold.
            if twins and (row.get("dormant") or not all(r.get("dormant") for r in twins)):
                faults.append("%s: the same fingerprint is recorded twice" % tag)
            seen.add((row["version"], row["sha256"]))
            if i == 0:
                if row["version"] != 1:
                    faults.append("%s: a workflow's first version is 1" % tag)
                continue
            prev = rows[i - 1]
            if row["version"] == prev["version"]:
                earlier = [r for r in rows[:i] if r["version"] == row["version"]]
                if row.get("slip"):
                    continue
                if all(r.get("dormant") for r in earlier):
                    continue
                faults.append("%s: its content changed at a version already recorded; bump the version "
                              "(a version may be re-recorded only while every earlier row at it is "
                              "dormant: no released plugin could run it)" % tag)
            elif row["version"] < prev["version"]:
                faults.append("%s: the version goes backwards (after v%s)" % (tag, prev["version"]))
            elif row["version"] != prev["version"] + 1:
                faults.append("%s: the version skips (after v%s)" % (tag, prev["version"]))
        faults += release_faults(tag_rows(wid, rows, " v%s", "version"), plugin_version)
    for name, rows in registry["contracts"].items():
        seen = set()
        for i, row in enumerate(rows):
            tag = "%s@%s" % (name, row["major"])
            if (row["major"], row["sha256"]) in seen:
                faults.append("%s: the same fingerprint is recorded twice" % tag)
            seen.add((row["major"], row["sha256"]))
            if i and row["major"] < rows[i - 1]["major"]:
                faults.append("%s: the major goes backwards" % tag)
            elif i and row["major"] > rows[i - 1]["major"] + 1:
                faults.append("%s: the major skips" % tag)
        faults += release_faults(tag_rows(name, rows, "@%s", "major"), plugin_version)
    return faults


def tag_rows(name, rows, fmt, field):
    return [(name + fmt % row[field], row) for row in rows]


def release_faults(tagged, plugin_version):
    faults, released_after_unreleased = [], False
    previous = None
    for tag, row in tagged:
        version = row["pluginVersion"]
        if version == UNRELEASED:
            if row["releasedAt"] is not None:
                faults.append("%s: an unreleased row carries no date until its release names it" % tag)
            if row.get("slip"):
                faults.append("%s: only a historical row can be a slip" % tag)
            released_after_unreleased = True
        else:
            if released_after_unreleased:
                faults.append("%s: a released row follows an unreleased one" % tag)
            if not row["releasedAt"]:
                faults.append("%s: a released row needs its date" % tag)
            if not row["note"].strip():
                faults.append("%s: a released row needs its note" % tag)
            if semver(plugin_version) and semver(version) and semver(version) > semver(plugin_version):
                faults.append("%s: released in %s, after this plugin's %s" % (tag, version, plugin_version))
        if previous is not None and release_order(version) < release_order(previous):
            faults.append("%s: its plugin release %s comes before the previous row's %s" % (tag, version, previous))
        previous = version
    return faults


def current_faults(plugin, registry):
    """The definitions and the catalog on disk against the registry (the version ratchet)."""
    faults = []
    defs, catalog = plugin.definitions(), plugin.catalog()
    workflows = registry["workflows"]
    for wid, definition in defs.items():
        entry = plugin.workflow_entry(definition)
        rows = workflows.get(wid)
        if not rows:
            faults.append("%s: not recorded (run scripts/workflow-registry.py record)" % wid)
            continue
        if entry["version"] != rows[-1]["version"]:
            faults.append("%s: version %s is not its newest recorded version %s (run record)" % (wid, entry["version"], rows[-1]["version"]))
        elif not any(r["version"] == entry["version"] and r["sha256"] == entry["sha256"] for r in rows):
            faults.append("%s: changed since version %s was recorded; bump its version and run record" % (wid, entry["version"]))
        lost, moved = step_drift(rows, entry["steps"])
        if lost or moved:
            faults.append("%s: every step id a runnable version shipped stays, with its contract (gone: %s; moved: %s)"
                          % (wid, ", ".join(lost) or "none", ", ".join(moved) or "none"))
        can_run = plugin.runnable(definition, catalog)
        if not can_run and rows[-1]["version"] == entry["version"] and not rows[-1].get("dormant"):
            faults.append("%s: this plugin cannot run it, so its newest row must be marked dormant" % wid)
        if (can_run and rows[-1].get("dormant") and rows[-1]["pluginVersion"] == UNRELEASED
                and rows[-1]["sha256"] == entry["sha256"]):
            faults.append("%s: this plugin can run it, so its unreleased row must not be marked dormant (run record)" % wid)
        elif can_run and rows[-1].get("dormant") and rows[-1]["version"] == entry["version"]:
            faults.append("%s: this plugin can run it, but its newest row says it shipped dormant; record it as runnable (run record)" % wid)
    for wid in sorted(set(workflows) - set(defs)):
        faults.append("recorded workflow %s no longer ships" % wid)
    for key, body in catalog.items():
        name, major = split_contract(key)
        sha = plugin.contract_sha(body)
        rows = [r for r in registry["contracts"].get(name, []) if r["major"] == major]
        if not any(r["sha256"] == sha for r in rows):
            faults.append("%s: not recorded at this content (run scripts/workflow-registry.py record)" % key)
        # The catalog's `since` and the registry say one thing: a contract that is new in this
        # release is written `unreleased` in both, and the release's stamp names the version in both.
        first = rows[0]["pluginVersion"] if rows else None
        since = body.get("since") if isinstance(body, dict) else None
        if first == UNRELEASED and since != UNRELEASED:
            faults.append("%s: new in this release, so the catalog writes it \"since\": \"unreleased\" (the release's stamp names the version)" % key)
        elif first not in (None, UNRELEASED) and since is not None and since != first:
            faults.append("%s: the catalog says since %s, but its first row was released in %s" % (key, since, first))
    return faults


def note_faults(plugin, registry):
    faults, lines = [], []
    for kind, groups in (("workflow", registry["workflows"]), ("contract", registry["contracts"])):
        for name, rows in groups.items():
            for row in rows:
                note = row.get("note", "")
                tag = "%s %s %s" % (kind, name, row.get("version", row.get("major")))
                if "\n" in note or "\r" in note or note != note.strip():
                    faults.append("%s: a note is one plain line" % tag)
                if len(note) > NOTE_MAX:
                    faults.append("%s: a note is at most %d characters" % (tag, NOTE_MAX))
                lines.append(note.replace("\n", " "))
    hygiene = plugin.path("scripts/check-public-hygiene.sh")
    if not os.path.isfile(hygiene):
        return faults + ["scripts/check-public-hygiene.sh is missing, so the notes cannot be checked"]
    work = tempfile.mkdtemp(prefix="registry-notes-")
    try:
        os.makedirs(os.path.join(work, "notes"))
        with open(os.path.join(work, "notes", "notes.txt"), "w", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")
        allow = os.path.join(work, "empty.allow")
        open(allow, "w").close()
        done = subprocess.run(["bash", hygiene, "--tree", os.path.join(work, "notes"), "--allow", allow],
                              capture_output=True, text=True)
        if done.returncode != 0:
            for line in (done.stdout + done.stderr).splitlines():
                if line.startswith("HYGIENE: "):
                    faults.append("a note is not fit to publish: %s" % line[len("HYGIENE: "):])
            if not any(f.startswith("a note is not fit") for f in faults):
                faults.append("the hygiene check could not read the notes: %s" % (done.stdout + done.stderr).strip()[:200])
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return faults


def resolve_base(plugin, explicit):
    """(commit, how) of what this branch started from, or (None, why) when there is none."""
    if explicit == "none":
        return None, "the base comparison was switched off (--base none)"
    if explicit:
        commit = (plugin.git("rev-parse", "--verify", "-q", explicit + "^{commit}") or "").strip()
        if not commit:
            raise Refused("unknown base ref %s (fetch it first)" % explicit)
        return commit, explicit
    found = []
    for ref in ("origin/train/release", "origin/develop"):
        if plugin.git("rev-parse", "--verify", "-q", ref + "^{commit}"):
            merge_base = (plugin.git("merge-base", ref, "HEAD") or "").strip()
            if merge_base:
                found.append((merge_base, "merge base with %s" % ref))
    if found:
        best = found[0]
        for candidate in found[1:]:
            ancestor = subprocess.run(["git", "-C", plugin.root, "merge-base", "--is-ancestor", best[0], candidate[0]],
                                      capture_output=True).returncode == 0
            if ancestor:
                best = candidate
        return best
    for ref in ("origin/main", "origin/master"):
        if plugin.git("rev-parse", "--verify", "-q", ref + "^{commit}"):
            merge_base = (plugin.git("merge-base", ref, "HEAD") or "").strip()
            if merge_base:
                return merge_base, "merge base with %s" % ref
    return None, "no base branch found"


def base_faults(plugin, registry, base_registry):
    faults = []
    defs, catalog = plugin.definitions(), plugin.catalog()
    for kind, field in (("workflows", "version"), ("contracts", "major")):
        for name, base_rows in base_registry.get(kind, {}).items():
            head_rows = registry[kind].get(name, [])
            for row in base_rows:
                tag = "%s %s %s" % (kind[:-1], name, row[field])
                if row["pluginVersion"] == UNRELEASED:
                    if not any(r[field] == row[field] for r in head_rows):
                        faults.append("%s: an unreleased row was deleted" % tag)
                    continue
                match = [r for r in head_rows if r[field] == row[field] and r["sha256"] == row["sha256"]]
                if not match:
                    faults.append("%s: a released row was deleted or its fingerprint edited" % tag)
                elif row not in match:  # a definition switched on unchanged has two rows of one fingerprint
                    faults.append("%s: a released row was edited" % tag)
        for name, head_rows in registry[kind].items():
            base_rows = base_registry.get(kind, {}).get(name, [])
            known = {(r[field], r["sha256"]) for r in base_rows}
            for row in head_rows:
                if (row[field], row["sha256"]) in known or any(
                        r[field] == row[field] and r["pluginVersion"] == UNRELEASED for r in base_rows):
                    continue
                tag = "%s %s %s" % (kind[:-1], name, row[field])
                if row.get("slip"):
                    faults.append("%s: a new row cannot be marked slip; bump the version instead" % tag)
                if kind == "workflows" and row.get("dormant"):
                    definition = defs.get(name)
                    if definition is not None and plugin.runnable(definition, catalog):
                        faults.append("%s: marked dormant, but this plugin can run it; record it unmarked" % tag)
    return faults


def check(plugin, base):
    faults = []
    try:
        registry = plugin.registry()
    except (OSError, ValueError) as error:
        print("REGISTRY FAULT: %s cannot be read: %s" % (REGISTRY, error))
        print("REGISTRY: 1 fault(s)")
        return 1
    try:
        schema = plugin.load_json(SCHEMA)
    except (OSError, ValueError) as error:
        print("REGISTRY FAULT: %s cannot be read: %s" % (SCHEMA, error))
        print("REGISTRY: 1 fault(s)")
        return 1
    faults += schema_faults(registry, schema)
    if not faults:
        faults += order_faults(registry, plugin.plugin_version())
        faults += current_faults(plugin, registry)
        faults += note_faults(plugin, registry)
        commit, how = resolve_base(plugin, base)
        if commit:
            text = plugin.git("show", "%s:./%s" % (commit, REGISTRY))
            if text is None:
                print("base: %s %s holds no registry yet; nothing to compare" % (how, commit[:10]))
            else:
                print("base: %s %s" % (how, commit[:10]))
                try:
                    faults += base_faults(plugin, registry, json.loads(text))
                except (ValueError, KeyError, TypeError) as error:
                    faults.append("the base's registry cannot be read: %s" % error)
        else:
            print("base: %s; nothing to compare" % how)
        try:
            with open(plugin.path(HISTORY), encoding="utf-8") as handle:
                page = handle.read()
        except OSError:
            page = None
        if page != history(plugin, registry):
            faults.append("%s is stale; run scripts/workflow-registry.py history --write" % HISTORY)
    for fault in faults:
        print("REGISTRY FAULT: %s" % fault)
    if faults:
        print("REGISTRY: %d fault(s)" % len(faults))
        return 1
    print("REGISTRY: ok (%d workflow rows, %d contract rows)" % (
        sum(len(r) for r in registry["workflows"].values()), sum(len(r) for r in registry["contracts"].values())))
    return 0


# ------------------------------------------------------------------------------------------ stamp
def central_today():
    try:
        from zoneinfo import ZoneInfo
        return datetime.datetime.now(ZoneInfo("America/Chicago")).date().isoformat()
    except Exception:  # no time zone data: CST is six hours behind UTC
        return (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=6)).date().isoformat()


def changelog_bullets(text, version):
    """The top-level bullets of one version's CHANGELOG section, each as one line, Cost left out."""
    lines = text.split("\n")
    start = next((i for i, line in enumerate(lines) if re.match(r"^## \[%s\]" % re.escape(version), line)), None)
    if start is None:
        return []
    bullets, heading = [], ""
    for line in lines[start + 1:]:
        if line.startswith("## ["):
            break
        if line.startswith("### "):
            heading = line[4:].strip().lower()
            continue
        if heading == "cost":
            continue
        if line.startswith("- "):
            bullets.append(line[2:].strip())
        elif bullets and line.startswith("  ") and not line.strip().startswith("- "):
            bullets[-1] += " " + line.strip()
    return bullets


def headline(bullet):
    match = re.match(r"^\*\*(.+?)\*\*", bullet)
    text = match.group(1) if match else re.split(r"(?<=[.!?])\s", bullet, maxsplit=1)[0]
    text = ITEM_NUMBER.sub("", text).strip()
    if text and text[-1] not in ".!?":
        text += "."
    return text


def note_for(bullets, words, fallback):
    """The headline of the first bullet that names the row by one of `words` (forms specific
    enough not to match an unrelated entry), else the neutral `fallback`: a guess frozen into a row
    that may never be edited would be worse than a plain one."""
    for bullet in bullets:
        lowered = bullet.lower()
        if any(re.search(r"(?<![\w-])%s(?![\w-])" % re.escape(w.lower()), lowered) for w in words if w):
            return headline(bullet)
    return fallback


def distinctive(name):
    """A bare id or contract name is matched on its own only when it is hyphenated (release-post-deploy,
    risk-check); a plain word such as build, plan or claim turns up in unrelated entries."""
    return name if "-" in name else None


def stamp(plugin, version, date, changelog):
    registry = plugin.registry()
    try:
        with open(changelog or plugin.path("CHANGELOG.md"), encoding="utf-8") as handle:
            bullets = changelog_bullets(handle.read(), version)
    except OSError:
        bullets = []
    defs = plugin.definitions()
    count = 0
    for wid, rows in registry["workflows"].items():
        name = defs.get(wid, {}).get("name", wid)
        for i, row in enumerate(rows):
            if row["pluginVersion"] != UNRELEASED:
                continue
            row.update({"pluginVersion": version, "releasedAt": date})
            if row["minPluginVersion"] == UNRELEASED:
                row["minPluginVersion"] = version
            if not row["note"].strip():
                revised = any(r["version"] == row["version"] for r in rows[:i])
                row["note"] = note_for(bullets, ["workflows/%s.json" % wid, "%s workflow" % name, "`%s`" % wid,
                                                 distinctive(wid)],
                                       "Revised in %s." % version if revised
                                       else "Version %s, first shipped in %s." % (row["version"], version))
            count += 1
    for cname, rows in registry["contracts"].items():
        for i, row in enumerate(rows):
            if row["pluginVersion"] != UNRELEASED:
                continue
            row.update({"pluginVersion": version, "releasedAt": date})
            if not row["note"].strip():
                revision = any(r["major"] == row["major"] for r in rows[:i])
                row["note"] = note_for(bullets, ["%s@%s" % (cname, row["major"]), "`%s`" % cname, distinctive(cname)],
                                       "%s in %s." % ("Revised" if revision else "Published", version))
            count += 1
    plugin.write_registry(registry)
    write_history(plugin, registry)
    print("REGISTRY STAMP: %s" % ("%d row(s) set to %s (%s)" % (count, version, date) if count else "nothing to stamp"))
    return 0


def verify_stamp(plugin, version):
    registry = plugin.registry()
    faults = []
    for kind, field in (("workflows", "version"), ("contracts", "major")):
        for name, rows in registry[kind].items():
            for row in rows:
                tag = "%s %s %s" % (kind[:-1], name, row[field])
                if row["pluginVersion"] == UNRELEASED:
                    faults.append("%s is still unreleased" % tag)
                elif row["pluginVersion"] == version and not (row["releasedAt"] and row["note"].strip()):
                    faults.append("%s of %s has no date or no note" % (tag, version))
    try:
        with open(plugin.path(HISTORY), encoding="utf-8") as handle:
            current = handle.read() == history(plugin, registry)
    except OSError:
        current = False
    if not current:
        faults.append("%s is stale" % HISTORY)
    for fault in faults:
        print("REGISTRY FAULT: %s" % fault)
    print("REGISTRY STAMP: %s" % ("verified %s" % version if not faults else "%d fault(s)" % len(faults)))
    return 1 if faults else 0


# ---------------------------------------------------------------------------------------- history
def anchor(heading):
    """GitHub's heading anchor: lower case, punctuation dropped, spaces to hyphens."""
    text = re.sub(r"[^\w\- ]", "", heading.lower().replace("`", ""))
    return text.replace(" ", "-")


def cell(text):
    return text.replace("|", "\\|").replace("\n", " ")


def ids(names):
    names = sorted(names)
    shown = ", ".join("`%s`" % n for n in names[:STEP_LIST_MAX])
    return shown + (" and %d more" % (len(names) - STEP_LIST_MAX) if len(names) > STEP_LIST_MAX else "")


def steps_changed(prev, row):
    if prev is None:
        return "first version: %d step%s" % (len(row["steps"]), "" if len(row["steps"]) == 1 else "s")
    was, now = prev["steps"], row["steps"]
    parts = []
    added = [i for i in now if i not in was]
    removed = [i for i in was if i not in now]
    moved = sorted(i for i in now if i in was and now[i] != was[i])
    if added:
        parts.append("added %s" % ids(added))
    if removed:
        parts.append("removed %s" % ids(removed))
    if moved:
        parts.append("contract changed: %s" % ", ".join("`%s` (%s → %s)" % (i, was[i], now[i]) for i in moved[:STEP_LIST_MAX])
                     + (" and %d more" % (len(moved) - STEP_LIST_MAX) if len(moved) > STEP_LIST_MAX else ""))
    return "; ".join(parts) or "none"


def note_cell(row):
    note = row["note"] or "(no note yet)"
    if row.get("dormant"):
        note += " *Shipped unused: no released plugin could run it.*"
    return cell(note)


def release_cell(row):
    return "unreleased" if row["pluginVersion"] == UNRELEASED else row["pluginVersion"]


def history(plugin, registry):
    defs = plugin.definitions()
    titles = {wid: "%s (`%s`)" % (defs.get(wid, {}).get("name", wid), wid) for wid in registry["workflows"]}
    by_release = {}
    for name, rows in registry["contracts"].items():
        for i, row in enumerate(rows):
            earlier = [r for r in rows[:i] if r["major"] == row["major"]]
            by_release.setdefault((row["pluginVersion"], row["releasedAt"]), []).append((name, row, bool(earlier)))
    releases = sorted(by_release, key=lambda k: release_order(k[0]), reverse=True)

    def release_title(key):
        return "Unreleased" if key[0] == UNRELEASED else "%s, %s" % key

    out = ["# Workflow and step contract history", "",
           "Generated from [`registry.json`](registry.json) by `scripts/workflow-registry.py history --write`,",
           "which the release's prepare step runs; never edit this page by hand. Every version of every",
           "built-in workflow and every revision of every step contract is listed, newest first. A",
           "version marked *shipped unused* was published as data before any released plugin could run it.",
           "", "## Contents", ""]
    for wid in sorted(registry["workflows"]):
        rows = registry["workflows"][wid]
        out.append("- [%s](#%s): version %s" % (titles[wid], anchor(titles[wid]), rows[-1]["version"]))
    out.append("- [Step contracts](#step-contracts): %d contracts" % len(registry["contracts"]))
    for key in releases:
        out.append("  - [%s](#%s)" % (release_title(key), anchor(release_title(key))))
    for wid in sorted(registry["workflows"]):
        rows = registry["workflows"][wid]
        newest = rows[-1]
        out += ["", "## %s" % titles[wid], "",
                "Current version **%s**, minimum plugin version **%s**, %d row(s) recorded." % (
                    newest["version"], newest["minPluginVersion"], len(rows)), "",
                "| Version | Plugin release | Date | Steps changed | Note |",
                "| --- | --- | --- | --- | --- |"]
        for i in range(len(rows) - 1, -1, -1):
            row = rows[i]
            out.append("| %s | %s | %s | %s | %s |" % (
                row["version"], release_cell(row), row["releasedAt"] or "-",
                cell(steps_changed(rows[i - 1] if i else None, row)), note_cell(row)))
    out += ["", "## Step contracts", "",
            "Each contract is `name@major`. A major version only grows by additions; a *revision* is a",
            "later published content of the same major, and a *slip* is one that changed more than that",
            "without a new major.", ""]
    for key in releases:
        out += ["### %s" % release_title(key), "", "| Contract | Note |", "| --- | --- |"]
        for name, row, revision in sorted(by_release[key], key=lambda t: (t[0], t[1]["major"])):
            label = "`%s@%s`" % (name, row["major"])
            if row.get("slip"):
                label += " (slip)"
            elif revision:
                label += " (revision)"
            out.append("| %s | %s |" % (label, cell(row["note"] or "(no note yet)")))
        out.append("")
    return "\n".join(out).rstrip("\n") + "\n"


def write_history(plugin, registry):
    page = history(plugin, registry)
    with open(plugin.path(HISTORY), "w", encoding="utf-8", newline="") as handle:
        handle.write(page)


# ------------------------------------------------------------------------------------------- main
def main(argv):
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    args, rest = [], list(argv)
    base = date = changelog = None
    flag = None
    while rest:
        arg = rest.pop(0)
        if arg in ("-h", "--help"):
            print(__doc__.strip())
            return 0
        if arg in ("--root", "--base", "--date", "--changelog"):
            if not rest:
                usage("%s needs a value" % arg)
            value = rest.pop(0)
            if arg == "--root":
                root = value
            elif arg == "--base":
                base = value
            elif arg == "--date":
                date = value
            else:
                changelog = value
        elif arg in ("--write", "--check"):
            flag = arg
        elif arg.startswith("-"):
            usage("unknown argument: %s" % arg)
        else:
            args.append(arg)
    if not args:
        usage("name a command: record, check, stamp, verify-stamp or history")
    command, operands = args[0], args[1:]
    if not os.path.isfile(os.path.join(root, ".claude-plugin", "plugin.json")):
        usage("no plugin at %s" % root)
    plugin = Plugin(root)
    try:
        if command == "record" and not operands:
            record(plugin)
            return 0
        if command == "check" and not operands:
            return check(plugin, base)
        if command in ("stamp", "verify-stamp") and len(operands) == 1:
            if not semver(operands[0]):
                usage("not a version: %s" % operands[0])
            if command == "verify-stamp":
                return verify_stamp(plugin, operands[0])
            if date is not None and not DATE.match(date):
                usage("--date takes YYYY-MM-DD")
            return stamp(plugin, operands[0], date or central_today(), changelog)
        if command == "history" and not operands:
            registry = plugin.registry()
            if flag == "--write":
                write_history(plugin, registry)
                print("HISTORY: written")
                return 0
            page = history(plugin, registry)
            if flag == "--check":
                try:
                    with open(plugin.path(HISTORY), encoding="utf-8") as handle:
                        current = handle.read() == page
                except OSError:
                    current = False
                print("HISTORY: %s" % ("current" if current else "stale (run history --write)"))
                return 0 if current else 1
            sys.stdout.write(page)
            return 0
    except Refused as refused:
        print("workflow-registry: %s" % refused, file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError) as error:
        print("workflow-registry: cannot read the registry or a definition: %s" % error, file=sys.stderr)
        return 2
    usage("unknown command or wrong operands: %s" % " ".join(args))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
