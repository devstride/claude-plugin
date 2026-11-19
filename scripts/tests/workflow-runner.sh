#!/bin/bash
# Tests for skills/run-workflow/scripts/workflow.py, the step runner: every case in
# skills/run-workflow/scripts/workflow-fixtures.json, the refusal contract (exit 2, exactly one
# `workflow:` line, nothing on stdout, never a traceback), and a run driven end to end with
# canned step answers. Everything happens in a throwaway directory: its own cache folder, copies
# of the plugin whose step skills are placeholders, and small git
# repositories for the proof cases. No network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export PYTHONDONTWRITEBYTECODE=1
unset CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID XDG_CACHE_HOME GIT_DIR GIT_WORK_TREE

cat > "$WORK/cases.py" <<'PY'
import ast, base64, copy, hashlib, importlib.util, json, os, re, shutil, stat, subprocess, sys, time

ROOT, WORK, SECTION = sys.argv[1], sys.argv[2], sys.argv[3]
RUNNER = "skills/run-workflow/scripts/workflow.py"
FIX = json.load(open(os.path.join(ROOT, "skills/run-workflow/scripts/workflow-fixtures.json"), encoding="utf-8"))
REAL_CATALOG = json.load(open(os.path.join(ROOT, "schemas/step-contracts.json"), encoding="utf-8"))
PENDING = ["claim-story", "story-lifecycle", "risk-check", "local-checks", "review-story", "merge-story",
           "capture-findings", "sync-base"]
CODES = ["bad-schema", "duplicate-step-id", "unknown-contract", "unknown-contract-major", "requires-missing",
         "requires-not-earlier", "required-not-always", "required-not-stop", "required-off", "skill-missing",
         "plugin-too-old", "repository-required", "unsupported-gate", "unsupported-when", "unsupported-source",
         "unsupported-on-fail", "credential-in-definition"]
OFF = {"source": "off", "ref": None, "version": None}
counter, made = [0], [0]


def check(label, good, detail=""):
    counter[0] += 1
    print(("ok   " if good else "FAIL ") + label + ("" if good else " -> %s" % (detail,)))
    return good


def load(root=ROOT):
    spec = importlib.util.spec_from_file_location("workflow_under_test", os.path.join(root, RUNNER))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.load_helpers()
    return module


def stand_in_catalog():
    catalog = copy.deepcopy(REAL_CATALOG)
    catalog["contracts"].update(copy.deepcopy(FIX["catalogs"]["standIn"]["contracts"]))
    for name, satisfiers in FIX["catalogs"]["standIn"]["satisfiedBy"].items():
        catalog["contracts"][name]["satisfiedBy"] = list(satisfiers)
    return catalog


def plugin_copy(name, catalog=None):
    """A copy of the plugin whose Build step skills are placeholders."""
    root = os.path.join(WORK, name)
    if os.path.isdir(root):
        return root
    for folder in (".claude-plugin", "schemas", "skills/run-workflow/scripts", "skills/build-item/scripts"):
        os.makedirs(os.path.join(root, folder))
    shutil.copy(os.path.join(ROOT, ".claude-plugin/plugin.json"), os.path.join(root, ".claude-plugin/plugin.json"))
    for path in (RUNNER, "skills/build-item/scripts/workflow_report.py", "skills/build-item/scripts/claim_record.py"):
        shutil.copy(os.path.join(ROOT, path), os.path.join(root, path))
    with open(os.path.join(root, "schemas/step-contracts.json"), "w", encoding="utf-8") as out:
        json.dump(catalog or REAL_CATALOG, out)
    for skill in ("branch-feature", "ultracode-build"):
        os.makedirs(os.path.join(root, "skills", skill))
        shutil.copy(os.path.join(ROOT, "skills", skill, "SKILL.md"), os.path.join(root, "skills", skill, "SKILL.md"))
    for skill in PENDING + ["stand-in"]:
        os.makedirs(os.path.join(root, "skills", skill))
        with open(os.path.join(root, "skills", skill, "SKILL.md"), "w") as out:
            out.write("---\nname: %s\n---\nA placeholder for a step skill.\n" % skill)
    return root


def roots(which):
    if which == "real":
        return ROOT
    return plugin_copy("plugin-stand-in", stand_in_catalog()) if which == "standIn" else plugin_copy("plugin")


def fresh(name):
    made[0] += 1
    path = os.path.join(WORK, "%s-%s-%d" % (SECTION, name, made[0]))
    os.makedirs(path)
    return path


def cli(root, command, request, cache, cwd=None, session="s1", raw=None):
    """Run one command. Returns (exit code, the answer or None, stdout, stderr)."""
    env = dict((k, v) for k, v in os.environ.items() if k not in ("CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID"))
    env["XDG_CACHE_HOME"] = cache
    if raw is None:
        request = dict(request)
        request.setdefault("session", session)
        raw = json.dumps(request)
    done = subprocess.run([sys.executable, "-B", os.path.join(root, RUNNER)] + ([command] if command else []),
                          input=raw, capture_output=True, text=True, env=env, cwd=cwd or WORK)
    answer = None
    if done.returncode == 0:
        answer = json.loads(done.stdout)
    return done.returncode, answer, done.stdout, done.stderr


def refused(result, code):
    rc, _, out, err = result
    return rc == 2 and out == "" and re.match(r"^workflow: %s: [^\n]+\n$" % re.escape(code), err) is not None and "Traceback" not in err


def edit(definition, edits):
    definition = copy.deepcopy(definition)

    def find(step_id):
        for phase in definition["phases"]:
            for at, step in enumerate(phase["steps"]):
                if step["id"] == step_id:
                    return phase["steps"], at
        raise KeyError(step_id)

    def put(target, path, value):
        for key in path[:-1]:
            target = target[key]
        target[path[-1]] = value

    for change in edits:
        op = change["op"]
        if op == "replace":
            return copy.deepcopy(change["value"])
        if op == "top":
            put(definition, change["path"], copy.deepcopy(change["value"]))
        elif op == "drop":
            target = definition
            for key in change["path"][:-1]:
                target = target[key]
            del target[change["path"][-1]]
        elif op == "repeat":
            target = definition
            for key in change["path"]:
                target = target[key]
            first = target[0]
            target[:] = [first] + [dict(copy.deepcopy(first), id="%s-%d" % (first["id"], n)) for n in range(2, change["count"] + 1)]
        elif op == "set":
            steps, at = find(change["step"])
            put(steps[at], change["path"], copy.deepcopy(change["value"]))
        elif op == "remove":
            steps, at = find(change["step"])
            del steps[at]
        elif op == "move":
            steps, at = find(change["step"])
            moved = steps.pop(at)
            steps, at = find(change["after"])
            steps.insert(at + 1, moved)
        elif op == "add":
            steps, at = find(change["after"])
            steps.insert(at + 1, copy.deepcopy(change["value"]))
    return definition


def git(repo, *args, **kw):
    done = subprocess.run(["git", "-C", repo, "-c", "user.name=Test", "-c", "user.email=test@example.com",
                           "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + list(args),
                          capture_output=True, input=kw.get("stdin"))
    if done.returncode != 0:
        raise RuntimeError("git %s: %s" % (" ".join(args), done.stderr.decode()))
    return done.stdout


def commit(repo, name, text, message):
    with open(os.path.join(repo, name), "w") as out:
        out.write(text)
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", message)


def new_repo(remote=None):
    """A repository on a branch called feature, one commit ahead of main."""
    repo = fresh("repo")
    git(repo, "init", "-q")
    git(repo, "checkout", "-q", "-b", "main")
    commit(repo, "readme.txt", "one\n", "first")
    # origin/main follows main: the base a risk check screens against, with no remote to fetch.
    git(repo, "symbolic-ref", "refs/remotes/origin/main", "refs/heads/main")
    git(repo, "checkout", "-q", "-b", "feature")
    commit(repo, "export.txt", "export\n", "add the export")
    if remote:
        git(repo, "remote", "add", "origin", remote)
    return repo


# Ordinary text that only looks like a credential: each survives as evidence, a name, a summary,
# a refusal and a question.
LOOKALIKES = ["password_reset.py: 12 passed", "auth/token.py:40: unused import", "Token: 911", "token_count=12", "has_token=true",
              "secret-scanner: clean", "api_key_rotation: 0 failures", "Rotate the token: weekly", "Authorization: header is now checked"]
DIFF = ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-relative", "--src-prefix=a/", "--dst-prefix=b/",
        "--ignore-submodules=none", "--unified=3", "--no-renames", "--diff-algorithm=myers", "--inter-hunk-context=0"]


def facts(repo, base="main"):
    """What a step skill reports about the repository, computed the way the runner checks it."""
    diff = git(repo, *(DIFF + [base + "...HEAD", "--"]))
    patch = git(repo, "patch-id", "--verbatim", stdin=diff).decode().split()
    return {"head": git(repo, "rev-parse", "HEAD").decode().strip(),
            "tree": git(repo, "rev-parse", "HEAD^{tree}").decode().strip(),
            "patchId": patch[0] if patch else ""}


def canned(contract, repo=None, **change):
    """The passing answer for a contract, its result changed by `change` (a dotted key: value)."""
    text = FIX["outputs"][contract]
    for key, value in (facts(repo) if repo else {"head": "h", "tree": "t", "patchId": "p"}).items():
        text = text.replace("{%s}" % key, value)
    if change:
        head, _, block = text.partition("```json\n")
        result = json.loads(block.split("```")[0])
        for path, value in change.items():
            target = result
            keys = path.split(".")
            for key in keys[:-1]:
                target = target.setdefault(key, {})
            target[keys[-1]] = value
        text = head + "```json\n" + json.dumps(result) + "\n```\n"
    return text


class Driver:
    """Starts a run and answers its steps with the canned outputs."""

    def __init__(self, which="fixture", definition="build", edits=(), context=None, repo=None, session="s1", plain=False):
        self.root = roots(which)
        self.cache = fresh("cache")
        self.repo = None if plain else (repo or new_repo())
        self.cwd = self.repo or fresh("plain")
        self.session = session
        self.answers = []
        request = {"definition": edit(FIX["definitions"][definition], edits),
                   "context": dict(FIX["context"], cwd=self.cwd, **(context or {}))}
        self.result = self.call("start", request)
        self.answer = self.result[1]

    def call(self, command, request, session=None):
        result = cli(self.root, command, request, self.cache, cwd=self.cwd, session=session or self.session)
        if result[1] is not None:
            self.answers.append(result[1])
        return result

    def done(self, output=None, **change):
        step = self.answer["step"]
        if output is None:
            output = canned(step["contract"], self.repo, **change)
        self.result = self.call("done", {"item": "I123", "stepId": step["id"], "attempt": step["attempt"], "output": output})
        self.answer = self.result[1]
        return self.answer

    def done_by_hand(self, step_id, attempt, output=None):
        """Report a stopped step again, repaired by hand, with its passing answer."""
        contract = next(step["contract"] for phase in FIX["definitions"]["build"]["phases"] for step in phase["steps"] if step["id"] == step_id)
        self.result = self.call("done", {"item": "I123", "stepId": step_id, "attempt": attempt, "output": output or canned(contract, self.repo)})
        self.answer = self.result[1]
        return self.answer

    def next(self):
        self.result = self.call("next", {"item": "I123"})
        self.answer = self.result[1]
        return self.answer

    def until(self, step_id):
        """Answer steps until `step_id` is the one issued (or the run stops or ends)."""
        while self.answer and self.answer["action"] == "run" and self.answer["step"]["id"] != step_id:
            self.done()
        return self.answer

    def to_end(self):
        return self.until(None)

    def state(self, session=None, item="I123"):
        path = os.path.join(self.cache, "devstride-plugin", "workflows", "%s.%s.json" % (session or self.session, item))
        with open(path) as handle:
            return json.load(handle)

    def state_path(self, session=None, item="I123"):
        return os.path.join(self.cache, "devstride-plugin", "workflows", "%s.%s.json" % (session or self.session, item))

    def step_reports(self, answers=None):
        return [report for answer in (answers or self.answers) for call in answer.get("reports", []) for report in call.get("reports", [])]


def is_run(answer, step_id, attempt=None):
    return (answer is not None and answer.get("action") == "run" and answer["step"]["id"] == step_id
            and (attempt is None or answer["step"]["attempt"] == attempt))


def is_stopped(answer, kind, step_id=None):
    return (answer is not None and answer.get("action") == "stopped" and answer["kind"] == kind
            and (step_id is None or answer["stepId"] == step_id))


def closes(answer, outcome):
    calls = answer.get("reports", [])
    return bool(calls) and calls[-1].get("run", {}).get("outcome") == outcome


# --- sections ---------------------------------------------------------------------------------

def section_catalog():
    module = load()
    real = module.check_catalog(REAL_CATALOG)
    check("the shipped catalog is sound", real == [], real)
    check("the shipped catalog holds twelve contracts", len(REAL_CATALOG["contracts"]) == 12, list(REAL_CATALOG["contracts"]))
    check("no shipped contract carries satisfiedBy yet", not any("satisfiedBy" in entry for entry in REAL_CATALOG["contracts"].values()))
    standin = module.check_catalog(stand_in_catalog())
    check("the fixture catalog, where stand-in@1 satisfies build@1, is sound", standin == [], standin)

    def variant(case):
        catalog = copy.deepcopy(REAL_CATALOG if case["base"] == "real" else stand_in_catalog())
        for change in case["edits"]:
            if "copy" in change:
                source = catalog
                for key in change["copy"]:
                    source = source[key]
                path, value = change["to"], copy.deepcopy(source)
            else:
                path, value = change["set"], copy.deepcopy(change["value"])
            target = catalog
            for key in path[:-1]:
                target = target[key]
            target[path[-1]] = value
        return module.check_catalog(catalog)

    for case in FIX["catalogs"]["faults"]:
        faults = variant(case)
        check("catalog fault: %s -> %s" % (case["name"], case["expect"]),
              any(fault.startswith(case["expect"] + ": ") for fault in faults), faults)
    for case in FIX["catalogs"]["sound"]:
        faults = variant(case)
        check("catalog sound: %s" % case["name"], faults == [], faults)
    check("an empty catalog is refused", module.check_catalog({"schema": 1, "contracts": {}}) != [])
    check("a catalog of another schema is refused", module.check_catalog(dict(REAL_CATALOG, schema=2)) != [])
    # a plugin whose catalog is unsound runs nothing
    broken = copy.deepcopy(REAL_CATALOG)
    broken["contracts"]["sync@1"]["requires"] = ["deploy@1"]
    root = plugin_copy("plugin-broken", broken)
    rc, _, out, err = cli(root, "next", {}, fresh("cache"))
    check("an unsound catalog stops every command (exit 1, one line)", rc == 1 and out == "" and err.startswith("workflow: internal-error: ") and err.count("\n") == 1 and "Traceback" not in err, (rc, err))


def section_validation():
    seen = set()
    repo, plain = new_repo(), fresh("plain")
    for case in FIX["validation"]:
        root, cache = roots(case["root"]), fresh("cache")
        cwd = repo if case["git"] else plain

        def start(edits):
            request = {"definition": edit(FIX["definitions"][case["definition"]], edits), "context": dict(FIX["context"], cwd=cwd)}
            return cli(root, "start", request, cache, cwd=cwd)

        result = start(case["edits"])
        if case["expect"] == "ok":
            good = result[0] == 0 and result[1]["action"] == "run" and re.match(r"^[0-9a-f]{32}$", result[1]["runId"]) is not None
        else:
            seen.add(case["expect"])
            wrote = os.path.isdir(os.path.join(cache, "devstride-plugin", "workflows")) and os.listdir(os.path.join(cache, "devstride-plugin", "workflows"))
            good = refused(result, case["expect"]) and not wrote
            if good and "sameAsOriginal" in case:
                good = refused(start(case["sameAsOriginal"]), case["expect"])
        check("start: %s -> %s" % (case["name"], case["expect"]), good, (result[0], result[3].strip()))
    check("every validation code has a case", seen == set(CODES), sorted(set(CODES) ^ seen))
    # the refusal contract of the command line itself
    cache = fresh("cache")
    for label, command, raw in (("an unknown command", "explode", "{}"), ("no command", None, "{}"), ("a request that is not JSON", "next", "not json"),
                                ("a request that is a list", "next", "[]"), ("a session that is a path", "next", '{"session": "../x"}'),
                                ("an item that is not an item number", "next", '{"session": "s1", "item": "../../x"}'),
                                ("a run id that is not one", "next", '{"session": "s1", "runId": "zz"}'),
                                ("a clock that is not a time", "next", '{"session": "s1", "now": "noon"}')):
        check("refused: %s" % label, refused(cli(ROOT, command, None, cache, raw=raw), "bad-request"))
    check("refused: no run to continue", refused(cli(ROOT, "next", {}, cache), "no-run"))
    for label, request in (("both a definition and a file", {"definition": {}, "definitionFile": "x", "context": {}}),
                           ("neither a definition nor a file", {"context": {}}),
                           ("no context", {"definition": FIX["definitions"]["claim-only"]}),
                           ("a working directory that does not exist", {"definition": FIX["definitions"]["claim-only"], "context": dict(FIX["context"], cwd=os.path.join(WORK, "nowhere"))})):
        check("refused: start with %s" % label, refused(cli(roots("fixture"), "start", request, cache), "bad-request"))
    check("refused: a definition file that does not exist", refused(cli(roots("fixture"), "start", {"definitionFile": os.path.join(WORK, "none.json"), "context": FIX["context"]}, cache), "definition-unreadable"))
    big = os.path.join(WORK, "big.json")
    with open(big, "w") as out:
        out.write(json.dumps(dict(FIX["definitions"]["claim-only"], name="x" * (257 * 1024))))
    check("refused: a definition file over 256 KB", refused(cli(roots("fixture"), "start", {"definitionFile": big, "context": FIX["context"]}, cache), "definition-unreadable"))
    small = os.path.join(WORK, "claim-only.json")
    with open(small, "w") as out:
        json.dump(FIX["definitions"]["claim-only"], out)
    rc, answer, _, err = cli(roots("fixture"), "start", {"definitionFile": small, "context": FIX["context"]}, cache)
    check("a definition file is read", rc == 0 and is_run(answer, "claim", 1), err)
    context = dict(FIX["context"])
    del context["goal"]
    result = cli(roots("fixture"), "start", {"definition": FIX["definitions"]["build"], "context": dict(context, cwd=repo)}, fresh("cache"), cwd=repo)
    check("refused: a context that lacks what a step is handed", refused(result, "context-missing"), result[3])
    # the plugin as released starts its own shipped Build definition (the whole run: build-workflow-run.sh)
    rc, answer, _, err = cli(ROOT, "start", {"definitionFile": os.path.join(ROOT, "workflows", "build.json"), "context": dict(FIX["context"], cwd=repo)}, fresh("cache"), cwd=repo)
    check("the released plugin starts workflows/build.json at its claim step", rc == 0 and is_run(answer, "claim", 1), err)
    # a refusal never echoes what looks like a credential
    edits = [{"op": "set", "step": "sync", "path": ["run", "ref"], "value": "gh" + "p_abcdefghijklmnop"}]
    result = cli(roots("fixture"), "start", {"definition": edit(FIX["definitions"]["build"], edits), "context": dict(FIX["context"], cwd=repo)}, fresh("cache"), cwd=repo)
    check("a step skill named like a token is refused by where it is, never echoed",
          refused(result, "credential-in-definition") and "gh" + "p_abcdef" not in result[3] and "phases[3].steps[3].run.ref" in result[3], result[3])
    edits = [{"op": "top", "path": ["auth"], "value": {"password": "huntertwo"}}]
    result = cli(roots("fixture"), "start", {"definition": edit(FIX["definitions"]["build"], edits), "context": dict(FIX["context"], cwd=repo)}, fresh("cache"), cwd=repo)
    check("a credential-named key holding a credential-shaped value is refused, never echoed",
          refused(result, "credential-in-definition") and "huntertwo" not in result[3], result[3])
    for line in LOOKALIKES:
        edits = [{"op": "set", "step": "build", "path": ["name"], "value": line}, {"op": "set", "step": "review", "path": ["summary"], "value": line}]
        result = cli(roots("fixture"), "start", {"definition": edit(FIX["definitions"]["build"], edits), "context": dict(FIX["context"], cwd=repo)}, fresh("cache"), cwd=repo)
        check("a step name and summary that only look like a credential are run: %s" % line, result[0] == 0 and is_run(result[1], "claim", 1), result[3])
    for step_id in ("rotate-token", "client-secret", "reset-password"):
        edits = [{"op": "set", "step": "sync", "path": ["run", "ref"], "value": "no-such-skill"}, {"op": "set", "step": "sync", "path": ["id"], "value": step_id}]
        result = cli(roots("fixture"), "start", {"definition": edit(FIX["definitions"]["build"], edits), "context": dict(FIX["context"], cwd=repo)}, fresh("cache"), cwd=repo)
        check("a refusal naming the step %s is shown as it is" % step_id, refused(result, "skill-missing") and step_id in result[3] and "not shown" not in result[3], result[3])
    run = Driver(definition="claim-only", plain=True)
    result = run.call("done", {"item": "I123", "stepId": "token=abc123def", "attempt": 1, "output": "CLAIM: WON"})
    check("a refusal that would echo a credential from the request says so instead",
          refused(result, "not-current-step") and "abc123def" not in result[3] and result[3].endswith("so it is not shown\n"), result[3])


def section_verdicts():
    module = load()
    contracts = stand_in_catalog()["contracts"]
    covered = set()
    for case in FIX["verdicts"]:
        parsed = module.parse_verdict(contracts[case["contract"]], case["output"])
        if case["class"] is None:
            good, label = parsed is None, "no verdict: %s" % case["why"]
        else:
            good = parsed is not None and parsed[0]["value"] == case["value"] and parsed[0]["class"] == case["class"] and parsed[1] == case["detail"]
            label = "verdict: %s %s -> %s" % (case["contract"], case["value"], case["class"])
            covered.add((case["contract"], case["value"]))
        check(label, good, (case["output"], parsed))
    two = {"verdict": {"label": "CLAIM", "values": [{"value": "HELD", "detail": "optional", "class": "stop"},
                                                    {"value": "HELD BACK", "detail": "optional", "class": "continue"}]}}
    for values in (two["verdict"]["values"], list(reversed(two["verdict"]["values"]))):
        parsed = module.parse_verdict({"verdict": {"label": "CLAIM", "values": values}}, "CLAIM: HELD BACK for now\n")
        check("the longest listed value wins, whatever the order", parsed is not None and parsed[0]["value"] == "HELD BACK" and parsed[1] == "for now", parsed)
    every = set((name, value["value"]) for name, entry in REAL_CATALOG["contracts"].items() for value in entry["verdict"]["values"])
    check("every value of every contract has a verdict case", every <= covered, sorted(every - covered))


def section_proof_fixtures():
    module = load()
    contracts = REAL_CATALOG["contracts"]
    for case in FIX["proofs"]:
        answers = case["git"]

        def fake(cwd, *args, **options):
            if args[:2] == ("rev-parse", "c0^{tree}") and "tree" in answers:
                return answers["tree"].encode()
            if args[0] == "diff" and args[-2].endswith("...c0"):
                return ("diff " + args[-2][:-len("...c0")]).encode()
            if args[0] == "diff":  # a story binding's other head: keyed by the whole range
                return ("diff " + args[-2]).encode()
            if args[0] == "patch-id" and options.get("stdin", b"").decode()[5:] in answers.get("patchIds", {}):
                patch = answers["patchIds"][options["stdin"].decode()[5:]]
                return (patch + " 0000\n").encode() if patch else b""
            raise module.GitFailed("no answer")

        world = module.World(env={}, git=fake, uid=os.getuid())
        entry = contracts[case["contract"]]
        value = [v for v in entry["verdict"]["values"] if v["value"] == case["verdict"]][0] if "verdict" in case else None
        fault = module.proof_fault(case["contract"], entry, case["proof"], value, case.get("result"))
        if fault:
            got = "refused"
        else:
            try:
                got = "holds" if module.binding_holds(entry["proof"]["binding"], case["proof"], world, WORK, "c0") else "stale"
            except module.GitFailed:
                got = "unreadable"
        good = got == case["expect"] and ("rule" not in case or fault.startswith(case["rule"] + ": "))
        check("proof: %s -> %s" % (case["name"], case["expect"]), good, (got, fault))


def section_lifecycle():
    run = Driver()
    first = run.answer
    reports = first["reports"]
    check("start answers with the first step and the run's id", is_run(first, "claim", 1) and re.match(r"^[0-9a-f]{32}$", first["runId"]) is not None, first)
    module = load()
    check("the first report of a run carries the definition, and the run its hash",
          len(reports) == 1 and reports[0]["definition"] == FIX["definitions"]["build"]
          and first["definitionHash"] == module.REPORT.definition_hash(reports[0]["definition"]) == run.state()["definitionHash"], reports)
    check("the reports name the run, the session and the item", reports[0]["runId"] == first["runId"] and reports[0]["sessionId"] == "s1" and reports[0]["itemNumber"] == "I123" and "repository" not in reports[0], reports[0])
    again = run.next()
    check("asking twice returns the same step and attempt", is_run(again, "claim", 1) and again["payload"] == first["payload"], again)
    check("a later report carries no definition", all("definition" not in call for call in again["reports"]), again["reports"])
    seen, order = {}, []
    while run.answer["action"] == "run":
        answer = run.answer
        seen[answer["step"]["id"]] = answer
        order.append(answer["step"]["id"])
        run.done()
    final = run.answer
    wanted = ["claim", "start", "branch", "build", "risk-check", "local-checks", "review", "merge", "complete", "capture", "sync"]
    check("the eleven steps are issued in order, once each", order == wanted, order)
    check("the run finishes completed, with every step's result by contract",
          final["action"] == "finished" and final["outcome"] == "completed" and set(final["results"]) == set(REAL_CATALOG["contracts"]) - {"custom@1"}
          and final["results"]["sync@1"] == {"branch": "main", "clean": True}, final)
    check("the last report closes the run as completed", closes(final, "completed"), final["reports"])
    check("done says what it recorded", final["recorded"] == {"stepId": "sync", "attempt": 1, "verdict": "SYNC: CLEAN", "class": "continue", "status": "done"}, final["recorded"])
    keys_ok = all(list(answer["payload"])[-2:] == ["step", "contract"] and answer["payload"]["step"] == step_id
                  and answer["payload"]["contract"] == answer["step"]["contract"] for step_id, answer in seen.items())
    check("every payload ends with the reserved step and contract keys", keys_ok)
    check("a skill that takes text gets its template rendered",
          seen["branch"]["argument"] == "export-button base: main"
          and seen["build"]["argument"] == "I123 Add the export button profile: standard review-moment: release-deferred", (seen["branch"]["argument"], seen["build"]["argument"]))
    check("any other skill gets its payload as one compact JSON string",
          json.loads(seen["claim"]["argument"]) == seen["claim"]["payload"] and "\n" not in seen["claim"]["argument"] and ": " not in seen["claim"]["argument"], seen["claim"]["argument"])
    check("each step names its skill", seen["start"]["skill"] == {"source": "builtin", "ref": "story-lifecycle"} and seen["complete"]["skill"]["ref"] == "story-lifecycle" and seen["build"]["skill"]["ref"] == "ultracode-build")
    check("the heartbeat carries the claim phase and the ship-intent request",
          seen["build"]["heartbeat"] == {"phase": "Build", "stage": "building", "shipIntent": {"route": "epic-release", "unit": "I123", "branch": "feature", "target": "main", "stage": "building"}}
          and seen["claim"]["heartbeat"] == {"phase": None, "stage": None, "shipIntent": None}
          and seen["local-checks"]["heartbeat"]["phase"] == "Verify" and seen["merge"]["heartbeat"]["stage"] == "landing", seen["build"]["heartbeat"])
    declared = subprocess.run([sys.executable, "-B", os.path.join(ROOT, "skills/build-item/scripts/ship-intent.py"), "record"],
                              input=json.dumps(seen["build"]["heartbeat"]["shipIntent"]), capture_output=True, text=True)
    check("the ship-intent request is one the ship-intent helper takes as it is",
          declared.returncode == 0 and json.loads(declared.stdout)["payload"]["stage"] == "building" and json.loads(declared.stdout)["key"] == "I123", declared.stderr)
    check("a payload reads the context and earlier results",
          seen["risk-check"]["payload"]["build"]["untrackedDeferrals"] == ["tidy the export menu"] and seen["risk-check"]["payload"]["profile"] == "standard"
          and seen["local-checks"]["payload"]["branch"] == "feature" and seen["local-checks"]["payload"]["previousProof"] is None
          and seen["build"]["payload"]["answer"] is None and seen["complete"]["payload"]["releaseUnit"] == "I120"
          and seen["merge"]["payload"]["review"]["path"] == "fast-local", seen["risk-check"]["payload"])
    steps = run.step_reports()
    version = json.load(open(os.path.join(run.root, ".claude-plugin/plugin.json")))["version"]
    by_step = {}
    for report in steps:
        by_step.setdefault(report["stepId"], []).append(report)
    def digest(skill):
        return hashlib.sha256(open(os.path.join(run.root, "skills", skill, "SKILL.md"), "rb").read()).hexdigest()
    refs = dict((step_id, answer["skill"]["ref"]) for step_id, answer in seen.items())
    shaped = all(set(r["status"] for r in by_step[step_id]) == {"running", "done"}
                 and all(r["ran"] == {"source": "builtin", "ref": refs[step_id], "version": version, "hash": digest(refs[step_id])} for r in by_step[step_id])
                 for step_id in wanted)
    check("every step has a running and a finished report naming the skill, the version and the hash of its text", shaped, by_step.get("claim"))
    check("no report object holds more than four step reports", all(len(call.get("reports", [])) <= 4 for answer in run.answers for call in answer["reports"]))
    merge_done = [r for r in by_step["merge"] if r["status"] == "done"][0]
    check("a finished report carries the verdict, the evidence and the links",
          merge_done["verdict"] == "MERGE: LANDED main" and merge_done["links"] == {"commit": "https://example.com/commit/1"}
          and [r for r in by_step["build"] if r["status"] == "done"][0]["evidence"] == ["3 files changed", "12 tests pass"], merge_done)
    rc, status, _, _ = run.call("status", {"item": "I123"})
    check("status lists every step, with a ready table",
          rc == 0 and status["state"] == "finished" and status["position"] is None and len(status["rows"]) == 11 and status["reports"] == []
          and status["rows"][0] == {"stepId": "claim", "phase": "Pick up", "name": "Claim it", "status": "done", "verdict": "CLAIM: WON", "attempt": 1}
          and len(status["table"].split("\n")) == 13 and status["table"].startswith("| Phase | Step | Status | Verdict | Attempt |\n|---|"), status)
    before = open(run.state_path()).read()
    rc, status, _, _ = run.call("status", {"item": "I123", "includeDefinition": True})
    check("status with includeDefinition returns the definition once, and changes nothing",
          len(status["reports"]) == 1 and status["reports"][0]["definition"] == FIX["definitions"]["build"] and "reports" not in status["reports"][0]
          and open(run.state_path()).read() == before, status["reports"])
    check("a finished run takes no more answers", refused(run.call("done", {"item": "I123", "stepId": "sync", "attempt": 1, "output": "SYNC: CLEAN"}), "not-current-step"))
    check("a finished run stays finished", run.next()["action"] == "finished" and run.answer["reports"] == [])

    # a renamed step keeps its contract
    run = Driver(edits=[{"op": "set", "step": "review", "path": ["id"], "value": "second-opinion"}])
    answer = run.until("second-opinion")
    check("a renamed step id leaves the contract unchanged", is_run(answer, "second-opinion") and answer["payload"]["step"] == "second-opinion" and answer["payload"]["contract"] == "review@1", answer)
    answer = run.done(**{"proof.patchId": "3" * 40})
    check("... and the renamed step still owes its contract's proof", is_run(answer, "second-opinion", 2) and answer["recorded"]["status"] == "failed", answer)
    answer = run.done()
    commit(run.repo, "export.txt", "export\nchanged under the merge\n", "a late change")
    answer = run.done("MERGE: REFRESHED\n")
    check("... and is still required: the merge waits for the risk check, the checks and the renamed review again",
          is_run(answer, "risk-check", 2) and is_run(run.done(), "local-checks", 2) and is_run(run.done(), "second-opinion", 3), answer)

    # position while running
    run = Driver()
    run.until("build")
    rc, status, _, _ = run.call("status", {"item": "I123"})
    check("status says where a running run is", status["state"] == "running" and status["position"] == {"stepId": "build", "index": 4, "of": 11}
          and [row["status"] for row in status["rows"]][:5] == ["done", "done", "done", "issued", "pending"], status)
    check("an answer for another step is refused", refused(run.call("done", {"item": "I123", "stepId": "merge", "attempt": 1, "output": "MERGE: LANDED main"}), "not-current-step"))
    check("an answer for another attempt is refused", refused(run.call("done", {"item": "I123", "stepId": "build", "attempt": 2, "output": "BUILD: READY"}), "not-current-step"))
    check("an answer whose attempt is not a number is refused", refused(run.call("done", {"item": "I123", "stepId": "build", "attempt": True, "output": "BUILD: READY"}), "bad-request"))

    # HELD ends the run
    run = Driver()
    answer = run.done("CLAIM: HELD another session, since this morning\n")
    check("HELD ends the run as held and reports it interrupted",
          answer["action"] == "finished" and answer["outcome"] == "held" and closes(answer, "interrupted")
          and answer["recorded"]["class"] == "end:held" and run.state()["outcome"] == "held", answer)
    check("a held claim without its holder is no verdict", is_stopped(Driver().done("CLAIM: HELD\n"), "no-verdict", "claim"))

    # the claim is optional
    for output in ("CLAIM: NOT CONFIGURED\n", "CLAIM: DEGRADED the claims service timed out\n", "CLAIM: DEGRADED\n"):
        run = Driver()
        answer = run.done(output)
        report = run.step_reports([answer])[0]
        check("%s is skipped and the run goes on" % output.strip()[:21], is_run(answer, "start", 1) and answer["recorded"]["status"] == "skipped" and report["status"] == "skipped", answer)

    # NEEDS DECISION waits for a person
    run = Driver()
    run.until("build")
    answer = run.done("BUILD: NEEDS DECISION keep the old export format?\nthe spec does not say\n")
    report = run.step_reports([answer])[-1]
    check("NEEDS DECISION stops the run for a person, with a waiting report",
          is_stopped(answer, "needs-person", "build") and answer["reason"] == "keep the old export format?" and report["status"] == "waiting"
          and closes(answer, "interrupted") and answer["recorded"]["status"] == "waiting", answer)
    check("a stopped run stays stopped until it is resumed", is_stopped(run.next(), "needs-person") and run.answer["reports"] == [])
    rc, answer, _, _ = run.call("resume", {"item": "I123", "answer": "yes, keep it"})
    check("resume with an answer re-issues the step with the answer in its payload", is_run(answer, "build", 2) and answer["payload"]["answer"] == "yes, keep it", answer)
    check("the answer is still there when the step is asked for again", run.next()["payload"]["answer"] == "yes, keep it" and is_run(run.answer, "build", 2))
    answer = run.done()
    check("the answer is handed out for that attempt only", is_run(answer, "risk-check", 1) and run.state()["steps"]["build"]["answer"] is None, answer)
    check("an answer that is not text is refused", refused(run.call("resume", {"item": "I123", "answer": 7}), "bad-request"))

    # FAIL and BLOCKED stop
    run = Driver()
    run.until("build")
    answer = run.done("BUILD: BLOCKED the tests cannot be made to pass\n")
    check("BLOCKED stops the run as failed", is_stopped(answer, "failed", "build") and closes(answer, "failed") and answer["recorded"]["status"] == "failed"
          and answer["reason"] == "BUILD: BLOCKED the tests cannot be made to pass", answer)
    rc, answer, _, _ = run.call("resume", {"item": "I123"})
    check("resume re-issues the stopped step", is_run(answer, "build", 2), answer)
    run.answer = answer
    run.until("local-checks")
    answer = run.done("LOCAL CHECKS: FAIL unit\n3 tests failed\n")
    check("FAIL stops the run as failed", is_stopped(answer, "failed", "local-checks") and closes(answer, "failed"), answer)
    answer = run.call("done", {"item": "I123", "stepId": "local-checks", "attempt": 1, "output": canned("local-checks@1", run.repo)})[1]
    check("the step a run stopped on can be repaired by hand and reported", is_run(answer, "review", 1) and answer["recorded"]["status"] == "done", answer)

    # no verdict is never a pass
    for label, output in (("no verdict line", "Everything went fine.\n"), ("an empty answer", ""), ("the wrong label", "BUILD: READY\n"),
                          ("an unlisted value", "CLAIM: SURE\n"), ("a verdict below the first line", "Done.\nCLAIM: WON\n"), ("an answer that is not text", None)):
        run = Driver()
        if output is None:
            result = run.call("done", {"item": "I123", "stepId": "claim", "attempt": 1, "output": 7})
            answer = result[1]
        else:
            answer = run.done(output)
        check("%s stops the run with no-verdict" % label, is_stopped(answer, "no-verdict", "claim") and answer["recorded"]["status"] == "failed"
              and answer["recorded"]["class"] is None and run.state()["steps"]["claim"]["status"] == "failed" and closes(answer, "failed"), answer)
    kept = json.dumps(answer) + open(run.state_path()).read()
    run = Driver()
    answer = run.done("Everything went fine, the key is hidden-words-here.\n")
    check("the text of an answer with no verdict is not kept", "hidden-words-here" not in json.dumps(answer) + open(run.state_path()).read())
    run = Driver()
    run.until("build")
    answer = run.done("BUILD: BLOCKED " + "x" * 400 + "\n")
    check("a verdict longer than 200 characters is cut to 200", len(answer["recorded"]["verdict"]) == 200 and len(run.step_reports([answer])[-1]["verdict"]) == 200, len(answer["recorded"]["verdict"]))
    run = Driver()
    answer = run.done("CLAIM: WON\nclaimed\n")
    check("a continue verdict without its required result is a stop, never a pass", is_stopped(answer, "failed", "claim") and "state" in answer["reason"] and answer["recorded"]["status"] == "failed", answer)
    run = Driver()
    answer = run.done("CLAIM: WON\n```json\n{\"state\": 7}\n```\n")
    check("a required result key of the wrong type counts as missing", is_stopped(answer, "failed", "claim"), answer)
    run = Driver()
    answer = run.done("CLAIM: WON\n```json\n[1, 2]\n```\n")
    check("a result block that is not an object is a stop", is_stopped(answer, "failed", "claim"), answer)

    # a switched-off step is skipped, and a run with no item works by itself
    run = Driver(edits=[{"op": "set", "step": "claim", "path": ["run"], "value": OFF}], context={"item": None})
    check("a switched-off step is reported skipped and the next one issued",
          is_run(run.answer, "start", 1) and [(r["stepId"], r["status"]) for r in run.step_reports()] == [("claim", "skipped"), ("start", "running")]
          and "itemNumber" not in run.answer["reports"][0] and os.path.isfile(run.state_path(item="run")), run.answer)
    check("a session's only open run is found without naming it", is_run(run.call("next", {})[1], "start", 1))
    check("a run with no item declares no ship intent", run.call("next", {})[1]["heartbeat"]["shipIntent"] is None)


def section_proofs():
    # a wrong tree is a failed attempt, issued again
    run = Driver()
    run.until("local-checks")
    answer = run.done(**{"proof.tree": "0" * 40})
    check("a proof whose tree is not the real tree is recorded failed and the step issued again",
          is_run(answer, "local-checks", 2) and answer["recorded"]["status"] == "failed" and answer["recorded"]["verdict"] == "LOCAL CHECKS: PASS (2 ran)"
          and answer["payload"]["previousProof"]["tree"] == "0" * 40, answer)
    answer = run.done()
    check("a proof with the right tree passes", is_run(answer, "review", 1) and answer["recorded"]["status"] == "done", answer)

    # a new commit before the merge re-issues the risk check, for the delta, then the local checks
    commit(run.repo, "export.txt", "export\nmore\n", "a review fix")
    answer = run.done()
    check("after a new commit, the risk check is issued again before the merge, handed the proof it gave",
          is_run(answer, "risk-check", 2) and answer["recorded"] == {"stepId": "review", "attempt": 1, "verdict": "REVIEW: SETTLED", "class": "continue", "status": "done"}
          and answer["payload"]["previousProof"]["head"] != facts(run.repo)["head"], answer)
    answer = run.done()
    check("... then the local checks, the review keeping its own proof", is_run(answer, "local-checks", 3), answer)
    answer = run.done()
    check("then the merge, since the review was of the patch as it now is", is_run(answer, "merge", 1), answer)

    # REFRESHED: a base refresh that leaves the patch alone
    commit_on_main = lambda text: (git(run.repo, "checkout", "-q", "main"), commit(run.repo, "readme.txt", text, "base moves"), git(run.repo, "checkout", "-q", "feature"))
    commit_on_main("one\ntwo\n")
    before = facts(run.repo)
    git(run.repo, "rebase", "-q", "main")
    after = facts(run.repo)
    answer = run.done("MERGE: REFRESHED\n")
    check("(the refresh changed the tree and left the patch alone)", before["tree"] != after["tree"] and before["patchId"] == after["patchId"])
    check("REFRESHED: the local checks, gone stale, are issued again first; the risk check, of an unchanged story, is not",
          is_run(answer, "local-checks", 4) and answer["recorded"]["class"] == "redo:self" and run.state()["steps"]["risk-check"]["attempt"] == 2, answer)
    answer = run.done()
    check("after a base refresh that leaves the patch identical the review is not issued again; the merge is",
          is_run(answer, "merge", 2) and run.state()["steps"]["review"]["attempt"] == 1, answer)

    # a commit that changes the patch
    commit(run.repo, "export.txt", "export\nmore\nand more\n", "another fix")
    answer = run.done("MERGE: REFRESHED\n")
    check("after a commit that changes the patch: the risk check again", is_run(answer, "risk-check", 3), answer)
    answer = run.done()
    check("... then the local checks", is_run(answer, "local-checks", 5), answer)
    answer = run.done()
    check("... and then the review again", is_run(answer, "review", 2), answer)
    answer = run.done()
    check("... and only then the merge", is_run(answer, "merge", 3), answer)

    # after the merge nothing earlier is re-opened
    answer = run.done()
    commit(run.repo, "later.txt", "later\n", "work after the merge")
    check("after the merge finishes and the tree changes, the run goes on", is_run(answer, "complete", 1) and is_run(run.next(), "complete", 1), answer)
    final = run.to_end()
    attempts = dict((name, record["attempt"]) for name, record in run.state()["steps"].items())
    check("... and nothing before the merge is re-opened", final["action"] == "finished" and final["outcome"] == "completed"
          and attempts["local-checks"] == 5 and attempts["review"] == 2 and attempts["risk-check"] == 3, attempts)

    # supersession: the build completed again. No command of this release runs a finished step
    # again, so the test marks the build as issued in the state file, as a later loop would.
    def reissue(run, step_id):
        state = run.state()
        record = state["steps"][step_id]
        record.update(status="issued", attempt=record["attempt"] + 1)
        state["current"] = {"stepId": step_id, "attempt": record["attempt"]}
        with open(run.state_path(), "w") as out:
            json.dump(state, out)
        return run.next()

    run = Driver()
    run.until("merge")
    answer = reissue(run, "build")
    answer = run.done()
    check("a re-run of the build voids the risk check", is_run(answer, "risk-check", 2), answer)
    answer = run.done()
    check("... and the local checks", is_run(answer, "local-checks", 2), answer)
    answer = run.done()
    check("... and the review", is_run(answer, "review", 2), answer)
    check("... and then the merge is issued", is_run(run.done(), "merge"), run.answer)

    # the risk check's own rule
    run = Driver()
    run.until("risk-check")
    answer = run.done(**{"proof.triggers": ["auth"], "proof.verifiers": 0})
    check("a risk check with triggers and no verifier is refused", is_stopped(answer, "proof", "risk-check") and "risk-triggers-need-verifiers" in answer["reason"]
          and answer["recorded"]["status"] == "failed" and closes(answer, "failed"), answer)
    run = Driver()
    run.until("risk-check")
    block = json.loads(canned("risk-check@1", run.repo).split("```json\n")[1].split("```")[0])
    del block["proof"]
    answer = run.done("RISK CHECK: CLEAR\n```json\n%s\n```\n" % json.dumps(block))
    check("a risk check with no proof is refused", is_stopped(answer, "proof", "risk-check"), answer)
    run = Driver()
    run.until("risk-check")
    check("a risk check with triggers and a verifier passes", is_run(run.done(**{"proof.triggers": ["auth"], "proof.verifiers": 2}), "local-checks", 1))

    # nothing configured locally: only a pull-request review lets the merge go
    for path, allowed in (("fast-local", False), ("pull-request", True)):
        run = Driver()
        run.until("local-checks")
        block = json.loads(canned("local-checks@1", run.repo, **{"proof.kind": "none-configured"}).split("```json\n")[1].split("```")[0])
        run.done("LOCAL CHECKS: NOT CONFIGURED\n```json\n%s\n```\n" % json.dumps(block))
        answer = run.done(**{"proof.path": path, "path": path})
        if allowed:
            check("local checks that found nothing configured are accepted by the merge after a pull-request review", is_run(answer, "merge", 1), answer)
        else:
            check("local checks that found nothing configured are refused by the merge after any other review",
                  is_stopped(answer, "proof", "merge") and "none-configured-needs-pull-request-route" in answer["reason"], answer)
            rc, answer, _, _ = run.call("resume", {"item": "I123"})
            check("... and a resume does not get past it", is_stopped(answer, "proof", "merge"), answer)
            check("... nor does an answer for the merge", refused(run.call("done", {"item": "I123", "stepId": "merge", "attempt": 0, "output": "MERGE: LANDED main"}), "not-current-step")
                  and refused(run.call("done", {"item": "I123", "stepId": "merge", "attempt": 1, "output": "MERGE: LANDED main"}), "not-current-step"))

    # ... also when the merge had been issued before the local checks came back with nothing configured
    run = Driver()
    run.until("merge")
    commit(run.repo, "export.txt", "export\nrefreshed\n", "a refresh")
    check("(the changed story is screened again first)", is_run(run.done("MERGE: REFRESHED\n"), "risk-check", 2), run.answer)
    run.done()
    block = json.loads(canned("local-checks@1", run.repo, **{"proof.kind": "none-configured"}).split("```json\n")[1].split("```")[0])
    answer = run.done("LOCAL CHECKS: NOT CONFIGURED\n```json\n%s\n```\n" % json.dumps(block))
    check("(the review is issued again for the changed patch)", is_run(answer, "review", 2), answer)
    answer = run.done()
    check("the merge rule holds for a merge that was issued once already", is_stopped(answer, "proof", "merge"), answer)
    answer = run.call("done", {"item": "I123", "stepId": "merge", "attempt": 1, "output": canned("merge@1", run.repo)})[1]
    check("... and a merge reported by hand does not get past it", is_stopped(answer, "proof", "merge") and answer["recorded"]["status"] == "failed" and run.state()["outcome"] is None, answer)

    # the cap on the runner's own re-issues
    run = Driver()
    run.until("local-checks")
    for attempt in range(1, 5):
        answer = run.done(**{"proof.tree": "1" * 40})
        check("a mismatched proof: automatic re-issue %d" % attempt, is_run(answer, "local-checks", attempt + 1), answer)
    answer = run.done(**{"proof.tree": "1" * 40})
    check("the fifth automatic re-issue stops the run instead", is_stopped(answer, "attempts-exhausted", "local-checks") and closes(answer, "failed"), answer)
    rc, answer, _, _ = run.call("resume", {"item": "I123"})
    check("... and a resume continues it", is_run(answer, "local-checks", 6), answer)
    run.answer = answer
    check("... to the next step once the proof is right", is_run(run.done(), "review", 1))

    # a review proof that names another patch
    answer = run.done(**{"proof.patchId": "2" * 40})
    check("a review proof whose patch id is not the real one is recorded failed and issued again", is_run(answer, "review", 2) and answer["recorded"]["status"] == "failed", answer)
    answer = run.done(**{"proof.base": "--output=leak"})
    check("a review proof whose base is not a git name cannot be checked, and stops the run", is_stopped(answer, "proof", "review") and not os.path.exists(os.path.join(run.repo, "leak")), answer)

    # an issued step is handed back as it was: it may already have acted
    landed = lambda head: FIX["outputs"]["merge@1"].replace("{head}", head)
    for how in ("the checkout switched to the base", "the base ref moved to include it"):
        run = Driver()
        run.until("merge")
        issued = facts(run.repo)["head"]
        if how.startswith("the checkout"):
            git(run.repo, "checkout", "-q", "main")
            git(run.repo, "merge", "-q", "--no-ff", "-m", "merge the feature", "feature")
            git(run.repo, "branch", "-q", "-D", "feature")
        else:
            git(run.repo, "branch", "-f", "main", "feature")
        rc, answer, _, _ = run.call("resume", {"item": "I123"})
        check("resume after a merge landed (%s) hands the merge back unchanged" % how,
              is_run(answer, "merge", 1) and answer["payload"]["commit"] == issued, answer)
        run.answer = answer
        answer = run.done(landed(issued))
        check("... and its LANDED naming the commit it was handed is accepted", is_run(answer, "complete", 1)
              and answer["recorded"]["status"] == "done" and run.state()["steps"]["merge"]["result"]["sha"] != issued, answer)
        check("... and the run ends", run.to_end()["action"] == "finished" and run.answer["outcome"] == "completed", run.answer)
    run = Driver()
    run.until("merge")
    commit(run.repo, "export.txt", "export\nchanged after the merge was issued\n", "a late change")
    check("next hands an issued merge back as it was, with the full commit it is to merge",
          is_run(run.next(), "merge", 1) and run.answer["payload"]["commit"] == run.state()["steps"]["merge"]["issuedHead"]
          and len(run.answer["payload"]["commit"]) == 40, run.answer)
    answer = run.done(landed(facts(run.repo)["head"]))
    check("... and a LANDED naming any other commit stops the run, showing the full commit it expected",
          is_stopped(answer, "proof", "merge") and run.state()["steps"]["merge"]["issuedHead"] in answer["reason"], answer)
    # a review that committed its own fixes, then a compaction
    run = Driver()
    run.until("review")
    commit(run.repo, "export.txt", "export fixed\n", "a review fix")
    rc, answer, _, _ = run.call("resume", {"item": "I123"})
    check("resume during a review that committed fixes hands the review back", is_run(answer, "review", 1), answer)
    run.answer = answer
    answer = run.done()
    check("... its answer is accepted, and the risk check, then the local checks are issued again for the new commit",
          is_run(answer, "risk-check", 2) and answer["recorded"]["status"] == "done" and is_run(run.done(), "local-checks", 2), answer)
    check("... then the merge, without a second review", is_run(run.done(), "merge", 1) and run.state()["steps"]["review"]["attempt"] == 1, run.answer)

    # a merge reported landed names the commit the checks and the review were proven on
    run = Driver()
    run.until("merge")
    commit(run.repo, "unreviewed.txt", "unreviewed\n", "an unreviewed change")
    answer = run.done()
    check("a merge that landed a commit added after it was issued stops the run",
          is_stopped(answer, "proof", "merge") and "merge-lands-what-was-checked" in answer["reason"] and answer["recorded"]["status"] == "failed", answer)
    issued = run.state()["steps"]["merge"]["issuedHead"]
    rc, answer, _, _ = run.call("resume", {"item": "I123"})
    check("... and resume answers with that stop, naming the commit the merge was handed, until told it did not land",
          is_stopped(answer, "proof", "merge") and answer.get("mayHaveLanded") is True and answer.get("commit") == issued
          and answer.get("attempt") == 1 and run.state()["stopped"] is not None, answer)
    rc, answer, _, _ = run.call("resume", {"item": "I123", "landed": False})
    check("... then, told it did not land, screens and checks the new commit first", is_run(answer, "risk-check", 2), answer)
    for bad_value in ({"landed": True}, {"landed": "no"}, {"close": False}):
        rc, answer, _, err = run.call("resume", dict({"item": "I123"}, **bad_value))
        check("resume refuses %s: landed is only ever false, close only ever true" % json.dumps(bad_value), rc == 2 and "bad-request" in err, err)
    run = Driver()
    run.until("merge")
    answer = run.done(output="MERGE: BLOCKED conflicts\n")
    commit(run.repo, "fixed.txt", "conflict fixed by hand\n", "a hand fix")
    answer = run.call("done", {"item": "I123", "stepId": "merge", "attempt": 1, "output": canned("merge@1", run.repo)})[1]
    check("a merge repaired by hand after a block, over a new commit, stops the run", is_stopped(answer, "proof", "merge") and "merge-lands-what-was-checked" in answer["reason"], answer)
    run = Driver()
    run.until("merge")
    block = json.loads(canned("merge@1", run.repo).split("```json\n")[1].split("```")[0])
    del block["proof"]
    answer = run.done("MERGE: LANDED main\n```json\n%s\n```\n" % json.dumps(block))
    check("a merge that does not name what it merged stops the run", is_stopped(answer, "proof", "merge") and "proof" in answer["reason"], answer)

    # every byte of the patch counts, white space too
    run = Driver()
    commit(run.repo, "auth.py", "def allowed(user):\n    if user.admin:\n        audit(user)\n        return True\n    return False\n", "auth")
    run.until("merge")
    stable = lambda: git(run.repo, "patch-id", "--stable", stdin=git(run.repo, *(DIFF + ["main...HEAD", "--"]))).split()[0]
    before = (facts(run.repo)["patchId"], stable())
    commit(run.repo, "auth.py", "def allowed(user):\n    if user.admin:\n        audit(user)\n    return True\n    return False\n", "an indentation change")
    check("(an indentation change keeps the stable patch id and changes the verbatim one)",
          facts(run.repo)["patchId"] != before[0] and stable() == before[1], before)
    answer = run.done("MERGE: REFRESHED\n")
    check("a change of indentation alone: the risk check and the local checks again",
          is_run(answer, "risk-check", 2) and is_run(run.done(), "local-checks", 2), answer)
    check("... and the review again, never straight to the merge", is_run(run.done(), "review", 2), run.answer)

    # git settings neither break the patch id nor run anything
    repo = new_repo()
    git(repo, "checkout", "-q", "main")
    commit(repo, "notes.txt", "".join("note %d\n" % n for n in range(12)), "notes")
    commit(repo, "spread.txt", "".join("line %d\n" % n for n in range(20)), "two changes, close together")
    os.makedirs(os.path.join(repo, "vendor"))  # a submodule that is not checked out: a pointer only, no network
    git(repo, "update-index", "--add", "--cacheinfo", "160000,%s,vendor" % ("1" * 40))
    git(repo, "commit", "-q", "-m", "a submodule")
    git(repo, "checkout", "-q", "feature")
    git(repo, "rebase", "-q", "main")
    git(repo, "mv", "notes.txt", "moved.txt")
    commit(repo, "readme.txt", "one\ntwo\nthree\nfour\n", "a rename and a change with context")
    commit(repo, "spread.txt", "".join("line %d%s\n" % (n, " changed" if n in (2, 11) else "") for n in range(20)), "two hunks close together")
    git(repo, "update-index", "--cacheinfo", "160000,%s,vendor" % ("2" * 40))
    git(repo, "commit", "-q", "-m", "the submodule moves")
    check("(the fixture's two close hunks are joined by diff.interHunkContext=10)",
          git(repo, *(DIFF + ["main...HEAD", "--"])).count(b"\n@@ ") > git(repo, "-c", "diff.interHunkContext=10", *(DIFF[:-1] + ["main...HEAD", "--"])).count(b"\n@@ "))
    check("(the fixture changes a submodule, which diff.ignoreSubmodules=all would hide)",
          b"Subproject commit" in git(repo, *(DIFF + ["main...HEAD", "--"]))
          and b"Subproject commit" not in git(repo, "-c", "diff.ignoreSubmodules=all", "diff", "main...HEAD"))
    run = Driver(repo=repo)
    run.until("review")
    hook = os.path.join(WORK, "ext-diff-ran")
    settings = {"color.diff": "always", "color.ui": "always", "diff.noprefix": "true", "diff.mnemonicPrefix": "true", "diff.relative": "true",
                "diff.external": "touch %s; false" % hook, "diff.wsErrorHighlight": "all", "core.pager": "cat", "diff.ignoreSubmodules": "all",
                "diff.context": "0", "diff.renames": "copies", "diff.algorithm": "patience", "diff.interHunkContext": "10"}
    env = dict(os.environ, GIT_CONFIG_COUNT=str(len(settings)))
    for n, (key, value) in enumerate(settings.items()):
        env["GIT_CONFIG_KEY_%d" % n], env["GIT_CONFIG_VALUE_%d" % n] = key, value
    plain = subprocess.run(["git", "-C", run.repo, "diff", "--no-ext-diff", "main...HEAD"], capture_output=True, env=env).stdout
    plain = subprocess.run(["git", "-C", run.repo, "patch-id", "--verbatim"], input=plain, capture_output=True, env=env).stdout.split()
    check("(these settings change a diff made without the fixed flags)", plain[:1] != [facts(run.repo)["patchId"].encode()], plain)
    output = canned("review@1", run.repo)
    done = subprocess.run([sys.executable, "-B", os.path.join(run.root, RUNNER), "done"], capture_output=True, text=True, cwd=run.cwd,
                          input=json.dumps({"session": "s1", "item": "I123", "stepId": "review", "attempt": 1, "output": output}),
                          env=dict(env, XDG_CACHE_HOME=run.cache))
    answer = json.loads(done.stdout) if done.returncode == 0 else done.stderr
    check("colour, prefix, external-diff, context, rename, algorithm and submodule settings leave the patch id as it is", is_run(answer, "merge", 1), answer)
    check("... and no external diff program runs", not os.path.exists(hook))

    # a count is a whole number of at least 0
    run = Driver()
    run.until("risk-check")
    block = json.loads(canned("risk-check@1", run.repo).split("```json\n")[1].split("```")[0])
    text = json.dumps(block).replace('"verifiers": 0', '"verifiers": NaN').replace('"triggers": []', '"triggers": ["auth"]')
    answer = run.done("RISK CHECK: CLEAR\n```json\n%s\n```\n" % text)
    check("a risk check whose verifier count is not a number (NaN) is refused", is_stopped(answer, "proof", "risk-check"), answer)
    run = Driver()
    run.until("risk-check")
    answer = run.done(**{"proof.triggers": ["auth"], "proof.verifiers": -2})
    check("... and a negative one", is_stopped(answer, "proof", "risk-check"), answer)

    # the verdict, not a free-text field, says whether anything is configured
    for label, verdict, kind in (("NOT CONFIGURED with a receipt", "LOCAL CHECKS: NOT CONFIGURED", "receipt"),
                                 ("a pass that says nothing is configured", "LOCAL CHECKS: PASS (2 ran)", "none-configured"),
                                 ("a kind the catalog does not list", "LOCAL CHECKS: NOT CONFIGURED", "not-configured")):
        run = Driver()
        run.until("local-checks")
        answer = run.done(canned("local-checks@1", run.repo, **{"proof.kind": kind}).replace("LOCAL CHECKS: PASS (2 ran)", verdict))
        check("local checks: %s is refused, never passed" % label, is_stopped(answer, "proof", "local-checks") and answer["recorded"]["status"] == "failed", answer)
    for label, change in (("ran no command", {"commands": [], "results": []}), ("carries no receipt", {"receipt": None, "proof.receipt": None}),
                          ("carries a blank receipt", {"receipt": "  ", "proof.receipt": "  "}), ("names a blank command", {"commands": ["unit", " "]}),
                          ("names a command that is not text", {"commands": [7]})):
        run = Driver()
        run.until("local-checks")
        answer = run.done(**change)
        check("local checks: a PASS that %s is refused, never passed" % label, is_stopped(answer, "proof", "local-checks") and answer["recorded"]["status"] == "failed", answer)
    run = Driver()
    run.until("review")
    answer = run.done(**{"proof.path": "pull-request-ish"})
    check("a review proof whose path the catalog does not list is refused", is_stopped(answer, "proof", "review"), answer)

    # healthy refreshes never use up the runner's own re-issues
    run = Driver()
    run.until("merge")
    for n in range(1, 8):
        git(run.repo, "checkout", "-q", "main")
        commit(run.repo, "base-%d.txt" % n, "x\n", "the base moves %d" % n)
        git(run.repo, "checkout", "-q", "feature")
        git(run.repo, "rebase", "-q", "main")
        if not is_run(run.done("MERGE: REFRESHED\n"), "local-checks") or not is_run(run.done(), "merge"):
            break
    check("seven base refreshes in a row each re-check the local checks and come back to the merge", n == 7 and is_run(run.answer, "merge", 8)
          and run.state()["steps"]["local-checks"]["autoRedo"] == 0 and run.state()["steps"]["review"]["attempt"] == 1, (n, run.answer))

    # a repository that disappears under a run
    run = Driver()
    run.until("review")
    output = canned("review@1", run.repo)
    shutil.move(os.path.join(run.repo, ".git"), os.path.join(run.repo, "gone"))
    answer = run.done(output)
    check("a proof that can no longer be checked is never accepted", is_stopped(answer, "proof"), answer)


def section_stand_in():
    edits = [{"op": "remove", "step": "build"}, {"op": "add", "after": "branch", "value": [c for c in FIX["validation"] if c["name"] == "stand-in: in place of the build"][0]["edits"][1]["value"]}]
    run = Driver("standIn", edits=edits)
    answer = run.until("risk-check")
    check("the risk check's payload reads the build's result from the stand-in", is_run(answer, "risk-check", 1) and answer["payload"]["build"]["scopeLine"] == "stood in", answer)
    run.until("merge")
    state = run.state()
    record = state["steps"]["stand-in"]
    record.update(status="issued", attempt=2)
    state["current"] = {"stepId": "stand-in", "attempt": 2}
    with open(run.state_path(), "w") as out:
        json.dump(state, out)
    run.next()
    answer = run.done()
    check("completing the stand-in again voids the risk check, which is issued again", is_run(answer, "risk-check", 2), answer)
    both = [{"op": "add", "after": "build", "value": edits[1]["value"]}]
    run = Driver("standIn", edits=both)
    answer = run.until("risk-check")
    check("with both in the workflow the nearest earlier one provides", answer["payload"]["build"]["scopeLine"] == "stood in", answer["payload"]["build"])


def section_evidence():
    module = load()

    def claim(output):
        run = Driver(definition="claim-only", plain=True)
        answer = run.done(output)
        text = json.dumps(answer) + open(run.state_path()).read()
        reports = run.step_reports([answer])
        return run, answer, text, (reports[-1] if reports else {})

    result = '```json\n{"state": "won"}\n```\n'
    run, answer, text, report = claim("CLAIM: WON\n" + "".join("line %04d %s\n" % (n, "e" * 300) for n in range(60)) + result)
    evidence = report["evidence"]
    check("evidence over 8 KB is cut, and the last line says so",
          sum(len(line.encode()) for line in evidence) <= 8192 and evidence[-1] == module.REPORT.EVIDENCE_DROPPED and evidence[0].startswith("line 0000")
          and run.state()["steps"]["claim"]["evidence"] == evidence, len(evidence))
    secrets = ["holder CLAIM_HOLDER=abc", "Authorization: Bearer abc.def-ghi.jkl-mno", "gh" + "p_example", "gh" + "o_example", "githu" + "b_pat_example",
               "key AK" + "IAEXAMPLEONLY12", "xo" + "xb-example", "xo" + "xp-example", "-----BE" + "GIN EXAMPLE KEY-----", "password=hunter2", "API_TOKEN = abcdefgh",
               "client_secret=abcdefgh", '{"password": "hunter2"}', "token: abc123def"]
    for line in secrets:
        run, answer, text, report = claim("CLAIM: WON\nbefore\n%s\nafter\n%s" % (line, result))
        check("an evidence line with a secret marker is dropped whole: %s" % line.split("=")[0].split(" ")[-1][:14],
              report["evidence"] == ["before", "after"] and line not in text, report.get("evidence"))
    run, answer, text, report = claim("CLAIM: WON\nthe token rotation is documented\npassword= \n" + result)
    check("a line that only mentions a secret word is kept", report["evidence"] == ["the token rotation is documented", "password="], report.get("evidence"))
    run, answer, text, report = claim("CLAIM: WON\nbell\x07 and escape\x1b[31m here\n" + result)
    check("control characters are stripped", report["evidence"] == ["bell and escape [31m here"] and "\\u0007" not in text and "\\u001b" not in text, report.get("evidence"))
    run, answer, text, report = claim("CLAIM: HELD the holder is CLAIM_HOLDER=abc123\n")
    check("a verdict detail that holds a secret marker is withheld", answer["recorded"]["verdict"] == "CLAIM: HELD [withheld]" and "abc123" not in text, answer["recorded"])
    run = Driver()
    run.until("build")
    answer = run.done("BUILD: NEEDS DECISION use token=abc123def or not?\n")
    check("a question that holds a secret marker is withheld too", answer["reason"] == "[withheld]" and "abc123def" not in json.dumps(answer) + open(run.state_path()).read(), answer)
    run, answer, text, report = claim('CLAIM: WON\n```json\n{"state": "won", "padding": "%s"}\n```\n' % ("p" * 17000))
    check("a result over 16 KB is refused", is_stopped(answer, "failed", "claim") and "16 KB" in answer["reason"] and run.state()["steps"]["claim"]["result"] == {}, answer)
    run, answer, text, report = claim('CLAIM: WON\n```json\n{"state": "won", "heldBy": 7, "holderToken": "tok-123", "since": "today"}\n```\nand the transcript went on: tail-text\n')
    check("an unknown result key, and an optional one of the wrong type, are dropped", run.state()["steps"]["claim"]["result"] == {"state": "won", "since": "today"} and "tok-123" not in text, run.state()["steps"]["claim"]["result"])
    check("nothing after the result block is kept", "tail-text" not in text)
    links = {"pullRequest": "http://example.com/pull/1", "commit": "https://example.com/commit/1", "comment": "javascript:alert(1)", "other": "https://example.com/x"}
    run, answer, text, report = claim('CLAIM: WON\n```json\n%s\n```\n' % json.dumps({"state": "won", "links": links}))
    check("a link that is not an https address is dropped", report["links"] == {"commit": "https://example.com/commit/1"} and "alert" not in text and "http://example.com" not in text, report.get("links"))
    run, answer, text, report = claim('CLAIM: WON\n```json\n%s\n```\n' % json.dumps({"state": "won", "links": {"commit": "https://example.com/" + "c" * 500}}))
    check("a link over 500 characters is dropped", "links" not in report, report.get("links"))
    run, answer, text, report = claim('CLAIM: WON\n```json\n%s\n```\n' % json.dumps({"state": "won", "links": {"branch": "feature/gh" + "p_example", "commit": "https://example.com/c?token=abc123def"}}))
    check("a link or branch name that holds a secret marker is dropped", "links" not in report and "gh" + "p_example" not in text and "token=abc123def" not in text, report.get("links"))
    # a web token signed RS256 with a key id: its header is 94 characters
    header = base64.urlsafe_b64encode(b'{"alg":"RS256","kid":"0123456789abcdef0123456789abcdef01","typ":"JWT"}').decode().rstrip("=")
    RS256 = header + ".e" + "yJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
    check("(the web token's header is 94 characters)", len(header) == 94, len(header))
    shapes = ["GOLDEN_DB_CONNECTION_STRING=postgresql://owner:pw-123@db.example.com/db", "aws_secret_access_key = wJalrXUtnFEMIEXAMPLEKEY",
              "authorization: bearer e" + "yJhbGciOiJIUzI1NiJ9.e" + "yJzdWIiOiIxIn0.sig", "AUTHORIZATION:   Basic dXNlcjpodW50ZXIy",
              "STRIPE_SECRET_KEY sk_l" + "ive_51Habcdefghijklmnop", "api_key=sk-" + "ant-api03-abcdefghijklmnop", "apikey: abcdefgh", "private_key=abcdefgh",
              "glp" + "at-abcdefghijklmnop0123", "the key s" + "k-proj-abcdefghijklmnopqrstu", "AWS_ACCESS_KEY_ID=AK" + "IAEXAMPLEONLY",
              "a token e" + "yJabcdefg.e" + "yJhijklmn.sig9 in the log", "Bearer abcd1234efgh5678", "passwd=x1y2z3w4", "https://user:pw@example.com/x",
              "secretKey=abcd1234efgh", "password: hunter2hunter", "bearer \t ABCDEFGHIJKLMNOPQRST", "AS" + "IAABCDEFGHIJKLMNOP",
              "np" + "m_abcdefghijklmnopqrstuvwxyz0123456789", "AI" + "zaSyA1234567890abcdefghijklmnopqrstu", "whs" + "ec_abcdefgh",
              "S" + "G.abcdefghijklmn.opqrstuvwxyz", "X-Api-Key: abc", "--password hunter2", "--token abcdef123", "client_secret hunter2",
              "Authorization: ApiKey abcdefghijklmnopqrstuvwxyz012345", "Authorization: Token " + "0123456789abcdef" * 2 + "01234567",
              "Authorization: Bot abcdefghijklmnopqrstu", "Authorization: SSWS 00abcdefghijklmnopqrstuvwx", "Authorization: abcdefghijklmnopqrstu",
              "db.password=huntertwo", "spring.datasource.password: huntertwo",
              "credential_for_production_region_production_region_production_region_password=huntertwo",
              "Authorization: Api-Key abcdefghijklmnopqrstuvwx", "redis://:pw@cache.example.com",
              RS256, "jwt=" + RS256, "the cookie was " + RS256 + " ok"]
    ordinary = ["3 files changed", "unit: 12 passed", "lint: clean", "tokens: 911 used", "the token rotation is documented",
                "secretary: Jane", "clone ssh://git@github.com/example/widgets", "git@github.com:example/widgets.git", "the Authorization header is checked",
                "a bearer of good news", "task-runner: done", "the password reset flow works", "https://example.com/commit/1", "main...HEAD",
                "eyJmb28iOiJiYXIifQ.json"] + LOOKALIKES
    run, answer, text, report = claim("CLAIM: WON\n%s\n%s" % ("\n".join(shapes + ordinary), result))
    check("credentials of every common shape are dropped, case and spacing aside", not any(line in text for line in shapes), [l for l in shapes if l in text])
    check("... and ordinary evidence lines survive", report["evidence"] == ordinary, report.get("evidence"))
    # a line holding a provider's token prefix is stored as parts cut inside the prefix, joined here
    corpus = dict((key, ["".join(line) if isinstance(line, list) else line for line in FIX["credentials"][key]]) for key in ("caught", "kept"))
    missed = [line for line in corpus["caught"] if not module.has_secret(line)]
    check("every line of the credential corpus that must be caught is (%d)" % len(corpus["caught"]), not missed and len(corpus["caught"]) == 125, missed)
    shown = [line for line in corpus["kept"] if module.has_secret(line)]
    check("... and every ordinary line in it is kept (%d)" % len(corpus["kept"]), not shown and len(corpus["kept"]) == 64, shown)
    step = module.SCAN_WINDOW - module.SCAN_OVERLAP
    for secret in ("password=huntertwo", RS256, "https://owner:huntertwo@example.com/db"):
        lost = [at for at in range(step - len(secret) - 8, module.SCAN_WINDOW + 8)
                if not module.has_secret(" " * at + secret + " " * (2 * module.SCAN_WINDOW - at))]
        check("a credential at every offset across a window boundary is caught (%s...)" % secret[:12], not lost, lost[:5])
    families = {"authorization= then /a.b": lambda n: "authorization=" * (n // 14) + "/a.b",
                "authorization=a/ then a.b": lambda n: "authorization=a/" * (n // 16) + "a.b",
                "token": lambda n: "token" * (n // 5), "a.": lambda n: "a." * (n // 2), "SG.": lambda n: "SG." * (n // 3),
                "eyJa.": lambda n: "eyJa." * (n // 5), "eyJ": lambda n: "eyJ" * (n // 3), "eyJ-": lambda n: "eyJ-" * (n // 4),
                "eyJa then a dot": lambda n: "eyJa" * (n // 4) + ".", "password=": lambda n: "password=" * (n // 9),
                "bearer": lambda n: "bearer " * (n // 7), "a scheme run": lambda n: "a" * n + "://",
                "a://": lambda n: "a://" * (n // 4), "a long key": lambda n: ("k" * 70 + "_password=") * (n // 80),
                "dots then a key": lambda n: "x." * (n // 2) + "password=huntertwo", "a=": lambda n: "a=" * (n // 2),
                "a:b:": lambda n: "a:b:" * (n // 4), "authorization: and spaces": lambda n: "authorization:" + " " * n}
    for name, build in families.items():
        for size in (100000, 400000):
            line = build(size)
            began = time.time()
            module.has_secret(line)
            took = time.time() - began
            check("a %d KB line built to be slow is scanned in under a second (%s)" % (size // 1000, name), took < 1.0, took)
    for line in LOOKALIKES:
        run = Driver()
        run.until("build")
        answer = run.done("BUILD: NEEDS DECISION %s\n" % line)
        check("a question that only looks like a credential is shown: %s" % line, answer["reason"] == line, answer)
    run = Driver()
    run.until("build")
    answer = run.done("BUILD: NEEDS DECISION use Authorization: Bearer abc123def456ghi789?\n")
    check("a question with an Authorization header is withheld", answer["reason"] == "[withheld]" and "abc123def456" not in json.dumps(answer) + open(run.state_path()).read(), answer)


def section_state():
    module = load()
    run = Driver(definition="claim-only", plain=True)
    folder = os.path.dirname(run.state_path())
    check("the state file is owner-only, in an owner-only folder",
          stat.S_IMODE(os.stat(run.state_path()).st_mode) == 0o600 and stat.S_IMODE(os.stat(folder).st_mode) == 0o700 and os.listdir(folder) == ["s1.I123.json"], os.listdir(folder))
    state = run.state()
    check("the state file holds the run as specified",
          state["stateVersion"] == 1 and state["sessionId"] == "s1" and state["item"] == "I123" and state["outcome"] is None and state["endedAt"] is None
          and state["current"] == {"stepId": "claim", "attempt": 1} and state["stopped"] is None and state["definitionReported"] is True
          and state["context"]["repository"] is None and state["context"]["cwd"] == os.path.realpath(run.cwd) and state["seq"] == 1
          and state["steps"]["claim"]["status"] == "issued" and state["pluginVersion"] == json.load(open(os.path.join(ROOT, ".claude-plugin/plugin.json")))["version"], state)
    world = module.World(env={}, uid=os.getuid())
    check("this user's state file is read", module.read_state(run.state_path(), world)["runId"] == state["runId"])
    try:
        module.read_state(run.state_path(), module.World(env={}, uid=os.getuid() + 1))
        other = False
    except module.Refuse as refusal:
        other = refusal.code == "state-unreadable"
    check("a state file owned by another user is refused", other)
    real = run.state_path() + ".moved"
    os.rename(run.state_path(), real)
    os.symlink(real, run.state_path())
    check("a symbolic link in place of a state file is refused", refused(run.call("next", {"item": "I123"}), "state-unreadable") and refused(run.call("done", {"item": "I123", "stepId": "claim", "attempt": 1, "output": "CLAIM: WON"}), "state-unreadable")
          and refused(run.call("start", {"definition": FIX["definitions"]["claim-only"], "context": dict(FIX["context"], cwd=run.cwd)}), "state-unreadable"))
    os.unlink(run.state_path())
    with open(run.state_path(), "w") as out:
        out.write(json.dumps(dict(state, padding="x" * 1100000)))
    check("a state file over 1 MB is refused", refused(run.call("next", {"item": "I123"}), "state-unreadable"))
    tampered = copy.deepcopy(state)
    tampered["definition"]["phases"][0]["steps"][0]["contract"] = "sync@1"
    with open(run.state_path(), "w") as out:
        json.dump(tampered, out)
    check("a state file whose definition was changed is refused", refused(run.call("next", {"item": "I123"}), "state-unreadable"))
    with open(run.state_path(), "w") as out:
        out.write("{not json")
    check("a state file that is not JSON is refused", refused(run.call("status", {"item": "I123"}), "state-unreadable"))

    # pruning
    run = Driver(definition="claim-only", plain=True)
    folder = os.path.dirname(run.state_path())
    old, recent = os.path.join(folder, "gone.I9.json"), os.path.join(folder, "kept.I9.json")
    for path, days in ((old, 8), (recent, 6)):
        with open(path, "w") as out:
            out.write("{}")
        os.utime(path, (time.time() - days * 86400, time.time() - days * 86400))
    run.call("start", {"definition": FIX["definitions"]["claim-only"], "context": dict(FIX["context"], cwd=run.cwd, item="I124")})
    check("a file older than seven days is pruned, a newer one is kept", not os.path.exists(old) and os.path.exists(recent), os.listdir(folder))

    # an open run, and replacing it
    request = {"definition": FIX["definitions"]["claim-only"], "context": dict(FIX["context"], cwd=run.cwd)}
    first = run.state()["runId"]
    check("a second start for the same session and item is refused", refused(run.call("start", request), "run-open") and run.state()["runId"] == first)
    rc, answer, _, _ = run.call("start", dict(request, replace=True))
    check("replace ends the open run as interrupted and starts a new one",
          rc == 0 and answer["runId"] != first and answer["reports"][0]["runId"] == first and answer["reports"][0]["run"]["outcome"] == "interrupted"
          and answer["reports"][1]["runId"] == answer["runId"] and "definition" in answer["reports"][1], answer and answer["reports"])
    run.answer = answer
    run.done()
    rc, answer, _, _ = run.call("start", request)
    check("a finished run does not block a new start", rc == 0 and is_run(answer, "claim", 1), answer)

    # adoption after a cleared conversation
    run = Driver(definition="claim-only", plain=True)
    first = run.state()
    rc, answer, _, err = run.call("resume", {"item": "I123"}, session="s2")
    adopted = run.state("s2")
    check("resume adopts the unfinished run an earlier session left: same run, same step, new session",
          rc == 0 and is_run(answer, "claim", 1) and answer["runId"] == first["runId"] and adopted["sessionId"] == "s2"
          and not os.path.exists(run.state_path("s1")) and os.listdir(os.path.dirname(run.state_path())) == ["s2.I123.json"], err)
    check("the first report after an adoption carries the definition again and the new session",
          answer["reports"][0]["definition"] == FIX["definitions"]["claim-only"] and answer["reports"][0]["sessionId"] == "s2", answer["reports"])
    check("the old session no longer has the run", refused(run.call("next", {"item": "I123"}, session="s1"), "no-run"))
    run.session = "s2"
    run.answer = answer
    check("the adopted run carries on", run.done()["action"] == "finished")
    check("a finished run is never adopted", refused(run.call("resume", {"item": "I123"}, session="s3"), "no-run") and os.path.exists(run.state_path("s2")))

    run = Driver(definition="claim-only", plain=True, session="old")
    older = run.state("old")["runId"]
    cache, cwd = run.cache, run.cwd
    request = {"definition": FIX["definitions"]["claim-only"], "context": dict(FIX["context"], cwd=cwd)}
    newer = cli(run.root, "start", request, cache, cwd=cwd, session="new")[1]["runId"]
    other = cli(run.root, "start", dict(request, context=dict(request["context"], item="I124")), cache, cwd=cwd, session="else")[1]["runId"]
    past = time.time() - 3600
    os.utime(run.state_path("old"), (past, past))
    rc, answer, _, _ = cli(run.root, "resume", {"item": "I123"}, cache, cwd=cwd, session="s9")
    check("with two earlier unfinished runs the newest is adopted", rc == 0 and answer["runId"] == newer and os.path.exists(run.state_path("old")) and not os.path.exists(run.state_path("new")), answer)
    check("a run for another item is left alone", os.path.exists(run.state_path("else", "I124")))
    rc, answer, _, _ = cli(run.root, "resume", {"runId": other}, cache, cwd=cwd, session="s9")
    check("a run can be adopted by its id", rc == 0 and answer["runId"] == other and os.path.exists(run.state_path("s9", "I124")), answer)
    check("resume with nothing to name is refused", refused(cli(run.root, "resume", {}, cache, cwd=cwd, session="s10"), "no-run"))
    os.symlink(run.state_path("old"), run.state_path("link"))
    with open(run.state_path("junk"), "w") as out:
        out.write("{}")
    rc, answer, _, _ = cli(run.root, "resume", {"item": "I123"}, cache, cwd=cwd, session="s11")
    check("a link or a stray file in the folder is never adopted", rc == 0 and answer["runId"] == newer and older != newer and os.path.exists(run.state_path("old")), answer["runId"])

    # adopting another session's run never overwrites this session's own open one
    run = Driver(definition="claim-only", plain=True, session="mine")
    mine = run.state("mine")["runId"]
    theirs = cli(run.root, "start", {"definition": FIX["definitions"]["claim-only"], "context": dict(FIX["context"], cwd=run.cwd)}, run.cache, cwd=run.cwd, session="theirs")[1]["runId"]
    result = run.call("resume", {"runId": theirs})
    check("resume by run id is refused while this session has its own open run for that item",
          refused(result, "run-open") and run.state("mine")["runId"] == mine and run.state("theirs")["runId"] == theirs, result[3])
    run.done()
    rc, answer, _, _ = run.call("resume", {"runId": theirs})
    check("... and adopts it once this session's own run has finished", rc == 0 and answer["runId"] == theirs and run.state("mine")["runId"] == theirs, answer)

    # where state may live
    repo = new_repo()
    request = {"definition": FIX["definitions"]["claim-only"], "context": dict(FIX["context"], cwd=repo)}
    check("state is never written under a .git folder", refused(cli(roots("fixture"), "start", request, os.path.join(repo, ".git", "cache"), cwd=repo), "state-unusable")
          and not os.path.exists(os.path.join(repo, ".git", "cache")))
    inside = os.path.join(roots("fixture"), "cache")
    check("state is never written into the plugin", refused(cli(roots("fixture"), "start", request, inside, cwd=repo), "state-unusable") and not os.path.exists(inside))
    caches = [name for root in (roots("fixture"), roots("standIn")) for _, names, _ in os.walk(root) for name in names if name == "__pycache__"]
    check("running the runner writes no byte-code into the plugin", caches == [], caches)
    # the session id: the request's, else the agent's own
    cache = fresh("cache")
    env = dict(os.environ, XDG_CACHE_HOME=cache, CODEX_THREAD_ID="thread-7")
    done = subprocess.run([sys.executable, "-B", os.path.join(roots("fixture"), RUNNER), "start"], input=json.dumps(request), capture_output=True, text=True, env=env, cwd=repo)
    check("without a session in the request the agent's own session id is used", done.returncode == 0 and os.listdir(os.path.join(cache, "devstride-plugin", "workflows")) == ["thread-7.I123.json"], done.stderr)
    env["CLAUDE_CODE_SESSION_ID"] = "claude-9"
    done = subprocess.run([sys.executable, "-B", os.path.join(roots("fixture"), RUNNER), "start"], input=json.dumps(request), capture_output=True, text=True, env=env, cwd=repo)
    check("... the first of the two the claim helper reads", done.returncode == 0 and "claude-9.I123.json" in os.listdir(os.path.join(cache, "devstride-plugin", "workflows")), done.stderr)


def section_reporting():
    module = load()
    vector = FIX["definitionHash"]
    definition = FIX["definitions"][vector["definition"]]
    run = Driver(definition=vector["definition"], plain=True)
    check("the definition's hash is the reporting helper's, on a shared test vector",
          run.answer["definitionHash"] == vector["sha256"] == module.REPORT.definition_hash(definition)
          == hashlib.sha256(module.REPORT.canonical_json(run.answer["reports"][0]["definition"])).hexdigest(), run.answer["definitionHash"])
    run = Driver(definition="mostly-off", plain=True)
    calls = run.answer["reports"]
    check("six step reports from one command go out as four and two, the definition in the first only",
          [len(call["reports"]) for call in calls] == [4, 2] and "definition" in calls[0] and "definition" not in calls[1]
          and [r["status"] for call in calls for r in call["reports"]] == ["skipped"] * 5 + ["running"]
          and calls[0]["reports"][0]["ran"] == {"source": "off"}, calls)
    final = run.done()
    check("a report object is exactly what the reporting helper builds",
          final["reports"] == [module.REPORT.build_report_arguments(final["runId"], "s1", [dict(final["reports"][0]["reports"][0], step="claim")], item_number="I123",
                                                                  run=final["reports"][0]["run"])], final["reports"])
    check("the runner keeps no second copy of the helper's rules",
          not re.search(r"def (canonical_json|definition_hash|normalize_repository|clean_verdict|clean_evidence|clean_links|build_report_arguments)\b|sort_keys=True, separators=\(\",\", \":\"\), ensure_ascii=False|VERDICT_MAX|EVIDENCE_MAX",
                        open(os.path.join(ROOT, RUNNER)).read()))


def section_records():
    """What became of a run's reports, the replay of unsent ones, a repaired step's attempt and
    the completeness check."""
    run = Driver()
    run.until("build")
    first = run.call("reported", {"item": "I123", "ok": False})[1]
    check("the first failed report marks the run and hands back the one line to say",
          first["unsent"] is True and isinstance(first["say"], str) and "a later session" in first["say"]
          and isinstance(run.state().get("reportsUnsent"), str), first)
    again = run.call("reported", {"item": "I123", "ok": False})[1]
    check("a second failed report says nothing more", again["unsent"] is True and again["say"] is None, again)
    check("reported needs ok to be true or false", refused(run.call("reported", {"item": "I123"}), "bad-request"))
    check("reported for an unknown run id is refused", refused(run.call("reported", {"runId": "0" * 32, "ok": True}), "no-run"))
    live = run.call("unsent", {"cwd": run.cwd}, session="another-session")[1]
    check("a run still going is never handed to another session", live == {"runs": [], "more": 0}, live)
    stopped = run.done("BUILD: BLOCKED the tests cannot be made to pass\n")
    unsent = run.call("unsent", {"cwd": run.cwd}, session="another-session")[1]
    reports = [r for call in unsent["runs"][0]["reports"] for r in call["reports"]] if unsent["runs"] else []
    check("once it has stopped, another session of the same repository is handed the run's reports in full",
          is_stopped(stopped, "failed", "build") and len(unsent["runs"]) == 1 and unsent["more"] == 0
          and unsent["runs"][0]["runId"] == stopped["runId"]
          and [(r["stepId"], r["status"]) for r in reports] == [("claim", "done"), ("start", "done"), ("branch", "done"), ("build", "failed")]
          and "definition" in unsent["runs"][0]["reports"][0] and all(len(call["reports"]) <= 4 for call in unsent["runs"][0]["reports"])
          and unsent["runs"][0]["reports"][-1].get("run", {}).get("outcome") == "failed", unsent)
    elsewhere = run.call("unsent", {"cwd": new_repo(remote="https://example.com/other/repo.git")}, session="another-session")[1]
    check("a checkout of another repository is handed nothing", elsewhere == {"runs": [], "more": 0}, elsewhere)
    before = run.state()["seq"]
    run.call("unsent", {"cwd": run.cwd})
    check("unsent changes nothing", run.state()["seq"] == before and run.state().get("reportsUnsent"))
    kept = run.call("reported", {"runId": stopped["runId"], "ok": True}, session="another-session")[1]
    check("a replayed run that has only stopped keeps its mark: its own session may carry it on unreported",
          kept == {"runId": stopped["runId"], "unsent": True, "say": None} and run.state().get("reportsUnsent"), kept)
    run.answer = run.call("resume", {"item": "I123"})[1]
    run.to_end()
    ended = run.call("unsent", {"cwd": run.cwd}, session="another-session")[1]["runs"][0]["reports"]
    check("a finished run's replay ends with the run's own end",
          ended[-1].get("run", {}).get("outcome") == "completed" and sum(len(call["reports"]) for call in ended) == 11, ended)
    cleared = run.call("reported", {"runId": stopped["runId"], "ok": True}, session="another-session")[1]
    check("once the run has ended, a replay that went through clears the mark, from any session of this user",
          cleared == {"runId": stopped["runId"], "unsent": False, "say": None} and "reportsUnsent" not in run.state()
          and run.call("unsent", {"cwd": run.cwd})[1]["runs"] == [], cleared)
    check("unsent refuses a cwd that is not a directory", refused(run.call("unsent", {"cwd": os.path.join(WORK, "no-such-folder")}), "bad-request"))
    broken = dict(run.state(), reportsUnsent="2026-01-01T00:00:00Z")
    del broken["sessionId"]
    with open(os.path.join(os.path.dirname(run.state_path()), "x.I999.json"), "w") as out:
        json.dump(broken, out)
    check("a state file this runner did not write is skipped, never a failure", run.call("unsent", {"cwd": run.cwd})[1] == {"runs": [], "more": 0})

    run = Driver()
    run.until("review")
    stopped = run.done(canned("review@1", run.repo).replace('"cycles"', '"rounds"'))
    failed = run.step_reports([stopped])[-1]
    repaired = run.done_by_hand("review", 1)
    fixed = [r for r in run.step_reports([repaired]) if r["stepId"] == "review"]
    check("a step repaired by hand is reported as a later attempt, so the tracker's finished failure does not hide it",
          is_stopped(stopped, "failed", "review") and (failed["status"], failed["attempt"]) == ("failed", 1)
          and is_run(repaired, "merge", 1) and [(r["status"], r["attempt"]) for r in fixed] == [("done", 2)]
          and repaired["recorded"]["attempt"] == 1, (failed, fixed))

    module = load()
    definition = FIX["definitions"]["build"]
    ids = [step["id"] for phase in definition["phases"] for step in phase["steps"]]
    tracked = lambda statuses, state="ended": {"runs": [{"state": state, "workflow": {"hash": "h"}, "reports": [
        {"stepId": step, "attempt": attempt, "status": status} for step, attempt, status in statuses]}], "definitions": {"h": definition}}
    judge = lambda answer: run.call("judge", {"item": "I123", "answer": answer})[1]
    done = [(step, 1, "done") for step in ids]
    check("every step done is complete", judge(tracked(done)) == {"item": "I123", "verdict": "complete", "gaps": [], "line": "I123: complete"})
    missing = judge(tracked([entry for entry in done if entry[0] not in ("risk-check", "review")]))
    check("a required step never reported is named", missing["verdict"] == "incomplete"
          and missing["gaps"] == [{"stepId": "risk-check", "reason": "missing"}, {"stepId": "review", "reason": "missing"}]
          and missing["line"] == "I123: incomplete (never reported: risk-check, review)", missing)
    check("a later attempt that passed overrides an earlier failure",
          judge(tracked(done + [("review", 1, "failed"), ("review", 2, "done")]))["verdict"] == "complete")
    check("a newest attempt that failed is a gap",
          judge(tracked(done + [("merge", 2, "failed")]))["gaps"] == [{"stepId": "merge", "reason": "failed"}])
    check("a step still running in an ended run never finished",
          judge(tracked(done[:4] + [("risk-check", 1, "running")]))["gaps"][0] == {"stepId": "risk-check", "reason": "unfinished"})
    check("a run still going is running, not incomplete", judge(tracked(done[:4] + [("risk-check", 1, "running")], "open"))["verdict"] == "running")
    check("an item with no run was not reported", judge({"runs": [], "definitions": {}})["verdict"] == "not-reported")
    check("a run whose definition the tracker does not hold cannot be judged",
          judge({"runs": [{"state": "ended", "workflow": {"hash": "x"}, "reports": []}], "definitions": {}})["verdict"] == "unknown")
    check("a run still going with every step done is complete", judge(tracked(done, "open"))["verdict"] == "complete")
    odd = run.call("judge", {"item": "I123", "answer": {"runs": [{"workflow": {"hash": ["x"]}, "reports": 3}], "definitions": {}}})
    worse = run.call("judge", {"item": "I123", "answer": {"runs": [{"workflow": {"hash": "h"}, "reports": [7]}], "definitions": {"h": {"phases": [{"name": "p", "steps": [3]}]}}}})
    check("an answer that is not the tracker's never crashes the runner",
          odd[0] == 0 and odd[1]["verdict"] == "unknown" and (worse[0] == 0 and worse[1]["verdict"] == "unknown" or refused(worse, "bad-request")), (odd, worse))
    check("judge needs the item and the tracker's answer", refused(run.call("judge", {"item": "I123"}), "bad-request")
          and refused(run.call("judge", {"answer": {"runs": []}}), "bad-request"))
    check("the completeness rule skips a step that is switched off or does not always run",
          module.judge_run({"reports": []}, {"phases": [{"name": "p", "steps": [
              {"id": "a", "run": {"source": "off"}, "when": {"mode": "always"}, "onFail": "stop"},
              {"id": "b", "run": {"source": "builtin"}, "when": {"mode": "manual"}, "onFail": "stop"}]}]}) == ("complete", []))


def section_repository():
    module = load()
    for case in FIX["repository"]:
        repo = new_repo(case["remote"])
        run = Driver(definition="claim-only", repo=repo)
        got = run.answer["reports"][0].get("repository")
        check("repository: %s -> %s" % (case["remote"], case["expect"]),
              got == case["expect"] == module.REPORT.read_repository(repo) and run.state()["context"]["repository"] == case["expect"], got)
    run = Driver(definition="claim-only", plain=True)
    check("repository: a directory with no git -> none", "repository" not in run.answer["reports"][0] and run.state()["context"]["repository"] is None)


def section_static():
    path = os.path.join(ROOT, RUNNER)
    source = open(path, encoding="utf-8").read()
    out = os.path.join(WORK, "compiled.pyc")
    done = subprocess.run([sys.executable, "-B", "-c", "import py_compile, sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)", path, out], capture_output=True, text=True)
    check("the runner compiles", done.returncode == 0 and os.path.isfile(out), done.stderr)
    tree = ast.parse(source)
    try:
        ast.parse(source, feature_version=(3, 8))
        old = True
    except (SyntaxError, TypeError):
        old = False
    check("the runner's syntax is valid for Python 3.8", old)
    imported = sorted(set(a.name.split(".")[0] for n in ast.walk(tree) if isinstance(n, ast.Import) for a in n.names)
                      | set((n.module or "").split(".")[0] for n in ast.walk(tree) if isinstance(n, ast.ImportFrom)))
    allowed = ["datetime", "hashlib", "importlib", "json", "os", "re", "secrets", "stat", "subprocess", "sys", "time"]
    check("the runner imports the standard library only (%s)" % " ".join(imported), imported == allowed, imported)
    check("the runner imports no network module", not set(imported) & {"socket", "http", "urllib", "ssl", "ftplib", "smtplib", "xmlrpc", "asyncio", "requests"}
          and not re.search(r"\b(socket|urllib|http\.client|ssl|requests)\b", source))
    helpers = re.findall(r'for name in \(([^)]*)\):\n\s+spec = importlib\.util\.spec_from_file_location', source)
    check("the two helpers are loaded by file path, and nothing else is", helpers == ['"workflow_report", "claim_record"'] and source.count("spec_from_file_location") == 1 and "__import__" not in source, helpers)
    started = [n for n in ast.walk(tree) if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and isinstance(n.func.value, ast.Name) and n.func.value.id == "subprocess"]
    check("one place starts a process, and it starts git", len(started) == 1 and started[0].func.attr == "run" and ast.get_source_segment(source, started[0].args[0]).startswith('["git", "-C", cwd]')
          and "os.system" not in source and "os.popen" not in source and "os.exec" not in source and "os.spawn" not in source, len(started))
    calls = [n for n in ast.walk(tree) if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr == "git"]
    named = [n.args[1].value if len(n.args) > 1 and isinstance(n.args[1], ast.Constant) else None for n in calls]
    check("every git command the runner runs is read-only (%s)" % " ".join(sorted(set(str(n) for n in named))),
          len(calls) >= 4 and set(named) <= {"rev-parse", "diff", "patch-id"}, named)
    module = load()
    check("... and the one place refuses any other", module.GIT_READ_ONLY == ("rev-parse", "diff", "patch-id"))
    for command in (("commit", "-m", "x"), ("push",), ("fetch",), ("checkout", "main"), ("reset", "--hard"), ()):
        try:
            module.run_git(WORK, *command)
            stopped = False
        except module.GitFailed:
            stopped = True
        check("git %s is not run" % (command[0] if command else "(nothing)"), stopped)
    check("the runner never writes to a repository, a network or a skill", not re.search(r"\b(push|fetch|pull|commit|checkout|reset|merge)\b\"", source))
    diff = [n for n in calls if len(n.args) > 1 and isinstance(n.args[1], ast.Constant) and n.args[1].value == "diff"]
    flags = [a.value for a in diff[0].args[2:] if isinstance(a, ast.Constant)] if len(diff) == 1 else []
    check("the patch id's diff has fixed flags: no colour, no external diff, no text converter, no relative paths, fixed prefixes, "
          "submodules shown, three lines of context, no renames, one algorithm", flags == DIFF[1:] + ["--"], flags)
    patch = [n for n in calls if len(n.args) > 2 and isinstance(n.args[1], ast.Constant) and n.args[1].value == "patch-id"]
    check("... and the patch id counts every byte (--verbatim)", len(patch) == 1 and isinstance(patch[0].args[2], ast.Constant) and patch[0].args[2].value == "--verbatim")

    def fake(cwd, *args, **options):
        if args[0] == "patch-id":
            raise module.GitFailed("git patch-id failed")
        return b"diff"

    try:
        module.World(env={}, git=fake).patch_id(WORK, "main", "c" * 40)
        said = ""
    except module.GitFailed as error:
        said = str(error)
    check("a git that cannot do --verbatim stops the check with a reason that says so", "--verbatim" in said, said)


SECTIONS = {"catalog": section_catalog, "validation": section_validation, "verdicts": section_verdicts,
            "proof-fixtures": section_proof_fixtures, "lifecycle": section_lifecycle, "proofs": section_proofs,
            "stand-in": section_stand_in, "evidence": section_evidence, "state": section_state,
            "reporting": section_reporting, "records": section_records, "repository": section_repository, "static": section_static}
SECTIONS[SECTION]()
print("ran %d" % counter[0])
PY

# section <name> <at least this many cases>
section() {
  local out rc n
  out="$(python3 -B "$WORK/cases.py" "$ROOT" "$WORK" "$1" 2>&1)"; rc=$?
  printf '%s\n' "$out" | grep -v '^ran [0-9]*$' | sed 's/^/  /'
  n="$(printf '%s\n' "$out" | sed -n 's/^ran \([0-9]*\)$/\1/p')"
  if [ $rc -ne 0 ] || [ -z "$n" ] || printf '%s\n' "$out" | grep -q '^FAIL'; then bad "$1: a case failed or the section did not finish (exit $rc)"
  elif [ "$n" -lt "$2" ]; then bad "$1: only $n cases ran, expected at least $2"
  else ok "($1: all $n cases passed)"; fi
}
section catalog 37
section validation 125
section verdicts 76
section proof-fixtures 25
section lifecycle 59
section proofs 71
section stand-in 3
section evidence 79
section state 29
section reporting 4
section records 24
section repository 7
section static 18
exit $FAIL
