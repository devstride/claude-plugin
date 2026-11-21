#!/usr/bin/env python3
"""The replay driver the workflow tests share: drive the REAL step runner with scripted step answers.

  python3 scripts/tests/fixtures/workflow-replay.py <plugin root> <scenario.json>

A scenario is { definition, phases?, context, script: [ {step, output} ], answers: [ ... ],
expect: { order, outcome, stops, reportCount? } }. `definition` is a path under the plugin root or a
definition object; `phases`, when given, keeps only those phase ids. The runner starts in a temporary
XDG_CACHE_HOME against a throwaway git repository (`main`, plus a branch carrying one commit), loops
`next`, feeds the output of the first unconsumed script entry for the issued step into `done`
({head} becomes the repository's HEAD), answers each stop with the next of `answers` through
`resume`, and compares the issued [step, attempt] pairs, the stopped step ids and the outcome
(`stopped` when the answers run out) with `expect`. One summary line on stdout; exit 0 when it
matches, 1 when it does not.

What a replay proves: the sequence, the stops, the re-issues and the outcome the runner produces
for answers written from today's step text. What a model does inside a step is not replayed.
"""
import json, os, subprocess, sys, tempfile


def git(repo, *args):
    subprocess.run(["git", "-C", repo, "-c", "user.name=Test", "-c", "user.email=test@example.com",
                    "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + list(args),
                   check=True, capture_output=True)


def main():
    root, scenario_path = sys.argv[1], sys.argv[2]
    scenario = json.load(open(scenario_path, encoding="utf-8"))
    definition = scenario["definition"]
    if isinstance(definition, str):
        definition = json.load(open(os.path.join(root, definition), encoding="utf-8"))
    if scenario.get("phases"):
        definition = dict(definition, phases=[p for p in definition["phases"] if p["id"] in scenario["phases"]])
    work = tempfile.mkdtemp()
    repo, cache = os.path.join(work, "repo"), os.path.join(work, "cache")
    os.makedirs(repo); os.makedirs(cache)
    git(repo, "init", "-q"); git(repo, "checkout", "-q", "-b", "main")
    open(os.path.join(repo, "readme.txt"), "w").write("one\n")
    git(repo, "add", "-A"); git(repo, "commit", "-q", "-m", "first")
    git(repo, "symbolic-ref", "refs/remotes/origin/main", "refs/heads/main")
    git(repo, "checkout", "-q", "-b", "test/replay")
    open(os.path.join(repo, "fix.txt"), "w").write("fixed\n")
    git(repo, "add", "-A"); git(repo, "commit", "-q", "-m", "the fix")
    head = subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    runner = os.path.join(root, "skills/run-workflow/scripts/workflow.py")
    env = dict(os.environ, XDG_CACHE_HOME=cache, PYTHONDONTWRITEBYTECODE="1")
    for key in ("CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID", "GIT_DIR", "GIT_WORK_TREE"):
        env.pop(key, None)

    def call(command, request):
        done = subprocess.run([sys.executable, "-B", runner, command], input=json.dumps(dict(request, session="replay")),
                              capture_output=True, text=True, env=env, cwd=repo)
        if done.returncode != 0:
            raise SystemExit("runner %s exit %d: %s" % (command, done.returncode, done.stderr.strip()))
        return json.loads(done.stdout)

    script = [dict(e, used=False) for e in scenario["script"]]
    answers = list(scenario.get("answers", []))
    issued, stops, reports = [], [], 0
    answer = call("start", {"definition": definition, "context": dict(scenario["context"], cwd=repo)})
    outcome = None
    for _ in range(200):
        reports += len(answer.get("reports") or [])
        action = answer.get("action")
        if action == "run":
            step = answer["step"]
            issued.append([step["id"], step["attempt"]])
            entry = next((e for e in script if not e["used"] and e["step"] == step["id"]), None)
            if entry is None:
                raise SystemExit("no scripted output left for step %s (attempt %d)" % (step["id"], step["attempt"]))
            entry["used"] = True
            answer = call("done", {"stepId": step["id"], "attempt": step["attempt"],
                                   "output": entry["output"].replace("{head}", head)})
        elif action == "stopped":
            stops.append(answer.get("stepId"))
            if not answers:
                outcome = "stopped"; break
            answer = call("resume", {"answer": answers.pop(0)})
        elif action == "finished":
            outcome = answer.get("outcome"); break
        else:
            raise SystemExit("unexpected answer %r" % (answer,))
    expect = scenario["expect"]
    got = {"order": issued, "outcome": outcome, "stops": stops}
    want = {k: expect[k] for k in ("order", "outcome", "stops")}
    if "reportCount" in expect:
        got["reportCount"], want["reportCount"] = reports, expect["reportCount"]
    if got != want:
        print("got %s, want %s" % (json.dumps(got), json.dumps(want)))
        sys.exit(1)
    print("%d steps issued, %d stops, outcome %s" % (len(issued), len(stops), outcome))


if __name__ == "__main__":
    main()
