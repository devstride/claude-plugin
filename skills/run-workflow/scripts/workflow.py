#!/usr/bin/env python3
"""The step runner: it walks a workflow definition one step at a time and remembers where it is.

It decides and records; it never acts. It has no network and no tracker access, runs no skill,
and reads a repository only through three read-only git commands (`rev-parse`, `diff`,
`patch-id`) plus the remote lookup of the reporting helper. A person, another agent or the
plugin's own loop asks it what is next, runs that step, hands the step's answer back, and gets
the same answers every time, also after a restart or a cleared conversation. The rules are in
`skills/run-workflow/references/workflow-runner.md`; the step contracts are in
`schemas/step-contracts.json`.

  python3 -B workflow.py <command>     one JSON object on stdin, one JSON object on stdout

  start   {"definition" | "definitionFile", "context", "session"?, "replace"?}
  next    {"runId"?, "item"?}
  done    {"runId"?, "item"?, "stepId", "attempt", "output"}
  status  {"runId"?, "item"?, "includeDefinition"?}
  resume  {"runId"?, "item"?, "answer"?, "session"?}

Every request may carry `session` (else the agent's own session id, else `manual-<pid of the
calling shell>`) and `now` (an ISO time, for tests). `start`, `next`, `done` and `resume` answer
with the next action: `run` (the step to run, the skill, its payload and argument, the heartbeat
to send), `finished` or `stopped`. Every answer carries `reports`: ready argument objects for the
tracker's step-recording tool. Sending them is the caller's job and may fail without consequence.

Exit 0 with an answer; 2 with exactly one `workflow: <code>: <message>` line on stderr and nothing
on stdout for a refusal; 1 (also one `workflow:` line) for anything else. Never a traceback.

State: one file per session and item under ${XDG_CACHE_HOME:-~/.cache}/devstride-plugin/workflows,
owner-only, written atomically, pruned after seven days.
"""
import hashlib
import importlib.util
import json
import os
import re
import secrets
import stat
import subprocess
import sys
import time
from datetime import datetime, timezone

sys.dont_write_bytecode = True  # loading the helpers below must never write into an installed plugin

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
CATALOG_PATH = os.path.join(PLUGIN_ROOT, "schemas", "step-contracts.json")
COMMANDS = ("start", "next", "done", "status", "resume")

KEEP_SECONDS = 7 * 24 * 3600
STATE_MAX_BYTES = 1048576
REQUEST_MAX_BYTES = 4 * 1048576
DEFINITION_FILE_MAX_BYTES = 256 * 1024
RESULT_MAX_BYTES = 16 * 1024
ANSWER_MAX_CHARS = 8000
AUTO_REDO_LIMIT = 5
GIT_READ_ONLY = ("rev-parse", "diff", "patch-id")
GIT_TIMEOUT, GIT_DIFF_TIMEOUT = 30, 120

SESSION = re.compile(r"^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$")
RUN_ID = re.compile(r"^[0-9a-f]{32}$")
SLUG = re.compile(r"^[a-z][a-z0-9-]{0,63}$")
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
CONTRACT = re.compile(r"^([a-z][a-z0-9-]*)@([0-9]+)$")
COMMIT_ID = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
GIT_REF = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/@^~-]{0,199}$")
CONTROL = re.compile(r"[\x00-\x1f\x7f]")
FENCE_OPEN = re.compile(r"^\s*```json\s*$")
TEMPLATE_FIELD = re.compile(r"\{([A-Za-z][A-Za-z0-9]*)\}")
PAYLOAD_PATH = re.compile(
    r"^(?:context(?:\.[A-Za-z][A-Za-z0-9]*)+"
    r"|result:[a-z][a-z0-9-]*@[0-9]+(?:\.[A-Za-z][A-Za-z0-9]*)*"
    r"|step\.(?:answer|proof|head))\??$")

# The catalog's vocabulary (schemas/step-contracts.json).
ENTRY_FIELDS = ("summary", "builtinSkill", "payload", "argument", "verdict", "result", "proof",
                "requires", "claimPhase", "shipIntentStage")
CLASSES = ("continue", "skipped", "redo:self", "stop", "ask")
END_CLASS = re.compile(r"^end:([a-z][a-z-]*)$")
DETAILS = ("none", "optional", "required")
BINDINGS = ("none", "tree", "patch")
BINDING_FIELDS = {"none": (), "tree": ("tree",), "patch": ("base", "patchId")}
TYPE_NAMES = ("string", "number", "count", "boolean", "array", "object", "null")
STAGES = ("building", "reviewing", "verifying", "landing")
RESERVED_PAYLOAD_KEYS = ("step", "contract")
CLAIM_PHASE_MAX = 64

DETAIL_NAME = re.compile(r"^[a-z][a-z-]{0,31}$")

# The definition's vocabulary and limits (schemas/workflow.schema.json).
WORKFLOW_ID = re.compile(r"^[a-z][a-z0-9-]{0,99}$")
STARTS_WHEN = ("item-picked-up", "children-complete", "on-demand")
ENDS_BY = ("ship", "hand-up", None)
APPLIES_TO = ("workTypes", "tags", "repositories")
KINDS = ("step", "gate")
RUN_SOURCES = ("builtin", "library", "repo", "off")
WHEN_MODES = ("always", "condition", "manual")
CONDITIONS = ("review-path:fast", "review-path:pull-request", None)
ON_FAIL = ("stop", "continue")
NAME_MAX, SUMMARY_MAX = 200, 500
MAX_PHASES, MAX_PHASE_STEPS, MAX_STEPS = 12, 40, 100

# How a run's end, or the kind of stop it is waiting at, is named to the tracker. The one table.
RUN_OUTCOME = {
    "completed": "completed",
    "held": "interrupted",
    "interrupted": "interrupted",
    "needs-person": "interrupted",
    "failed": "failed",
    "no-verdict": "failed",
    "proof": "failed",
    "attempts-exhausted": "failed",
}

# What looks like a credential: shapes, not words. An evidence line that matches is dropped whole,
# a verdict detail or a refusal message is replaced, and a definition that holds one is refused.
# A value is one unbroken run of at least 7 characters that is not all digits, so `token: 911`,
# `has_token=true` and `Rotate the token: weekly` are ordinary text and `password: hunter2` is not.
# Each rule may start only at the beginning of a run of the characters it reads (a lookbehind or a
# fixed word), and reads that run once, so the scan stays linear in the text's length.
CREDENTIAL_WORD = re.compile(r"secret|token|passw(?:or)?d|api[_-]?key|access_?key|private_?key", re.I)
CREDENTIAL_VALUE = r"(?=[^\s\"']{7})(?![0-9]+(?:[\s\"']|$))"
SECRET = re.compile(
    r"CLAIM_HOLDER|-----BEGIN"
    r"|\bauthorization[\"']?\s*[:=]\s*[\"']?(?:[A-Za-z][A-Za-z0-9_-]{0,31}\s+)?"   # an Authorization header, any scheme,
    r"(?![A-Za-z0-9._~+/=-]*/[A-Za-z0-9_.-]*\.[A-Za-z]{1,5}(?![A-Za-z0-9._~+/=-]))[A-Za-z0-9._~+/=-]{16}"  # not a file path
    r"|\b(?:bearer|basic)\s+[A-Za-z0-9._~+/=-]{16}"                     # a bearer or basic credential
    r"|\bx-api-key[\"']?\s*:\s*[\"']?[^\s\"']"                           # an API key header
    r"|(?<![a-z0-9+.-])[a-z][a-z0-9+.-]*://[^\s/@:]*:[^\s/@]+@"              # a URL with a user and password
    r"|\b(?:sk_live_|sk_test_|rk_live_|sk-ant-|ghp_|gho_|ghu_|ghs_|ghr_|github_pat_|glpat-|xox[abpors]-|whsec_)[A-Za-z0-9_-]{4}"
    r"|\bnpm_[A-Za-z0-9]{16}|\bAIza[A-Za-z0-9_-]{16}|\bSG\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8}"
    r"|\bsk-[A-Za-z0-9_-]{16}|(?-i:\b(?:AKIA|ASIA)[0-9A-Z]{12})"
    r"|(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\."            # a JSON web token
    r"|(?:--(?:password|token)|\bclient_secret)(?:\s+|=)[\"']?" + CREDENTIAL_VALUE,   # a flag and its value
    re.I)
# A key assigned a value: the whole key is read once (a lookahead and a back-reference, so no
# backtracking into it), then its last dotted part must name a credential: db.password=… is one,
# password_reset.py: … is not.
ASSIGNED = re.compile(r"(?<![A-Za-z0-9_./\\-])(?=([A-Za-z0-9_.-]+))\1[\"']?\s*[:=]\s*[\"']?" + CREDENTIAL_VALUE)
KEY = re.compile(r"^[A-Za-z0-9_.-]+$")
CREDENTIAL_STRING = re.compile(r"^\s*(?![0-9]+\s*$)\S{7,}\s*$")


def credential_key(key):
    """True when a key's last dotted part names a credential."""
    return bool(KEY.match(key)) and bool(CREDENTIAL_WORD.search(key.rsplit(".", 1)[-1]))
WITHHELD = "[withheld]"
NOT_SHOWN = "the message names a value that looks like a credential, so it is not shown"

MISSING = object()
REPORT = None   # skills/build-item/scripts/workflow_report.py: hashing, normalizing, capping, report shape
CLAIMS = None   # skills/build-item/scripts/claim_record.py: the session id and the plugin version


class Refuse(Exception):
    """A request the runner will not act on: exit 2, one line, nothing changed."""

    def __init__(self, code, message):
        Exception.__init__(self, message)
        self.code = code


class GitFailed(Exception):
    """Git could not answer. A proof that cannot be checked is never treated as valid."""


def load_helpers():
    """Load the two shared helpers by file path; the runner keeps no second copy of their rules."""
    global REPORT, CLAIMS
    if REPORT is None:
        folder = os.path.join(os.path.dirname(os.path.dirname(HERE)), "build-item/scripts")  # the skill beside this one
        loaded = []
        for name in ("workflow_report", "claim_record"):
            spec = importlib.util.spec_from_file_location(name, os.path.join(folder, name + ".py"))
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            loaded.append(module)
        REPORT, CLAIMS = loaded


def run_git(cwd, *args, **options):
    """The only place a process is started. Read-only subcommands, each with a timeout."""
    if not args or args[0] not in GIT_READ_ONLY:
        raise GitFailed("git %s is not a command the runner runs" % (args[0] if args else ""))
    try:
        done = subprocess.run(["git", "-C", cwd] + list(args), input=options.get("stdin"),
                              capture_output=True, timeout=options.get("timeout", GIT_TIMEOUT))
    except (OSError, subprocess.SubprocessError) as error:
        raise GitFailed("git %s: %s" % (args[0], error.__class__.__name__))
    if done.returncode != 0:
        raise GitFailed("git %s failed" % args[0])
    return done.stdout


class World:
    """Everything outside the runner's own state: the environment, the clock, git and the user."""

    def __init__(self, env=None, git=run_git, uid=None, now=None):
        self.env = os.environ if env is None else env
        self.git = git
        self.uid = os.getuid() if uid is None else uid
        self._now = now

    def now(self):
        if self._now:
            return self._now
        moment = datetime.now(timezone.utc)
        return moment.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (moment.microsecond // 1000)

    def head(self, cwd):
        """The full commit id HEAD is on: read once, then every proof is checked against it."""
        head = self.git(cwd, "rev-parse", "--verify", "HEAD^{commit}").decode("utf-8", "replace").strip()
        if not COMMIT_ID.match(head):
            raise GitFailed("HEAD does not name a commit id")
        return head

    def tree(self, cwd, commit):
        return self.git(cwd, "rev-parse", commit + "^{tree}").decode("utf-8", "replace").strip()

    def patch_id(self, cwd, base, commit):
        """The verbatim patch id of everything on `commit` since it left `base`, or None for no
        patch. Every byte counts, white space too. The fixed flags override the settings for colour,
        prefixes, relative paths, submodules, context, hunk joining, renames and the diff algorithm,
        and no diff driver or text converter runs; `diff.suppressBlankEmpty` and `core.quotePath`
        are not covered, and fail closed: an id they change reads as stale and the step runs again."""
        if not isinstance(base, str) or not GIT_REF.match(base):
            raise GitFailed("the proof's base is not a usable git name")
        diff = self.git(cwd, "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-relative",
                        "--src-prefix=a/", "--dst-prefix=b/", "--ignore-submodules=none", "--unified=3",
                        "--no-renames", "--diff-algorithm=myers", "--inter-hunk-context=0", base + "..." + commit, "--",
                        timeout=GIT_DIFF_TIMEOUT)
        try:
            out = self.git(cwd, "patch-id", "--verbatim", stdin=diff).decode("utf-8", "replace").split()
        except GitFailed:
            raise GitFailed("git patch-id --verbatim failed; a git too old to support --verbatim cannot check a review")
        return out[0] if out else None

    def in_work_tree(self, cwd):
        try:
            return self.git(cwd, "rev-parse", "--is-inside-work-tree").strip() == b"true"
        except GitFailed:
            return False


# --- the catalog ------------------------------------------------------------------------------

def is_type(value, spec):
    """True when `value` is one of the `|`-separated type names in `spec`."""
    for name in spec.split("|"):
        if ((name == "null" and value is None)
                or (name == "string" and isinstance(value, str))
                or (name == "boolean" and isinstance(value, bool))
                or (name == "number" and isinstance(value, (int, float)) and not isinstance(value, bool))
                or (name == "count" and isinstance(value, int) and not isinstance(value, bool) and value >= 0)
                or (name == "array" and isinstance(value, list))
                or (name == "object" and isinstance(value, dict))):
            return True
    return False


def parse_path(path):
    """A payload path as (kind, contract, keys, optional). Kinds: context, result, step."""
    optional = path.endswith("?")
    body = path[:-1] if optional else path
    if body.startswith("result:"):
        contract, _, rest = body[len("result:"):].partition(".")
        return "result", contract, rest.split(".") if rest else [], optional
    kind, _, rest = body.partition(".")
    return kind, None, rest.split("."), optional


def _keys_and_types(block):
    return (isinstance(block.get("required"), list) and all(isinstance(k, str) for k in block["required"])
            and isinstance(block.get("types"), dict)
            and all(isinstance(k, str) and isinstance(t, str) and t and all(n in TYPE_NAMES for n in t.split("|"))
                    for k, t in block["types"].items())
            and all(k in block["types"] for k in block["required"]))


def _entry_shape(entry):
    """Why one catalog entry is not shaped as an entry, or None."""
    if not isinstance(entry, dict):
        return "an entry is an object"
    extra = sorted(k for k in entry if k not in ENTRY_FIELDS + ("satisfiedBy",))
    lacking = [k for k in ENTRY_FIELDS if k not in entry]
    if extra or lacking:
        return "fields: unknown %s, missing %s" % (extra, lacking)
    if not isinstance(entry["summary"], str) or not entry["summary"].strip():
        return "summary is one sentence"
    if entry["builtinSkill"] is not None and not (isinstance(entry["builtinSkill"], str) and SLUG.match(entry["builtinSkill"])):
        return "builtinSkill is a skill name or null"
    if not isinstance(entry["payload"], dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in entry["payload"].items()):
        return "payload maps names to paths"
    if entry["argument"] is not None and not isinstance(entry["argument"], str):
        return "argument is a template or null"
    verdict = entry["verdict"]
    if (not isinstance(verdict, dict) or not isinstance(verdict.get("label"), str) or not verdict["label"].strip()
            or ":" in verdict["label"] or not isinstance(verdict.get("values"), list) or not verdict["values"]):
        return "verdict needs a label and at least one value"
    for value in verdict["values"]:
        if (not isinstance(value, dict) or not isinstance(value.get("value"), str) or not value["value"].strip()
                or value.get("detail") not in DETAILS or not isinstance(value.get("class"), str)):
            return "a verdict value needs value, detail and class"
        if (value["detail"] == "none") != ("detailName" not in value) or (
                "detailName" in value and not (isinstance(value["detailName"], str) and DETAIL_NAME.match(value["detailName"]))):
            return "a verdict value that takes a detail names it (detailName, a lower-case word), and only such a value"
        if "proof" in value and not (isinstance(value["proof"], dict) and value["proof"]
                                     and all(isinstance(v, str) for v in value["proof"].values())):
            return "a verdict value's proof maps proof keys to the text each must be"
    if len(set(v["value"] for v in verdict["values"])) != len(verdict["values"]):
        return "a verdict value is listed twice"
    if not isinstance(entry["result"], dict) or not _keys_and_types(entry["result"]):
        return "result needs required keys, each with a type"
    proof = entry["proof"]
    if not isinstance(proof, dict) or proof.get("binding") not in BINDINGS:
        return "proof.binding is none, tree or patch"
    if ("required" in proof or "types" in proof) and not _keys_and_types(proof):
        return "proof needs required keys, each with a type"
    values = proof.get("values", {})
    if not isinstance(values, dict) or not all(
            key in proof.get("required", []) and proof["types"][key] == "string" and isinstance(allowed, list)
            and allowed and all(isinstance(v, str) for v in allowed) for key, allowed in values.items()):
        return "proof.values maps required text keys to the values each may take"
    if not isinstance(entry["requires"], list) or not all(isinstance(r, str) for r in entry["requires"]):
        return "requires is a list of contract names"
    if entry["claimPhase"] is not None and not isinstance(entry["claimPhase"], str):
        return "claimPhase is text or null"
    if entry["shipIntentStage"] is not None and entry["shipIntentStage"] not in STAGES:
        return "shipIntentStage is one of %s or null" % ", ".join(STAGES)
    if "satisfiedBy" in entry and not (isinstance(entry["satisfiedBy"], list) and all(isinstance(s, str) for s in entry["satisfiedBy"])):
        return "satisfiedBy is a list of contract names"
    return None


def requires_closure(contracts, name):
    """Every contract `name` requires, directly or through another requirement."""
    seen, queue = set(), list(contracts[name]["requires"])
    while queue:
        need = queue.pop()
        if need not in seen and need in contracts:
            seen.add(need)
            queue.extend(contracts[need]["requires"])
    return seen


def check_catalog(catalog):
    """Every structural fault in a contract catalog, as `<code>: <contract>: <reason>` lines.
    An empty list means the catalog is sound. The runner refuses to run on an unsound one."""
    faults = []

    def fault(code, name, reason):
        faults.append("%s: %s: %s" % (code, name, reason))

    if (not isinstance(catalog, dict) or catalog.get("schema") != 1 or isinstance(catalog.get("schema"), bool)
            or not isinstance(catalog.get("contracts"), dict) or not catalog["contracts"]):
        return ["shape: catalog: needs schema 1 and a contracts object"]
    contracts = catalog["contracts"]
    for name, entry in contracts.items():
        if not CONTRACT.match(name):
            fault("name", name, "a contract is named <name>@<major>")
        problem = _entry_shape(entry)
        if problem:
            fault("shape", name, problem)
    if faults:
        return faults
    order = list(contracts)
    for name, entry in contracts.items():
        for need in entry["requires"]:
            if need not in contracts:
                fault("requires-unknown", name, "requires %s, which the catalog does not hold" % need)
    if faults:
        return faults
    # Every contract some other one requires, with the contracts that may stand in for it.
    relied = set(given for entry in contracts.values() for need in entry["requires"]
                 for given in [need] + [s for s in contracts[need].get("satisfiedBy", []) if isinstance(s, str)])
    for name, entry in contracts.items():
        closure = requires_closure(contracts, name)
        if name in closure:
            fault("cycle", name, "requires itself through its requirements")
        proof = entry["proof"]
        for key in BINDING_FIELDS[proof["binding"]]:
            if key not in proof.get("required", []) or proof["types"][key] != "string":
                fault("proof-fields", name, "a %s binding needs the text proof key %s" % (proof["binding"], key))
        pinned = set(key for value in entry["verdict"]["values"] for key in value.get("proof", {}))
        for value in entry["verdict"]["values"]:
            for key, wanted in value.get("proof", {}).items():
                if wanted not in proof.get("values", {}).get(key, []):
                    fault("proof-values", name, "%s pins %s to a value proof.values does not list" % (value["value"], key))
            if value["class"] == "continue" and pinned - set(value.get("proof", {})):
                fault("proof-values", name, "%s does not pin %s, which another verdict pins" % (value["value"], ", ".join(sorted(pinned))))
        for value in entry["verdict"]["values"]:
            if value["class"] not in CLASSES and not END_CLASS.match(value["class"]):
                fault("class", name, "%s has the unknown class %s" % (value["value"], value["class"]))
            if value["class"] == "skipped" and name in relied:
                fault("required-skippable", name, "%s skips a step another contract requires" % value["value"])
        phase = entry["claimPhase"]
        if phase is not None and (not phase or len(phase) > CLAIM_PHASE_MAX or CONTROL.search(phase)):
            fault("claim-phase", name, "a claim phase is 1 to %d characters with no control character" % CLAIM_PHASE_MAX)
        for key, path in entry["payload"].items():
            if key in RESERVED_PAYLOAD_KEYS:
                fault("reserved-key", name, "the payload key %s is the runner's own" % key)
            if not PAYLOAD_PATH.match(path):
                fault("payload-path", name, "%s: %s is not a payload path" % (key, path))
                continue
            kind, contract, _, optional = parse_path(path)
            if kind == "step" and not optional:
                fault("payload-path", name, "%s: a step path is always optional" % key)
            if kind == "result":
                if contract not in contracts:
                    fault("payload-path", name, "%s reads %s, which the catalog does not hold" % (key, contract))
                elif contract not in closure and not (optional and order.index(contract) < order.index(name)):
                    fault("payload-order", name, "%s reads %s, which this contract does not require" % (key, contract))
        if entry["argument"] is not None:
            for field in TEMPLATE_FIELD.findall(entry["argument"]):
                if field not in entry["payload"]:
                    fault("argument-field", name, "the argument names {%s}, which is not a payload key" % field)
        satisfiers = entry.get("satisfiedBy", [])
        if len(set(satisfiers)) != len(satisfiers):
            fault("satisfied-duplicate", name, "satisfiedBy lists a contract twice")
        for satisfier in satisfiers:
            if satisfier == name:
                fault("satisfied-self", name, "a contract never satisfies itself")
            elif satisfier not in contracts:
                fault("satisfied-unknown", name, "satisfiedBy names %s, which the catalog does not hold" % satisfier)
            else:
                for reader, other in contracts.items():
                    for path in other["payload"].values():
                        if not PAYLOAD_PATH.match(path):
                            continue
                        kind, contract, keys, optional = parse_path(path)
                        if (kind == "result" and contract == name and keys and not optional
                                and keys[0] not in contracts[satisfier]["result"]["required"]):
                            fault("satisfied-keys", name, "%s reads %s from it, which %s does not always give" % (reader, keys[0], satisfier))
    return faults


def load_catalog():
    try:
        with open(CATALOG_PATH, encoding="utf-8") as handle:
            catalog = json.load(handle)
    except (OSError, ValueError, RecursionError):
        raise RuntimeError("the step contract catalog cannot be read")
    faults = check_catalog(catalog)
    if faults:
        raise RuntimeError("the step contract catalog is unsound (%s)" % faults[0])
    return catalog["contracts"]


def providers_of(contracts, need):
    """The contracts whose step meets a requirement for `need`: itself and its satisfiers."""
    return [need] + list(contracts[need].get("satisfiedBy", []))


def provider(steps, contracts, index, need):
    """The nearest step before `index` that provides `need`, or None."""
    accepted = providers_of(contracts, need)
    for earlier in range(index - 1, -1, -1):
        if steps[earlier]["contract"] in accepted:
            return earlier
    return None


# --- the definition ----------------------------------------------------------------------------

def flat_steps(definition):
    """The definition's steps in order, each with its phase's name."""
    return [dict(step, phase=phase["name"]) for phase in definition["phases"] for step in phase["steps"]]


def _version(text):
    return tuple(int(part) for part in text.split("."))


def _text(value, limit, empty=False):
    return isinstance(value, str) and len(value) <= limit and (empty or bool(value))


def _whole(value):
    return isinstance(value, int) and not isinstance(value, bool)


def _shape_fault(definition):
    """Why a definition does not meet schemas/workflow.schema.json (the bad-schema refusal), or
    None. Every field the schema requires is checked, with its type and its limits."""
    if not isinstance(definition, dict):
        return "a definition is one JSON object"
    if definition.get("schema") != 1 or isinstance(definition.get("schema"), bool):
        return "schema must be 1"
    if not isinstance(definition.get("id"), str) or not WORKFLOW_ID.match(definition["id"]):
        return "id must be a lower-case slug of at most 100 characters"
    if not _whole(definition.get("version")) or definition["version"] < 1:
        return "version must be a whole number of at least 1"
    if not _text(definition.get("name"), NAME_MAX):
        return "name must be text of 1 to %d characters" % NAME_MAX
    if definition.get("startsWhen") not in STARTS_WHEN:
        return "startsWhen must be one of %s" % ", ".join(STARTS_WHEN)
    if "endsBy" not in definition or definition["endsBy"] not in ENDS_BY:
        return "endsBy must be ship, hand-up or null"
    applies = definition.get("appliesTo")
    if not isinstance(applies, dict) or any(not isinstance(applies.get(key), list) or not all(isinstance(v, str) for v in applies[key])
                                            for key in APPLIES_TO):
        return "appliesTo must hold workTypes, tags and repositories, each a list of text"
    if not isinstance(definition.get("minPluginVersion"), str) or not SEMVER.match(definition["minPluginVersion"]):
        return "minPluginVersion must be x.y.z"
    phases = definition.get("phases")
    if not isinstance(phases, list) or not 1 <= len(phases) <= MAX_PHASES:
        return "phases must be a list of 1 to %d phases" % MAX_PHASES
    total = 0
    for p, phase in enumerate(phases):
        where = "phases[%d]" % p
        if not isinstance(phase, dict):
            return "%s must be an object" % where
        if not isinstance(phase.get("id"), str) or not SLUG.match(phase["id"]):
            return "%s.id must be a lower-case slug" % where
        if not _text(phase.get("name"), NAME_MAX):
            return "%s.name must be text of 1 to %d characters" % (where, NAME_MAX)
        steps = phase.get("steps")
        if not isinstance(steps, list) or not 1 <= len(steps) <= MAX_PHASE_STEPS:
            return "%s.steps must be a list of 1 to %d steps" % (where, MAX_PHASE_STEPS)
        total += len(steps)
        if total > MAX_STEPS:
            return "a definition has at most %d steps across its phases" % MAX_STEPS
        for s, step in enumerate(steps):
            at = "%s.steps[%d]" % (where, s)
            if not isinstance(step, dict):
                return "%s must be an object" % at
            if not isinstance(step.get("id"), str) or not SLUG.match(step["id"]):
                return "%s.id must be a lower-case slug" % at
            if not _text(step.get("name"), NAME_MAX):
                return "%s.name must be text of 1 to %d characters" % (at, NAME_MAX)
            if not _text(step.get("summary"), SUMMARY_MAX, empty=True):
                return "%s.summary must be text of at most %d characters" % (at, SUMMARY_MAX)
            if not isinstance(step.get("contract"), str) or not CONTRACT.match(step["contract"]):
                return "%s.contract must be <name>@<major>" % at
            if step.get("kind") not in KINDS:
                return "%s.kind must be one of %s" % (at, ", ".join(KINDS))
            run = step.get("run")
            if not isinstance(run, dict) or run.get("source") not in RUN_SOURCES:
                return "%s.run.source must be one of %s" % (at, ", ".join(RUN_SOURCES))
            if "ref" not in run or not (run["ref"] is None or isinstance(run["ref"], str)):
                return "%s.run.ref must be text or null" % at
            if run["source"] != "off" and not run["ref"]:
                return "%s.run.ref must name what runs the step" % at
            if "version" not in run or not (run["version"] is None or isinstance(run["version"], str) or _whole(run["version"])):
                return "%s.run.version must be a whole number, text or null" % at
            when = step.get("when")
            if not isinstance(when, dict) or when.get("mode") not in WHEN_MODES:
                return "%s.when.mode must be one of %s" % (at, ", ".join(WHEN_MODES))
            if "condition" not in when or when["condition"] not in CONDITIONS:
                return "%s.when.condition must be review-path:fast, review-path:pull-request or null" % at
            if step.get("onFail") not in ON_FAIL:
                return "%s.onFail must be one of %s" % (at, ", ".join(ON_FAIL))
    return None


def _credential_at(value, path="$"):
    """Where a definition holds a string that looks like a credential, or None."""
    if isinstance(value, str):
        return path if has_secret(value) else None
    if isinstance(value, list):
        for at, item in enumerate(value):
            found = _credential_at(item, "%s[%d]" % (path, at))
            if found:
                return found
    elif isinstance(value, dict):
        for key, item in value.items():
            # a key that names a credential, holding a value shaped like one: {"password": "huntertwo"}
            if has_secret(key) or (credential_key(key) and isinstance(item, str) and CREDENTIAL_STRING.match(item)):
                return path
            found = _credential_at(item, "%s.%s" % (path, key))
            if found:
                return found
    return None


def validate_definition(definition, contracts, plugin_version, in_work_tree, root=PLUGIN_ROOT):
    """Refuse a definition this plugin cannot run whole. The codes are part of the contract."""
    problem = _shape_fault(definition)
    if problem:
        raise Refuse("bad-schema", problem)
    try:
        REPORT.canonical_json(definition)
        where = _credential_at(definition)
    except (ValueError, RecursionError) as error:
        raise Refuse("bad-schema", str(error))
    if where:
        # The definition is reported to the tracker as it is, so one that holds a credential is never run.
        raise Refuse("credential-in-definition", "%s holds what looks like a credential" % where)
    steps = flat_steps(definition)
    seen = set()
    for step in steps:
        if step["id"] in seen:
            raise Refuse("duplicate-step-id", "two steps are called %s" % step["id"])
        seen.add(step["id"])
    if not plugin_version or _version(definition["minPluginVersion"]) > _version(plugin_version):
        raise Refuse("plugin-too-old", "the workflow needs plugin %s; this is %s" % (
            definition["minPluginVersion"], plugin_version or "an unreadable version"))
    names = set(CONTRACT.match(name).group(1) for name in contracts)
    for step in steps:
        if step["contract"] not in contracts:
            if CONTRACT.match(step["contract"]).group(1) in names:
                raise Refuse("unknown-contract-major", "step %s: this plugin does not know %s" % (step["id"], step["contract"]))
            raise Refuse("unknown-contract", "step %s: no contract is called %s" % (step["id"], step["contract"]))
    for index, step in enumerate(steps):
        if step["run"]["source"] == "off":
            continue
        for need in contracts[step["contract"]]["requires"]:
            at = provider(steps, contracts, index, need)
            if at is None:
                accepted = providers_of(contracts, need)
                later = any(other["contract"] in accepted for other in steps[index + 1:])
                raise Refuse("requires-not-earlier" if later else "requires-missing",
                             "step %s needs a %s step before it" % (step["id"], need))
            given = steps[at]
            if given["run"]["source"] == "off":
                raise Refuse("required-off", "step %s is required by %s and cannot be switched off" % (given["id"], step["id"]))
            if given["when"]["mode"] != "always":
                raise Refuse("required-not-always", "step %s is required by %s and must always run" % (given["id"], step["id"]))
            if given["onFail"] != "stop":
                raise Refuse("required-not-stop", "step %s is required by %s and must stop the run when it fails" % (given["id"], step["id"]))
            again = [other for other in steps[index + 1:] if other["run"]["source"] != "off" and other["contract"] in providers_of(contracts, need)]
            if again:
                # Its changes would come after the step that checks them, so nothing would.
                raise Refuse("requires-not-earlier", "step %s provides %s after step %s, which requires it" % (again[0]["id"], need, step["id"]))
    for step in steps:
        if step["kind"] == "gate":
            raise Refuse("unsupported-gate", "step %s is a gate, which this plugin does not run" % step["id"])
        if step["when"]["mode"] != "always":
            raise Refuse("unsupported-when", "step %s runs on %s, which this plugin does not support" % (step["id"], step["when"]["mode"]))
        source = step["run"]["source"]
        if source in ("library", "repo") or (source == "builtin" and contracts[step["contract"]]["builtinSkill"] is None):
            raise Refuse("unsupported-source", "step %s: this plugin runs no %s skill for %s" % (step["id"], source, step["contract"]))
        if step["onFail"] != "stop":
            raise Refuse("unsupported-on-fail", "step %s carries on after a failure, which this plugin does not support" % step["id"])
    for step in steps:
        if step["run"]["source"] != "builtin":
            continue
        ref = step["run"]["ref"]
        if not SLUG.match(ref) or not os.path.isfile(os.path.join(root, "skills", ref, "SKILL.md")):
            raise Refuse("skill-missing", "step %s names the skill %s, which this plugin does not have" % (step["id"], ref))
    for step in steps:
        binding = contracts[step["contract"]]["proof"]["binding"]
        if step["run"]["source"] != "off" and binding != "none" and not in_work_tree:
            raise Refuse("repository-required", "step %s proves itself against a git %s; run inside a repository" % (step["id"], binding))
    return steps


# --- a step's answer ---------------------------------------------------------------------------

def has_secret(text):
    return bool(SECRET.search(text)) or any(credential_key(m.group(1)) for m in ASSIGNED.finditer(text))


def parse_verdict(entry, output):
    """The verdict on the first non-blank line as (value entry, detail), or None when that line is
    not `<label>: <a listed value>[ <detail>]`. The longest listed value wins."""
    first = next((line.strip() for line in output.splitlines() if line.strip()), None)
    prefix = entry["verdict"]["label"] + ": "
    if first is None or not first.startswith(prefix):
        return None
    rest = first[len(prefix):]
    best = None
    for value in entry["verdict"]["values"]:
        if (rest == value["value"] or rest.startswith(value["value"] + " ")) and (
                best is None or len(value["value"]) > len(best["value"])):
            best = value
    if best is None:
        return None
    detail = rest[len(best["value"]):].strip()
    if (best["detail"] == "none" and detail) or (best["detail"] == "required" and not detail):
        return None
    return best, detail


def split_output(output):
    """(evidence lines, result text or None): the lines after the verdict up to the first fenced
    json block, and that block's body. Whatever follows the block is not kept."""
    lines = output.splitlines()
    start = next(index for index, line in enumerate(lines) if line.strip()) + 1
    evidence = []
    for index in range(start, len(lines)):
        if FENCE_OPEN.match(lines[index]):
            body = []
            for line in lines[index + 1:]:
                if line.strip() == "```":
                    break
                body.append(line)
            return evidence, "\n".join(body)
        evidence.append(lines[index])
    return evidence, None


def read_result(entry, text):
    """(result, proof, links, problem) from a step's result block, checked against its contract.
    Unknown keys are dropped; a key of the wrong type counts as missing."""
    if text is None:
        block = {}
    elif len(text.encode("utf-8")) > RESULT_MAX_BYTES:
        return {}, None, {}, "the result block is over %d KB" % (RESULT_MAX_BYTES // 1024)
    else:
        try:
            block = json.loads(text)
        except (ValueError, RecursionError):
            block = None
        if not isinstance(block, dict):
            return {}, None, {}, "the result block is not one JSON object"
    types = entry["result"]["types"]
    result = dict((key, block[key]) for key in types if key in block and is_type(block[key], types[key]))
    lacking = [key for key in entry["result"]["required"] if key not in result]
    problem = "the result lacks %s" % ", ".join(lacking) if lacking else None
    proof = block.get("proof") if isinstance(block.get("proof"), dict) else None
    links = block.get("links") if isinstance(block.get("links"), dict) else {}
    # Only https addresses are kept; the reporting helper then applies its own caps.
    links = dict((key, value) for key, value in links.items() if isinstance(value, str) and not has_secret(value)
                 and (key == "branch" or value.startswith("https://")))
    return result, proof, REPORT.clean_links(links), problem


def proof_fault(contract, entry, proof, value=None, result=None):
    """Why a proof is refused outright (its shape, a value the catalog does not list or that
    disagrees with the verdict `value`, or a named acceptance rule), or None."""
    rules = entry["proof"]
    if "required" not in rules:
        return None
    if proof is None:
        return "the result carries no proof"
    lacking = [key for key in rules["required"] if key not in proof or not is_type(proof[key], rules["types"][key])]
    if lacking:
        return "the proof lacks %s" % ", ".join(lacking)
    for key, allowed in rules.get("values", {}).items():
        if proof[key] not in allowed:
            return "the proof's %s is not one of %s" % (key, ", ".join(allowed))
    for key, wanted in ((value or {}).get("proof") or {}).items():
        if proof[key] != wanted:
            return "the verdict %s needs a proof whose %s is %s" % (value["value"], key, wanted)
    if contract == "risk-check@1" and proof["triggers"] and proof["verifiers"] < 1:
        return "risk-triggers-need-verifiers: the risk check names triggers and ran no verifier"
    if contract == "local-checks@1" and proof["kind"] == "receipt":
        named = lambda text: isinstance(text, str) and bool(text.strip())
        commands = (result or {}).get("commands")
        if not named(proof["receipt"]) or (result is not None and not (commands and all(named(c) for c in commands))):
            return "a pass names the commands it ran and carries their receipt"
    return None


def binding_holds(binding, proof, world, cwd, commit):
    """True when a proof still matches `commit`, the commit HEAD was found on. `tree`: the proof's
    tree is that commit's tree. `patch`: its patch id is the id of everything on that commit since
    its base, so a base that moved under an unchanged patch keeps the proof. `none`: nothing binds it."""
    if binding == "tree":
        return isinstance(proof, dict) and proof.get("tree") == world.tree(cwd, commit)
    if binding == "patch":
        real = isinstance(proof, dict) and world.patch_id(cwd, proof.get("base"), commit)
        return bool(real) and proof.get("patchId") == real
    return True


# --- state -------------------------------------------------------------------------------------

def state_dir(world, create):
    base = world.env.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
    path = os.path.join(base, "devstride-plugin", "workflows")
    real = os.path.realpath(path)
    plugin = os.path.realpath(PLUGIN_ROOT)
    if ".git" in real.split(os.sep) or real == plugin or real.startswith(plugin + os.sep):
        raise Refuse("state-unusable", "run state is never kept inside a repository's git folder or the plugin")
    if not create and not os.path.isdir(path):
        return None
    try:
        os.makedirs(path, mode=0o700, exist_ok=True)
        info = os.lstat(path)
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != world.uid:
            raise OSError("not this user's own directory")
        if info.st_mode & 0o077:
            os.chmod(path, 0o700)
    except OSError as error:
        raise Refuse("state-unusable", "the state folder cannot be used: %s" % (error.strerror or error))
    return path


def state_name(session, item):
    return "%s.%s.json" % (session, item or "run")


def read_state(path, world):
    """A state file is read only when it is a regular file this user owns, not a link, and small."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    except OSError:
        raise Refuse("state-unreadable", "the run's state file cannot be opened (a link is never followed)")
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != world.uid or info.st_size > STATE_MAX_BYTES:
            raise Refuse("state-unreadable", "the run's state file is not a small regular file this user owns")
        state = json.loads(os.read(fd, STATE_MAX_BYTES + 1).decode("utf-8"))
    except (OSError, ValueError, RecursionError):
        raise Refuse("state-unreadable", "the run's state file is not readable JSON")
    finally:
        os.close(fd)
    try:
        sound = (state["stateVersion"] == 1 and bool(RUN_ID.match(state["runId"])) and isinstance(state["steps"], dict)
                 and isinstance(state["context"], dict) and isinstance(state["seq"], int)
                 and REPORT.definition_hash(state["definition"]) == state["definitionHash"]
                 and all(step["id"] in state["steps"] for step in flat_steps(state["definition"])))
    except (KeyError, TypeError, ValueError, AttributeError):
        sound = False
    if not sound:
        raise Refuse("state-unreadable", "the run's state file is not one this runner wrote")
    return state


def write_state(folder, state):
    """Atomic and owner-only: a new file beside the final name, then moved over it."""
    state["seq"] += 1
    name = state_name(state["sessionId"], state["item"])
    data = (json.dumps(state, separators=(",", ":"), sort_keys=True) + "\n").encode("utf-8")
    if len(data) > STATE_MAX_BYTES:
        raise Refuse("state-unusable", "the run's state has grown past %d bytes" % STATE_MAX_BYTES)
    temporary = os.path.join(folder, ".%s.%s.tmp" % (name, secrets.token_hex(8)))
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)
    os.replace(temporary, os.path.join(folder, name))  # replaces a link itself, never its target


def prune(folder, world):
    now = time.time()
    for name in os.listdir(folder):
        path = os.path.join(folder, name)
        try:
            info = os.lstat(path)
            if stat.S_ISREG(info.st_mode) and info.st_uid == world.uid and now - info.st_mtime > KEEP_SECONDS:
                os.unlink(path)
        except OSError:
            pass


def session_of(request, world):
    session = request.get("session")
    if session is None:
        session = CLAIMS.session_id(world.env) or "manual-%d" % os.getppid()
    if not isinstance(session, str) or not SESSION.match(session):
        raise Refuse("bad-request", "session must be 1 to 128 letters, digits, dots, hyphens or underscores")
    return session


def item_of(value):
    if value is not None and not (isinstance(value, str) and REPORT.ITEM.match(value)):
        raise Refuse("bad-request", "item must be an item number or null")
    return value


def find_run(world, request, session):
    """This session's run: the one for the item, else the one with the run id, else its only
    open run. Returns (folder, state)."""
    item, run_id = item_of(request.get("item")), request.get("runId")
    if run_id is not None and not (isinstance(run_id, str) and RUN_ID.match(run_id)):
        raise Refuse("bad-request", "runId is 32 lower-case hex characters")
    folder = state_dir(world, create=False)
    if folder is None:
        raise Refuse("no-run", "this session has no run")
    if item:
        names = [state_name(session, item)] if os.path.lexists(os.path.join(folder, state_name(session, item))) else []
    else:
        names = sorted(name for name in os.listdir(folder) if name.startswith(session + ".") and name.endswith(".json"))
    states = [read_state(os.path.join(folder, name), world) for name in names]
    states = [state for state in states if state.get("sessionId") == session]
    if run_id:
        states = [state for state in states if state["runId"] == run_id]
    elif not item:
        states = [state for state in states if not state["outcome"]]
    if not states:
        raise Refuse("no-run", "this session has no such run")
    if len(states) > 1:
        raise Refuse("ambiguous-run", "this session has %d open runs; name the item or the run" % len(states))
    return folder, states[0]


# --- one run -----------------------------------------------------------------------------------

def ended_well(record):
    return record["status"] in ("done", "skipped") and record["class"] in ("continue", "skipped")


def dig(value, keys):
    for key in keys:
        if not isinstance(value, dict) or key not in value:
            return MISSING
        value = value[key]
    return value


class Run:
    """One run's state plus what this command has to report about it."""

    def __init__(self, state, contracts, world):
        self.state, self.contracts, self.world = state, contracts, world
        self.steps = flat_steps(state["definition"])
        self.events = []        # step reports, in the order they happened
        self.closing = None     # the run's end as the tracker is told it
        self.resend_definition = False
        self.commit = None      # the commit HEAD is on, read once per command

    def record(self, index):
        return self.state["steps"][self.steps[index]["id"]]

    def entry(self, index):
        return self.contracts[self.steps[index]["contract"]]

    def index_of(self, step_id):
        for index, step in enumerate(self.steps):
            if step["id"] == step_id:
                return index
        raise Refuse("not-current-step", "the workflow has no step called %s" % (step_id,))

    def provider(self, index, need):
        return provider(self.steps, self.contracts, index, need)

    # -- proofs --

    def relied_on(self, index):
        """True while a later step that requires this one has not finished."""
        for later in range(index + 1, len(self.steps)):
            if self.steps[later]["run"]["source"] == "off" or ended_well(self.record(later)):
                continue
            if any(self.provider(later, need) == index for need in self.entry(later)["requires"]):
                return True
        return False

    def head(self):
        """HEAD as a full commit id, read once: every proof this command checks, and the commit a
        merge it issues is handed, are that one commit, whatever lands on the branch meanwhile."""
        if self.commit is None:
            self.commit = self.world.head(self.state["context"]["cwd"])
        return self.commit

    def binding_holds(self, index, proof):
        binding = self.entry(index)["proof"]["binding"]
        if binding == "none":
            return True
        return binding_holds(binding, proof, self.world, self.state["context"]["cwd"], self.head())

    def proof_gone(self, index):
        """Why a finished step's proof no longer holds (`superseded` or `stale`), or None."""
        record = self.record(index)
        if record["class"] != "continue":
            return None
        for need in self.entry(index)["requires"]:
            given = self.provider(index, need)
            if given is not None and (self.record(given)["doneSeq"] or 0) > (record["doneSeq"] or 0):
                return "superseded"
        return None if self.binding_holds(index, record["proof"]) else "stale"

    def merge_refused(self, index):
        """none-configured-needs-pull-request-route: a merge accepts local checks that found
        nothing configured only when the review ran on a pull request, where CI is the gate."""
        if self.steps[index]["contract"] != "merge@1":
            return None
        checks, review = self.provider(index, "local-checks@1"), self.provider(index, "review@1")
        checked = (self.record(checks)["proof"] or {}) if checks is not None else {}
        reviewed = (self.record(review)["proof"] or {}) if review is not None else {}
        if checked.get("kind") == "none-configured" and reviewed.get("path") != "pull-request":
            return ("none-configured-needs-pull-request-route: no local checks are configured, "
                    "so the merge needs a review that ran on a pull request")
        return None

    def landed_fault(self, index, proof):
        """merge-lands-what-was-checked: a merge that landed names the commit it merged, and it is
        the commit it was handed (`issuedHead`), the one the local checks' tree and the review's
        patch were found to hold for when the merge was issued."""
        record = self.record(index)
        if self.steps[index]["contract"] != "merge@1" or proof.get("head") == record.get("issuedHead"):
            return None
        return ("merge-lands-what-was-checked: the merge names another commit than %s, the one the local checks "
                "and the review were proven on; resume to check what changed" % (record.get("issuedHead") or "none"))

    # -- what a step is handed --

    def payload(self, index):
        step, record = self.steps[index], self.record(index)
        out = {}
        for key, path in self.entry(index)["payload"].items():
            kind, contract, keys, optional = parse_path(path)
            if kind == "context":
                value = dig(self.state["context"], keys)
            elif kind == "result":
                given = self.provider(index, contract)
                value = dig(self.record(given)["result"], keys) if given is not None and ended_well(self.record(given)) else MISSING
            else:
                value = {"answer": record["answer"], "proof": record["proof"], "head": record.get("issuedHead")}[keys[0]]
                value = MISSING if value is None else value
            if value is MISSING and not optional:
                raise KeyError(key)
            out[key] = None if value is MISSING else value
        out["step"], out["contract"] = step["id"], step["contract"]
        return out

    def ship_intent(self, index, stage):
        context = self.state["context"]
        branch = self.provider(index, "branch@1")
        branch = self.record(branch)["result"].get("branch") if branch is not None else None
        request = {"route": context.get("route"), "unit": self.state["item"], "branch": branch,
                   "target": context.get("workingBase"), "stage": stage}
        return request if stage and all(isinstance(value, str) and value for value in request.values()) else None

    def run_answer(self, index):
        step, record, entry = self.steps[index], self.record(index), self.entry(index)
        payload = self.payload(index)
        if entry["argument"] is None:
            argument = json.dumps(payload, separators=(",", ":"), ensure_ascii=False)
        else:
            argument = TEMPLATE_FIELD.sub(lambda m: "" if payload.get(m.group(1)) is None else str(payload[m.group(1)]), entry["argument"])
        return {"action": "run", "runId": self.state["runId"],
                "step": {"id": step["id"], "name": step["name"], "phase": step["phase"],
                         "contract": step["contract"], "attempt": record["attempt"]},
                "skill": {"source": "builtin", "ref": step["run"]["ref"]},
                "payload": payload, "argument": argument,
                "heartbeat": {"phase": entry["claimPhase"], "stage": entry["shipIntentStage"],
                              "shipIntent": self.ship_intent(index, entry["shipIntentStage"])}}

    # -- transitions --

    def report(self, index):
        step, record = self.steps[index], self.record(index)
        status = "running" if record["status"] == "issued" else record["status"]
        self.events.append({"step": step["id"], "attempt": max(record["attempt"], 1), "status": status,
                            "verdict": record["verdict"], "evidence": record["evidence"], "links": record["links"],
                            "startedAt": record["startedAt"], "endedAt": record["endedAt"], "ran": record["ran"]})

    def stop(self, kind, reason, index):
        self.state["current"] = None
        self.state["stopped"] = {"kind": kind, "reason": REPORT.clean_verdict(reason) or kind, "stepId": self.steps[index]["id"]}
        self.closing = {"outcome": RUN_OUTCOME[kind], "endedAt": self.world.now()}
        return self.stopped_answer()

    def stopped_answer(self):
        return dict(self.state["stopped"], action="stopped", runId=self.state["runId"])

    def finish(self, outcome):
        self.state["current"] = None
        self.state["outcome"], self.state["endedAt"] = outcome, self.world.now()
        self.closing = {"outcome": RUN_OUTCOME.get(outcome, "interrupted"), "endedAt": self.state["endedAt"]}
        return self.finished_answer()

    def finished_answer(self):
        results = {}
        for index, step in enumerate(self.steps):
            if self.record(index)["status"] == "done":
                results[step["contract"]] = self.record(index)["result"]
        return {"action": "finished", "runId": self.state["runId"], "outcome": self.state["outcome"], "results": results}

    def issue(self, index, cause):
        """Hand out a step. `cause` names the runner's own reason for a re-issue (None when a
        person or the plain order asked): those are counted, and the fifth stops the run."""
        step, record = self.steps[index], self.record(index)
        refused = self.merge_refused(index)
        if refused:
            return self.stop("proof", refused, index)
        if step["contract"] == "merge@1":
            try:
                self.head()
            except GitFailed as error:
                return self.stop("proof", "the commit step %s would merge cannot be read: %s" % (step["id"], error), index)
        if cause and cause != "redo":  # a step's own verdict asking for another go is not the runner's re-issue
            record["autoRedo"] += 1
            if record["autoRedo"] >= AUTO_REDO_LIMIT:
                return self.stop("attempts-exhausted", "step %s was re-issued %d times without its proof holding" % (
                    step["id"], AUTO_REDO_LIMIT - 1), index)
        if record["attempt"] >= REPORT.MAX_ATTEMPT:
            return self.stop("attempts-exhausted", "step %s has run %d times" % (step["id"], record["attempt"]), index)
        try:
            self.payload(index)
        except KeyError as error:
            return self.stop("failed", "step %s cannot be handed %s: an earlier step did not give it" % (step["id"], error.args[0]), index)
        ref = step["run"]["ref"]
        try:
            with open(os.path.join(PLUGIN_ROOT, "skills", ref, "SKILL.md"), "rb") as handle:
                digest = hashlib.sha256(handle.read()).hexdigest()
        except OSError:
            raise Refuse("skill-missing", "step %s names the skill %s, which this plugin no longer has" % (step["id"], ref))
        # A step re-issued only to refresh its own stale proof does not void the steps that rely
        # on it: they hold their own proofs (a rebase that leaves the patch alone keeps the review).
        refresh = cause == "stale" or (cause == "mismatch" and record.get("refresh", False))
        record.update(attempt=record["attempt"] + 1, status="issued", verdict=None, evidence=[], links={},
                      startedAt=self.world.now(), endedAt=None, refresh=refresh, redo=None, issuedHead=self.commit,
                      ran={"source": "builtin", "ref": ref, "version": self.state["pluginVersion"], "hash": digest})
        record["class"] = None
        self.state["current"] = {"stepId": step["id"], "attempt": record["attempt"]}
        self.report(index)
        return self.run_answer(index)

    def advance(self):
        """The next action: the first step, in order, that is not satisfied."""
        state = self.state
        if state["outcome"]:
            return self.finished_answer()
        if state["stopped"]:
            return self.stopped_answer()
        if state["current"]:
            # An issued step is handed back as it was: it may already have acted (a merge that
            # landed), so only its answer moves the run on, and its proofs are checked then.
            index = self.index_of(state["current"]["stepId"])
            self.report(index)  # the same running report again: harmless, and a lost one is not lost
            return self.run_answer(index)
        for index, step in enumerate(self.steps):
            record = self.record(index)
            if step["run"]["source"] == "off":
                if record["status"] != "skipped":
                    record.update(status="skipped", verdict="Off", startedAt=self.world.now(), endedAt=self.world.now(),
                                  ran={"source": "off"})
                    record["class"] = "skipped"
                    self.report(index)
                continue
            cause = record.get("redo")
            if ended_well(record):
                if not self.relied_on(index):
                    continue
                try:
                    cause = self.proof_gone(index)
                except GitFailed as error:
                    return self.stop("proof", "the proof of step %s cannot be checked: %s" % (step["id"], error), index)
                if cause is None:
                    continue
            elif record["status"] == "done":
                cause = "redo"  # its own verdict asked for another go
            return self.issue(index, cause)
        return self.finish("completed")

    def complete(self, index, output):
        """Record a step's answer: its verdict, evidence, result and proof, and what that means
        for the step and the run. Whatever cannot be read as a pass is recorded as a failure."""
        state, step, record, entry = self.state, self.steps[index], self.record(index), self.entry(index)
        state["current"], state["stopped"] = None, None
        record.update(endedAt=self.world.now(), answer=None, evidence=[], links={}, redo=None)
        parsed = parse_verdict(entry, output) if isinstance(output, str) else None
        if parsed is None:
            record.update(status="failed", verdict="No verdict")
            record["class"] = None
            self.report(index)
            self.stop("no-verdict", "step %s did not open its answer with a `%s: …` verdict its contract lists" % (
                step["id"], entry["verdict"]["label"]), index)
            return
        value, detail = parsed
        if has_secret(detail):
            detail = WITHHELD
        line = REPORT.clean_verdict("%s: %s %s" % (entry["verdict"]["label"], value["value"], detail))
        lines, text = split_output(output)
        result, proof, links, problem = read_result(entry, text)
        record.update(verdict=line, evidence=REPORT.clean_evidence([l for l in lines if not has_secret(l)]),
                      result=result, proof=proof, links=links)
        kind = record["class"] = value["class"]
        after = None  # (stop kind, reason) once the report is queued
        if kind == "continue":
            # The merge rule is asked again here: a step repaired by hand was never issued past it.
            fault = (problem or proof_fault(step["contract"], entry, proof, value, result) or self.merge_refused(index)
                     or self.landed_fault(index, proof or {}))
            try:
                holds = fault is not None or self.binding_holds(index, proof)
            except GitFailed as error:
                fault, holds = "its proof cannot be checked: %s" % error, True
            if fault:
                record["status"] = "failed"
                after = ("failed" if problem else "proof", "step %s: %s" % (step["id"], fault))
            elif not holds:
                # A claimed tree or patch that is not the real one: failed, and issued again.
                record.update(status="failed", redo="mismatch")
            else:
                record["status"] = "done"
                if not (record.get("refresh") and record["doneSeq"]):
                    record["doneSeq"] = state["seq"] + 1
                record.update(refresh=False, autoRedo=0)  # its proof holds: the runner's re-issues start again from 0
        elif kind == "skipped":
            record["status"] = "skipped"
        elif kind == "stop":
            record["status"] = "failed"
            after = ("failed", line)
        elif kind == "ask":
            record["status"] = "waiting"
            after = ("needs-person", detail)
        else:  # redo:self, or end:<outcome>
            record["status"] = "done"
        self.report(index)
        if after:
            self.stop(after[0], after[1], index)
        elif END_CLASS.match(kind):
            self.finish(END_CLASS.match(kind).group(1))

    # -- reporting --

    def reports(self):
        """The argument objects for the tracker's step-recording tool: at most a few step reports
        each, the definition in the first one of a run, the run's end in the last."""
        state = self.state
        size = REPORT.MAX_REPORTS
        chunks = [self.events[at:at + size] for at in range(0, len(self.events), size)]
        if not chunks and (self.closing or self.resend_definition):
            chunks = [[]]
        objects = []
        for number, chunk in enumerate(chunks):
            definition = None
            if number == 0 and (self.resend_definition or not state["definitionReported"]):
                definition = state["definition"]
            closing = self.closing if number == len(chunks) - 1 else None
            try:
                objects.append(REPORT.build_report_arguments(
                    state["runId"], state["sessionId"], chunk, item_number=state["item"],
                    repository=state["context"].get("repository"), definition=definition,
                    run=closing, now=self.world.now()))
            except ValueError:
                continue  # a report that cannot be shaped is not sent; it never stops the run
            if definition is not None and not self.resend_definition:
                state["definitionReported"] = True
        return objects


# --- the commands ------------------------------------------------------------------------------

def read_definition_file(path):
    if not isinstance(path, str) or not path:
        raise Refuse("bad-request", "definitionFile is a path")
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_size > DEFINITION_FILE_MAX_BYTES:
                raise Refuse("definition-unreadable", "the definition must be a regular file of at most 256 KB")
            return json.loads(os.read(fd, DEFINITION_FILE_MAX_BYTES + 1).decode("utf-8"))
        finally:
            os.close(fd)
    except (OSError, ValueError, RecursionError):
        raise Refuse("definition-unreadable", "the definition file cannot be read as JSON")


def new_record():
    return {"attempt": 0, "autoRedo": 0, "status": "pending", "verdict": None, "class": None, "evidence": [],
            "result": {}, "proof": None, "links": {}, "startedAt": None, "endedAt": None, "doneSeq": None,
            "ran": None, "answer": None, "refresh": False, "redo": None, "issuedHead": None}


def close_replaced(old, world):
    """The report that ends a run another start replaced."""
    try:
        return [REPORT.build_report_arguments(
            old["runId"], old["sessionId"], [], item_number=old["item"], repository=old["context"].get("repository"),
            run={"outcome": RUN_OUTCOME["interrupted"], "endedAt": world.now()}, now=world.now())]
    except ValueError:
        return []


def command_start(world, request, contracts):
    if ("definition" in request) == ("definitionFile" in request):
        raise Refuse("bad-request", "start takes exactly one of definition and definitionFile")
    definition = request["definition"] if "definition" in request else read_definition_file(request["definitionFile"])
    context = request.get("context")
    if not isinstance(context, dict):
        raise Refuse("bad-request", "context must be an object")
    context = dict(context)
    item = item_of(context.get("item"))
    cwd = context.get("cwd", os.getcwd())
    if not isinstance(cwd, str) or not os.path.isdir(cwd):
        raise Refuse("bad-request", "context.cwd must be a directory")
    cwd = os.path.realpath(cwd)
    session = session_of(request, world)
    version = CLAIMS.plugin_version(PLUGIN_ROOT)
    steps = validate_definition(definition, contracts, version, world.in_work_tree(cwd))
    for step in steps:
        if step["run"]["source"] == "off":
            continue
        for key, path in contracts[step["contract"]]["payload"].items():
            kind, _, keys, optional = parse_path(path)
            if kind == "context" and not optional and dig(context, keys) is MISSING:
                raise Refuse("context-missing", "step %s needs context.%s" % (step["id"], ".".join(keys)))
    folder = state_dir(world, create=True)
    path = os.path.join(folder, state_name(session, item))
    replaced = []
    if os.path.lexists(path):
        old = read_state(path, world)
        if not old["outcome"]:
            if request.get("replace") is not True:
                raise Refuse("run-open", "this session already has an open run for %s; resume it, or start with replace" % (item or "no item"))
            replaced = close_replaced(old, world)
    prune(folder, world)
    context.update(cwd=cwd, repository=REPORT.read_repository(cwd))
    state = {"stateVersion": 1, "runId": secrets.token_hex(16), "sessionId": session, "item": item,
             "startedAt": world.now(), "endedAt": None, "outcome": None, "pluginVersion": version,
             "definition": definition, "definitionHash": REPORT.definition_hash(definition), "context": context,
             "seq": 0, "current": None, "stopped": None, "definitionReported": False,
             "steps": dict((step["id"], new_record()) for step in steps)}
    run = Run(state, contracts, world)
    answer = run.advance()
    answer.update(definitionHash=state["definitionHash"], reports=replaced + run.reports())
    write_state(folder, state)
    return answer


def command_next(world, request, contracts):
    folder, state = find_run(world, request, session_of(request, world))
    run = Run(state, contracts, world)
    answer = run.advance()
    answer["reports"] = run.reports()
    write_state(folder, state)
    return answer


def command_done(world, request, contracts):
    folder, state = find_run(world, request, session_of(request, world))
    run = Run(state, contracts, world)
    step_id, attempt = request.get("stepId"), request.get("attempt")
    current, stopped = state["current"], state["stopped"]
    if isinstance(attempt, bool) or not isinstance(attempt, int) or not isinstance(step_id, str):
        raise Refuse("bad-request", "done names the step (stepId) and its attempt (a whole number)")
    issued = current is not None and current == {"stepId": step_id, "attempt": attempt}
    # The one exception: the step a stopped run stopped on, repaired by hand and reported.
    repaired = (not state["outcome"] and current is None and stopped is not None and stopped["stepId"] == step_id
                and attempt >= 1 and state["steps"][step_id]["attempt"] == attempt)
    if not (issued or repaired):
        raise Refuse("not-current-step", "the run is not waiting for attempt %s of step %s" % (attempt, step_id))
    index = run.index_of(step_id)
    run.complete(index, request.get("output"))
    record = run.record(index)
    recorded = {"stepId": step_id, "attempt": attempt, "verdict": record["verdict"], "class": record["class"], "status": record["status"]}
    answer = run.advance()
    answer.update(recorded=recorded, reports=run.reports())
    write_state(folder, state)
    return answer


def command_status(world, request, contracts):
    _, state = find_run(world, request, session_of(request, world))
    run = Run(state, contracts, world)
    rows = [{"stepId": step["id"], "phase": step["phase"], "name": step["name"], "status": run.record(index)["status"],
             "verdict": run.record(index)["verdict"], "attempt": run.record(index)["attempt"]}
            for index, step in enumerate(run.steps)]
    at = (state["current"] or state["stopped"] or {}).get("stepId")
    position = None
    if at and not state["outcome"]:
        position = {"stepId": at, "index": run.index_of(at) + 1, "of": len(rows)}
    table = ["| Phase | Step | Status | Verdict | Attempt |", "|---|---|---|---|---|"]
    for row in rows:
        table.append("| %s | %s | %s | %s | %s |" % tuple(
            str(cell if cell is not None else "").replace("|", "\\|")
            for cell in (row["phase"], row["name"], row["status"], row["verdict"], row["attempt"] or "")))
    if request.get("includeDefinition") is True:
        run.resend_definition = True
    return {"runId": state["runId"], "state": "finished" if state["outcome"] else "stopped" if state["stopped"] else "running",
            "position": position, "rows": rows, "table": "\n".join(table), "reports": run.reports()}


def adopt(world, request, session):
    """An unfinished run for the same item (or with the named run id) that another of this user's
    sessions left on this machine, newest first, rewritten under this session."""
    item, run_id = item_of(request.get("item")), request.get("runId")
    folder = state_dir(world, create=False)
    if folder is None or not (item or run_id):
        raise Refuse("no-run", "there is no unfinished run to resume")
    found = []
    for name in os.listdir(folder):
        if not name.endswith(".%s.json" % item if item else ".json") or name.startswith("."):
            continue
        path = os.path.join(folder, name)
        try:
            state = read_state(path, world)
            modified = os.lstat(path).st_mtime
        except (Refuse, OSError):
            continue  # not this user's, not a state file, or gone: never adopted
        if (not state["outcome"] and state["sessionId"] != session and (item is None or state["item"] == item)
                and (not run_id or state["runId"] == run_id) and state_name(state["sessionId"], state["item"]) == name):
            found.append((modified, path, state))
    if not found:
        raise Refuse("no-run", "there is no unfinished run to resume")
    _, old_path, state = max(found, key=lambda entry: entry[0])
    mine = os.path.join(folder, state_name(session, state["item"]))
    if os.path.lexists(mine) and not read_state(mine, world)["outcome"]:
        # As start: an open run of this session's own is never overwritten.
        raise Refuse("run-open", "this session already has an open run for %s; finish it, or start with replace" % (state["item"] or "no item"))
    state["sessionId"] = session
    state["definitionReported"] = False  # the first report after an adoption carries the definition again
    write_state(folder, state)
    os.unlink(old_path)
    return folder, state


def command_resume(world, request, contracts):
    session = session_of(request, world)
    answer_text = request.get("answer")
    if answer_text is not None and not (isinstance(answer_text, str) and len(answer_text) <= ANSWER_MAX_CHARS):
        raise Refuse("bad-request", "answer is text of at most %d characters" % ANSWER_MAX_CHARS)
    try:
        folder, state = find_run(world, request, session)
        if state["outcome"]:
            raise Refuse("no-run", "that run has ended")
    except Refuse as refusal:
        if refusal.code != "no-run":
            raise
        folder, state = adopt(world, request, session)
    prune(folder, world)
    run = Run(state, contracts, world)
    at = (state["stopped"] or state["current"] or {}).get("stepId")
    if at:
        record = state["steps"][at]
        if state["stopped"]:
            record["autoRedo"] = 0  # a person can always continue
        if answer_text is not None:
            record["answer"] = answer_text
    state["stopped"] = None
    answer = run.advance()
    answer["reports"] = run.reports()
    write_state(folder, state)
    return answer


HANDLERS = {"start": command_start, "next": command_next, "done": command_done,
            "status": command_status, "resume": command_resume}


def run_command(command, request, world=None):
    """One command, in process: what the command line does after it has read stdin."""
    load_helpers()
    if command not in HANDLERS:
        raise Refuse("bad-request", "usage: workflow.py %s   (one JSON object on stdin)" % "|".join(COMMANDS))
    if not isinstance(request, dict):
        raise Refuse("bad-request", "the request on stdin must be one JSON object")
    world = world or World()
    if "now" in request:
        if not isinstance(request["now"], str) or not REPORT.ISO.match(request["now"]):
            raise Refuse("bad-request", "now must be an ISO time")
        world._now = request["now"]
    return HANDLERS[command](world, request, load_catalog())


def shown(message):
    """A message as it may leave the runner: one line, and never an echoed credential."""
    message = CONTROL.sub(" ", message)
    return NOT_SHOWN if has_secret(message) else message


def main(argv):
    try:
        if len(argv) != 2:
            raise Refuse("bad-request", "usage: workflow.py %s   (one JSON object on stdin)" % "|".join(COMMANDS))
        try:
            request = json.loads(sys.stdin.read(REQUEST_MAX_BYTES + 1)[:REQUEST_MAX_BYTES])
        except (ValueError, RecursionError):
            raise Refuse("bad-request", "the request on stdin is not JSON")
        answer = run_command(argv[1], request)
    except Refuse as refusal:
        sys.stderr.write("workflow: %s: %s\n" % (refusal.code, shown(str(refusal))))
        return 2
    sys.stdout.write(json.dumps(answer, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as error:  # never a traceback on the caller's screen
        sys.stderr.write("workflow: internal-error: %s\n" % shown(str(error) or error.__class__.__name__))
        sys.exit(1)
