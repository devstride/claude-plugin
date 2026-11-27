#!/bin/bash
# scripts/tests/workflow-dormant.sh — the step runner's newer abilities are dormant: against a tracker
# that offers none of them, every answer equals the 4.8.1 runner's.
#
# The newer abilities (approval gates and checkpoints, conditions, carrying on after a failure,
# starting when an item's children are complete, the landed and shipped run endings) need something the tracker does not offer everywhere yet. Until it does, a
# run must behave exactly as it did in 4.8.1. This test proves it three ways:
#
#   1. Recorded answers. scripts/tests/fixtures/workflow-dormant/release-4.8.1.json holds every
#      answer the 4.8.1 runner gave to the scripted walks below (a Build run with no workflow
#      fetched, with the tracker absent, with no match, with the organization's own workflow, with
#      a failed check then a resume, an organization's workflow that leaves the review out, one
#      that carries a key only gates read, one whose step always runs and still names a
#      condition, a Hotfix run with no item (a second start refused, a question, a resume, the
#      end, and a start that replaces an open run), and a definition with an approval gate or a
#      checkpoint handed straight to `start`, in the request and as a file).
#      The same walks run against this runner and each answer must be equal, apart from the keys
#      listed in ADDED, which must hold their empty value (or, for the runner's own note of what a
#      step recorded, a value the tracker is never told here). Ids, hashes, times, paths and the
#      plugin's own version are replaced by placeholders on both sides.
#   2. Nothing new is ever asked for: no walk answers with a gate, a parked run, a changes request
#      or a need for facts, and no run is reported with an ending other than completed, failed or
#      interrupted, even when a step recorded a landing.
#   3. A definition that holds a gate or a checkpoint is still refused at `start`, whoever hands it
#      over (4.8.1: it knew no such step; now: not switched on), and nothing is written.
#
# The Release workflow is switched on, so its walk (4.8.1 refused each release definition) is the one
# recorded walk no longer replayed: RETIRED says so, and workflow-release.sh case (140) starts them.
#
# `--record <plugin root>` rewrites the fixture from another copy of the plugin. It was recorded once,
# from the 4.8.1 release, and is never recorded from a later runner: that would compare this runner
# with itself.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
RECORD=""
if [ "${1:-}" = "--record" ]; then
  [ $# -eq 2 ] && [ -d "$2" ] || { echo "usage: workflow-dormant.sh [--record <plugin root>]" >&2; exit 2; }
  RECORD="$(cd "$2" && pwd)"
fi

cat > "$WORK/cases.py" <<'PY'
import copy, importlib.util, json, os, re, subprocess, sys

ROOT, WORK, RECORD = sys.argv[1], sys.argv[2], sys.argv[3]
RUNNER = "skills/run-workflow/scripts/workflow.py"
FIXTURE = os.path.join(ROOT, "scripts/tests/fixtures/workflow-dormant/release-4.8.1.json")
FIX = json.load(open(os.path.join(ROOT, "skills/run-workflow/scripts/workflow-fixtures.json"), encoding="utf-8"))
NOW = "2026-11-21T16:00:00.000Z"
RELEASES = ("release", "release-cut-to-deploy", "release-merge-and-deploy", "release-docs", "release-notes", "release-post-deploy")
made = [0]


def check(label, good, detail=""):
    print(("ok   " if good else "FAIL ") + label + ("" if good else " -> %s" % (detail,)))
    return good


def git(repo, *args, **kw):
    done = subprocess.run(["git", "-C", repo, "-c", "user.name=Test", "-c", "user.email=test@example.com",
                           "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + list(args),
                          capture_output=True, input=kw.get("stdin"))
    if done.returncode != 0:
        raise RuntimeError("git %s: %s" % (" ".join(args), done.stderr.decode()))
    return done.stdout


def fresh(name):
    made[0] += 1
    path = os.path.join(WORK, "%s-%d" % (name, made[0]))
    os.makedirs(path)
    return path


def new_repo():
    """A repository on a branch called feature, one commit ahead of main."""
    repo = fresh("repo")
    git(repo, "init", "-q")
    git(repo, "checkout", "-q", "-b", "main")
    for name, text, message, branch in (("readme.txt", "one\n", "first", None), ("export.txt", "export\n", "add the export", "feature")):
        if branch:
            git(repo, "symbolic-ref", "refs/remotes/origin/main", "refs/heads/main")
            git(repo, "checkout", "-q", "-b", branch)
        with open(os.path.join(repo, name), "w") as out:
            out.write(text)
        git(repo, "add", "-A")
        git(repo, "commit", "-q", "-m", message)
    return repo


DIFF = ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-relative", "--src-prefix=a/", "--dst-prefix=b/",
        "--ignore-submodules=none", "--unified=3", "--no-renames", "--diff-algorithm=myers", "--inter-hunk-context=0"]


def canned(contract, repo):
    """The passing answer for a contract (the runner's own fixtures), about this repository."""
    diff = git(repo, *(DIFF + ["main...HEAD", "--"]))
    patch = git(repo, "patch-id", "--verbatim", stdin=diff).decode().split()
    known = {"head": git(repo, "rev-parse", "HEAD").decode().strip(), "tree": git(repo, "rev-parse", "HEAD^{tree}").decode().strip(),
             "patchId": patch[0] if patch else ""}
    text = FIX["outputs"][contract]
    for key, value in known.items():
        text = text.replace("{%s}" % key, value)
    return text


def told(verdict, result):
    return "%s\nevidence line\n```json\n%s\n```\n" % (verdict, json.dumps(result))


# The passing answer for each of the Hotfix workflow's own steps; the three it shares with Build
# answer as they do there, the review on a pull request.
HOTFIX = {
    "hotfix-preflight@1": lambda head: told("HOTFIX PREFLIGHT: READY feature", {"branch": "feature", "base": "main", "prefix": "test", "date": "11-21-26", "dateFormat": "MM-DD-YY", "configSource": "file"}),
    "hotfix-branch@1": lambda head: told("HOTFIX BRANCH: CUT feature", {"branch": "feature", "base": "main", "baseSha": head, "pushed": True, "shipIntent": "not configured"}),
    "hotfix-stage@1": lambda head: told("HOTFIX STAGE: NAMED local", {"stage": "local", "production": False}),
    "hotfix-environment@1": lambda head: told("HOTFIX ENVIRONMENT: RECREATED", {"case": 1, "mode": "inPlace", "why": "recreate is set", "restartDevServer": True}),
    "hotfix-report@1": lambda head: told("HOTFIX CUT: DONE feature", {"branch": "feature", "case": "1"}),
    "hotfix-fix@1": lambda head: told("HOTFIX FIX: COMMITTED " + head, {"commit": head, "deferrals": [], "deviations": [], "untrackedDeferrals": [], "dismissed": [], "scopeLine": "Fixes the login crash.", "head": head}),
    "hotfix-merge@1": lambda head: told("HOTFIX MERGE: MERGED abc1234", {"sha": "abc1234", "pullRequest": 7}),
    "deploy-approval@1": lambda head: told("DEPLOY APPROVAL: APPROVED", {"mergeSha": "abc1234", "approved": True}),
    "deploy-confirm@1": lambda head: told("DEPLOY: CONFIRMED abc1234", {"mergeCommit": "abc1234", "confirmedAt": "2026-11-21T19:00:00Z"}),
    "hotfix-close@1": lambda head: told("HOTFIX CLOSED: CLOSED abc1234", {"mergeSha": "abc1234", "openRelease": None}),
}


def hotfix_canned(contract, repo):
    if contract in HOTFIX:
        return HOTFIX[contract](git(repo, "rev-parse", "HEAD").decode().strip())
    text = canned(contract, repo)
    return text.replace('"fast-local"', '"pull-request"').replace('"pullRequest": null', '"pullRequest": 7') if contract == "review@1" else text


class Walk:
    """One scripted run against one copy of the plugin; every answer is kept, with what changes
    from run to run replaced by a placeholder."""

    def __init__(self, root, item="I123", canned=canned):
        self.root, self.cache, self.repo, self.said = root, fresh("cache"), new_repo(), []
        self.names, self.canned = ({"item": item} if item else {}), canned  # a run with no item is the session's only open one
        self.version = json.load(open(os.path.join(root, ".claude-plugin/plugin.json"), encoding="utf-8"))["version"]

    def call(self, command, request):
        env = dict((k, v) for k, v in os.environ.items() if k not in ("CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID"))
        env["XDG_CACHE_HOME"] = self.cache
        request = dict(request, session="s1", now=NOW)
        done = subprocess.run([sys.executable, "-B", os.path.join(self.root, RUNNER), command], input=json.dumps(request),
                              capture_output=True, text=True, env=env, cwd=self.repo)
        answer = json.loads(done.stdout) if done.returncode == 0 else None
        refusal = done.stderr.strip().split(": ")[1] if done.returncode == 2 else None  # the code, never the wording
        self.said.append({"command": command, "exit": done.returncode, "answer": self.plain(answer), "refused": refusal})
        return answer

    def plain(self, value):
        text = json.dumps(value, sort_keys=True)
        for path in (os.path.realpath(self.repo), self.repo, os.path.realpath(self.cache), self.cache):
            text = text.replace(json.dumps(path)[1:-1], "<path>")
        text = re.sub(r"\b[0-9a-f]{32,64}\b", "<hex>", text)
        text = text.replace('"%s"' % self.version, '"<plugin>"')
        return json.loads(text)

    def start(self, definition=None, **more):
        request = {"definition": definition or FIX["definitions"]["build"], "context": dict(FIX["context"], cwd=self.repo)}
        request.update(more)
        return self.call("start", request)

    def to_end(self, answer, answers=None, stop_at=None):
        """Answer each issued step with its passing answer (or the one given) until the run stops, ends or reaches `stop_at`."""
        while answer and answer.get("action") == "run" and answer["step"]["id"] != stop_at:
            step = answer["step"]
            output = (answers or {}).get(step["id"]) or self.canned(step["contract"], self.repo)
            answer = self.call("done", dict(self.names, stepId=step["id"], attempt=step["attempt"], output=output))
        return answer


# A step a person answers in the tracker: an approval gate, and a checkpoint.
ASKS = {
    "gate": {"id": "approve", "name": "Approve the change", "summary": "A person approves before the review.", "contract": "approval@1",
             "kind": "gate", "run": {"source": "builtin", "ref": "gate", "version": None}, "when": {"mode": "always", "condition": None},
             "onFail": "stop"},
    "checkpoint": {"id": "by-hand", "name": "Try it by hand", "summary": "Export one board and open the file.", "contract": "checkpoint@1",
                   "kind": "step", "run": {"source": "builtin", "ref": "checkpoint", "version": None},
                   "when": {"mode": "manual", "condition": None}, "onFail": "stop"},
}


def asking(definition, kind):
    """The definition with that step put in after the local checks."""
    definition = copy.deepcopy(definition)
    for phase in definition["phases"]:
        for at, step in enumerate(phase["steps"]):
            if step["id"] == "local-checks":
                phase["steps"].insert(at + 1, copy.deepcopy(ASKS[kind]))
                return definition
    raise RuntimeError("the Build fixture has no local-checks step")


def organization(root, definition):
    """What a tracker without any of the newer abilities answers for the item: the organization's
    workflow, whole, with its fingerprint; no run endings listed, no library skills."""
    spec = importlib.util.spec_from_file_location("report_of", os.path.join(root, "skills/build-item/scripts/workflow_report.py"))
    report = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(report)
    return {"organizationId": "org-1", "skills": [],
            "match": {"workflowId": "our-build", "name": "Our build", "version": 3, "startsWhen": definition["startsWhen"],
                      "minPluginVersion": definition["minPluginVersion"], "hash": report.definition_hash(definition), "definition": definition}}


def without_review(definition):
    """The organization's workflow with the review switched off and nothing after it that needs one."""
    definition, keep, phases = copy.deepcopy(definition), True, []
    for phase in definition["phases"]:
        steps = []
        for step in phase["steps"]:
            if keep:
                steps.append(step)
            if step["id"] == "review":
                step["run"], keep = {"source": "off", "ref": None, "version": None}, False
        if steps:
            phases.append(dict(phase, steps=steps))
    return dict(definition, phases=phases)


def walks(root):
    """Every scripted walk, by name: the list of what the runner said."""
    out = {}
    build = FIX["definitions"]["build"]
    ours = dict(copy.deepcopy(build), id="our-build", name="Our build", version=3)

    w = Walk(root)
    w.to_end(w.start())
    w.call("status", {"item": "I123"})
    out["a build run, no workflow fetched"] = w.said

    for name, fetched in (("the tracker absent", {"error": "ABSENT"}), ("no workflow matches", {"match": None}),
                          ("the route's wrapped answer with no match", {"data": {"match": None}})):
        w = Walk(root)
        w.to_end(w.start(fetched=fetched))
        out["a build run, %s" % name] = w.said

    w = Walk(root)
    w.to_end(w.start(fetched=organization(root, ours)))
    w.call("status", {"item": "I123", "includeDefinition": True})
    out["the organization's own workflow"] = w.said

    w = Walk(root)
    answer = w.to_end(w.start(), stop_at="local-checks")
    w.call("status", {"item": "I123"})
    w.call("next", {"item": "I123"})
    answer = w.call("done", {"item": "I123", "stepId": "local-checks", "attempt": answer["step"]["attempt"],
                             "output": "LOCAL CHECKS: FAIL unit\nunit: 1 failed\n"})
    w.call("status", {"item": "I123"})
    w.call("done", {"item": "I123", "stepId": "review", "attempt": 1, "output": "REVIEW: PASS\n"})  # not the current step
    w.to_end(w.call("resume", {"item": "I123", "workflow": "build"}))
    w.call("resume", {"item": "I123", "workflow": "build"})  # the run is over
    out["a failed check, then a resume"] = w.said

    w = Walk(root)
    w.to_end(w.start(fetched=organization(root, without_review(ours))))
    out["the organization's workflow with the review switched off"] = w.said

    w = Walk(root)
    w.to_end(w.start(context=dict(FIX["context"], cwd=w.repo, trigger="on-demand")))
    out["a build run started with another trigger"] = w.said

    keyed = copy.deepcopy(ours)
    keyed["phases"][0]["steps"][0]["answerers"] = [{"kind": "everyone"}]  # a key 4.8.1 never read, on a step that is no gate
    w = Walk(root)
    w.to_end(w.start(fetched=organization(root, keyed)))
    out["the organization's workflow with a key only gates read, on an ordinary step"] = w.said

    conditioned = copy.deepcopy(ours)
    conditioned["phases"][-1]["steps"][-1]["when"] = {"mode": "always", "condition": "review-path:fast"}  # stored by DevStride today: never read
    w = Walk(root)
    w.to_end(w.start(fetched=organization(root, conditioned)))
    out["the organization's workflow with a condition on a step that always runs"] = w.said

    # The Hotfix workflow with no item, as branch-hotfix starts it: one such run to a session.
    w = Walk(root, item=None, canned=hotfix_canned)
    hotfix = {"definitionFile": os.path.join(root, "workflows", "hotfix.json"),
              "context": {"branchArgument": "fix-login", "profile": {"name": "extended", "source": "config"}, "workingBase": "main",
                          "oneOff": True, "route": "develop-pr", "reviewMoment": "pr-boundary", "cwd": w.repo}}
    w.call("start", hotfix)
    w.call("start", hotfix)                                   # a second start: refused, the first is open
    w.call("start", dict(hotfix, fetched={"match": None}))    # with the tracker's answer: where the open run is
    w.call("done", {"stepId": "preflight", "attempt": 1, "output": told("HOTFIX PREFLIGHT: NEEDS INPUT which branch name?", {})})
    w.call("status", {})
    w.to_end(w.call("resume", {"workflow": "hotfix", "answer": "fix-login"}))
    w.call("resume", {"workflow": "hotfix"})                  # the run is over
    w.call("start", hotfix)                                   # a finished run does not block the next one
    w.call("start", dict(hotfix, replace=True))               # replace ends the open run and starts another
    w.call("status", {})
    out["a hotfix run with no item"] = w.said

    # A gate or a checkpoint handed straight to start, with no answer from the tracker: in the
    # request, then as a file. 4.8.1 knew no such step and refused; nothing is asked of a person.
    w = Walk(root)
    for kind in ("gate", "checkpoint"):
        handed = asking(build, kind)
        w.start(handed)
        path = os.path.join(fresh("definition"), "%s.json" % kind)
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(handed, handle)
        w.call("start", {"definitionFile": path, "context": dict(FIX["context"], cwd=w.repo)})
    w.said.append({"written": sorted(name for _, _, names in os.walk(w.cache) for name in names)})
    out["a gate and a checkpoint handed to start"] = w.said

    return out


if RECORD:
    recorded = {"_readme": "Every answer the 4.8.1 step runner gave to the scripted walks of scripts/tests/workflow-dormant.sh, "
                           "recorded once from that release. Never edit it and never record it from a later runner.",
                "walks": walks(RECORD)}
    os.makedirs(os.path.dirname(FIXTURE), exist_ok=True)
    with open(FIXTURE, "w", encoding="utf-8") as out:  # one call a line: compact, and a change still reads
        out.write('{"_readme": %s,\n "walks": {\n' % json.dumps(recorded["_readme"]))
        names = sorted(recorded["walks"])
        for name in names:
            calls = ",\n   ".join(json.dumps(call, sort_keys=True, separators=(",", ":")) for call in recorded["walks"][name])
            out.write('  %s: [\n   %s\n  ]%s\n' % (json.dumps(name), calls, "" if name == names[-1] else ","))
        out.write(" }\n}\n")
    print("ok   recorded %d walks from %s" % (len(recorded["walks"]), RECORD))
    sys.exit(0)

# What this runner's answers hold that 4.8.1's did not, and the only values each may have here.
# recordedOutcome is the runner's own note of what a step recorded: the agent is shown it, and the
# tracker is told it only when it lists that ending (checked below: here it never is).
# agent says only where a run answer's step runs (skills/run-workflow/references/step-agents.md): a
# driver that does not read it runs every step in its conversation, exactly as 4.8.1's did.
ADDED = {"recordedOutcome": (None, "landed", "shipped"), "continuedPastFailures": ([],), "openCheckpoints": ([],),
         "skippedByCondition": ([],), "parkedAt": (None,), "agent": ("routine", "conversation")}
# The refusals whose code changed, by walk: the release step skill was missing, and is now not
# switched on; a gate or a checkpoint was a step 4.8.1 had no contract for, and is now not switched on.
RENAMED_REFUSALS = {"a gate and a checkpoint handed to start": {"unknown-contract": "skill-dormant"}}
# A stop that asks a person no longer ends the run: 4.8.1 told the tracker it ended `interrupted`,
# and the run now stays open so the answer carries it on. Only that ending is set aside, and only on
# such a stop; the answer must then carry no ending at all.
def opened_stop(old, new):
    answer = old.get("answer")
    if not (isinstance(answer, dict) and answer.get("action") == "stopped" and answer.get("kind") == "needs-person"):
        return old
    for batch in (new.get("answer") or {}).get("reports") or []:
        if "run" in batch:
            return old
    old = copy.deepcopy(old)
    for batch in old["answer"].get("reports") or []:
        if batch.get("run", {}).get("outcome") == "interrupted":
            batch.pop("run")
    return old


# A waiting step that asked a person now says so (`waitingOn: "person"`), a key 4.8.1 never sent.
# It is set aside only on a waiting report; anywhere else it stays and the comparison fails.
def asked_person(new):
    new = copy.deepcopy(new)
    for batch in (new.get("answer") or {}).get("reports") or [] if isinstance(new.get("answer"), dict) else []:
        for report in batch.get("reports") or []:
            if report.get("status") == "waiting" and report.get("waitingOn") == "person":
                report.pop("waitingOn")
    return new


# The recorded walks no longer replayed, each with why: the fixture is never edited.
RETIRED = {"the release definitions": "the Release workflow is switched on: workflow-release.sh case (140) starts each definition"}
OLD_ACTIONS = ("run", "stopped", "finished")
OLD_ENDINGS = ("completed", "failed", "interrupted")

try:
    before = json.load(open(FIXTURE, encoding="utf-8"))["walks"]
    check("each retired walk is one 4.8.1 recorded", sorted(set(RETIRED) - set(before)) == [], sorted(RETIRED))
    before = dict((name, calls) for name, calls in before.items() if name not in RETIRED)
except (OSError, ValueError) as error:
    check("the answers recorded from 4.8.1 are readable: never skipped, or this test proves nothing", False, error)
    sys.exit(0)
now = walks(ROOT)
check("the same walks are recorded and run", sorted(before) == sorted(now), (sorted(before), sorted(now)))
for name in sorted(before):
    was, said = before[name], now.get(name, [])
    differences, extra = [], []
    for at, (old, new) in enumerate(zip(was, said)):
        new = copy.deepcopy(new)
        if isinstance(new.get("answer"), dict):
            for key, allowed in ADDED.items():
                if key in new["answer"]:
                    value = new["answer"].pop(key)
                    if value not in allowed:
                        extra.append("%s call %d: %s is %r" % (name, at + 1, key, value))
        new = asked_person(new)
        old = opened_stop(old, new)
        if old.get("refused") in RENAMED_REFUSALS.get(name, {}):
            old = dict(old, refused=RENAMED_REFUSALS[name][old["refused"]])
        if old != new:
            keys = sorted(k for k in set(old) | set(new) if old.get(k) != new.get(k))
            differences.append("call %d (%s) differs in %s" % (at + 1, new.get("command", "the files written"), ", ".join(keys)))
    if len(was) != len(said):
        differences.append("%d calls were recorded, %d were made" % (len(was), len(said)))
    check("%s: every answer equals the 4.8.1 runner's (%d calls)" % (name, len(was)), differences == [], differences[:4])
    check("%s: nothing a newer ability adds is ever set" % name, extra == [], extra[:4])
    answers = [call["answer"] for call in said if isinstance(call.get("answer"), dict)]
    actions = sorted(set(a["action"] for a in answers if "action" in a))
    check("%s: no gate, parked run, changes request or need for facts" % name, all(a in OLD_ACTIONS for a in actions), actions)
    endings = sorted(set(r["run"]["outcome"] for a in answers for r in a.get("reports", []) if "run" in r))
    check("%s: the tracker is told only completed, failed or interrupted" % name, all(e in OLD_ENDINGS for e in endings), endings)

landed = [call for call in now["a build run, no workflow matches"] if (call.get("answer") or {}).get("action") == "finished"]
verdicts = [r.get("verdict") for call in now["a build run, no workflow matches"] for o in (call.get("answer") or {}).get("reports", [])
            for r in o.get("reports", [])]
check("a step that recorded a landing still ends the run as completed, to a tracker that lists no run endings",
      len(landed) == 1 and landed[0]["answer"]["outcome"] == "completed"
      and [r["run"]["outcome"] for r in landed[0]["answer"]["reports"] if "run" in r] == ["completed"]
      and any(isinstance(v, str) and v.startswith("COMPLETE: ") for v in verdicts), (landed, verdicts[-3:]))
handed = now["a gate and a checkpoint handed to start"]
check("a gate or a checkpoint handed to start, in the request or as a file, is refused as not switched on, and nothing is written",
      [call["exit"] for call in handed[:-1]] == [2] * 4 and set(call["refused"] for call in handed[:-1]) == {"skill-dormant"}
      and handed[-1] == {"written": []}, handed)
off = now["the organization's workflow with the review switched off"]
check("an organization's workflow that switches the review off, with nothing after it that needs one, still runs as theirs",
      off[0]["exit"] == 0 and off[0]["answer"]["definitionSource"] == "organization" and off[-1]["answer"]["action"] == "finished", off[0])

# Which built-in workflows the walks above cover, said exactly: Build (for an item) and the Hotfix
# (with no item) are replayed against 4.8.1's answers; the Release definitions, Plan and Rebalance
# are walked by their own suites (workflow-plan.sh), never against 4.8.1's answers.
# A built-in workflow in none of the three lists fails the check below, so a new one is placed on purpose.
REPLAYED = set(call["answer"]["workflow"]["id"] for walk in now.values() for call in walk
               if call.get("command") == "start" and (call.get("answer") or {}).get("definitionSource") == "builtin")
ELSEWHERE = {"plan", "rebalance"}
shipped, used = set(), []
for name in sorted(os.listdir(os.path.join(ROOT, "workflows"))):
    if not name.endswith(".json") or name == "registry.json":
        continue
    definition = json.load(open(os.path.join(ROOT, "workflows", name), encoding="utf-8"))
    shipped.add(definition["id"])
    if definition["startsWhen"] == "children-complete":
        used.append("%s starts when children are complete" % name)
    for phase in definition["phases"]:
        for step in phase["steps"]:
            if (step["kind"] != "step" or step["when"]["mode"] != "always" or step["when"]["condition"] is not None
                    or step["onFail"] != "stop" or "answerers" in step):
                used.append("%s %s" % (name, step["id"]))
check("no built-in workflow has a gate, a checkpoint, a condition, a step that carries on or a rollup start", used == [], used)
check("every built-in workflow is replayed against 4.8.1 here (Build, Hotfix) or walked by its own suite (the Release ones, Plan, Rebalance)",
      REPLAYED == {"build", "hotfix"} and shipped == REPLAYED | set(RELEASES) | ELSEWHERE,
      (sorted(REPLAYED), sorted(shipped ^ (REPLAYED | set(RELEASES) | ELSEWHERE))))
hotfix_walk = now["a hotfix run with no item"]
check("a hotfix with no item: the second start is refused, with the tracker's answer the open run's own step comes back, and the run ends completed",
      (hotfix_walk[1]["exit"], hotfix_walk[1]["refused"]) == (2, "run-open") and hotfix_walk[2]["exit"] == 0
      and (hotfix_walk[2]["answer"]["action"], hotfix_walk[2]["answer"]["step"], hotfix_walk[2]["answer"]["notice"])
      == ("run", hotfix_walk[0]["answer"]["step"], None)
      and [call["answer"]["outcome"] for call in hotfix_walk if (call.get("answer") or {}).get("action") == "finished"] == ["completed"], hotfix_walk[1:3])
flat = lambda path: " ".join(open(os.path.join(ROOT, path), encoding="utf-8").read().split())
check("the build loop stays silent about a ready rollup when the tracker has no rollup tools",
      "No rollup tools → silent" in flat("skills/build-item/references/next-unblocked.md"))
check("doctor never warns about the missing gate tools",
      "either missing → INFO, never WARN or FAIL" in flat("skills/doctor/references/workflows-checks.md"))
PY

OUT="$(python3 -B "$WORK/cases.py" "$ROOT" "$WORK" "$RECORD" 2>&1)"; RC=$?
printf '%s\n' "$OUT" | sed 's/^/  /'
N="$(printf '%s\n' "$OUT" | grep -c '^ok')"
if [ $RC -ne 0 ] || printf '%s\n' "$OUT" | grep -q '^FAIL'; then bad "a case failed or the script did not finish (exit $RC)"
elif [ -z "$RECORD" ] && [ "$N" -lt 58 ]; then bad "only $N cases ran, expected at least 58"
else ok "(all $N cases passed)"; fi
exit $FAIL
