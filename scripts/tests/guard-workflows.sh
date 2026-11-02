#!/bin/bash
# Tests for the two pull-request workflows: the three required checks exist under their exact
# names, release-guard waits for the ready-flip, and the pull_request_target guards never run the
# pull request's own code or splice its text into a script. Plain-text checks, so no YAML library
# is needed on any machine.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; W="$ROOT/.github/workflows"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
RESULT="$(mktemp)"; trap 'rm -f "$RESULT"' EXIT

# Written to a file, not captured with $( ): bash 3.2 misparses a quoted heredoc inside one.
python3 - "$W/release-guard.yml" "$W/public-repo-guards.yml" > "$RESULT" <<'PY'
import re, sys
rg, guards = (open(p, encoding="utf-8").read() for p in sys.argv[1:3])
problems = []
def need(cond, msg):
    if not cond:
        problems.append(msg)
names = re.findall(r"^    name: (\S+)$", rg + "\n" + guards, re.M)
for check in ("release-guard", "merge-path", "public-hygiene"):
    need(names.count(check) == 1, "the required check %r is not exactly one job name" % check)
# release-guard: CI last — nothing runs on a draft; the ready-flip starts it.
need(re.search(r"types: \[[^\]]*\bready_for_review\b", rg), "release-guard does not run on ready_for_review")
need("github.event.pull_request.draft == false" in rg, "release-guard's check job is not draft-gated")
need(re.search(r"^concurrency:", rg, re.M) and "cancel-in-progress" in rg, "release-guard has no per-PR concurrency")
need(re.search(r"^  tag:\n    if: github.event_name == 'push'$", rg, re.M), "the tag job no longer runs only on a push to main")
# public-repo-guards: pull_request_target with the base's code only.
need(re.search(r"^on:\n  pull_request_target:", guards, re.M), "public-repo-guards is not pull_request_target")
perms = re.search(r"^permissions:\n((?:  .*\n)+)", guards, re.M)
need(perms and "write" not in perms.group(1), "public-repo-guards asks for a write permission")
need(not re.search(r"^\s+permissions:", guards, re.M), "a job overrides the read-only permissions")
refs = re.findall(r"^\s+ref: (.*)$", guards, re.M)
need(refs and all(r.strip() == "${{ github.event.pull_request.base.sha }}" for r in refs),
     "a checkout is not pinned to the base commit")
need(guards.count("persist-credentials: false") == guards.count("actions/checkout@"),
     "a checkout keeps the token in the work tree")
# Untrusted text (branch name, title, body, labels) reaches a script only through env.
untrusted = re.compile(r"\$\{\{[^}]*github\.event\.pull_request\.(title|body|head\.ref|labels)")
for n, line in enumerate(guards.splitlines(), 1):
    if untrusted.search(line) and not re.match(r"^\s+[A-Z_]+: \$\{\{[^}]*\}\}\s*$", line):
        problems.append("line %d splices pull-request text outside an env entry: %s" % (n, line.strip()))
need("pull/head" in guards and not re.search(r"git (checkout|switch)", guards), "the pull request's commits are checked out")
print("\n".join(problems))
PY
OUT="$(cat "$RESULT")"
if [ -z "$OUT" ]; then ok "(1) three required checks; release-guard waits for ready; the guards run only the base's code"
else bad "(1) $OUT"; fi

exit $FAIL
