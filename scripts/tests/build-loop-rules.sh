#!/bin/bash
# scripts/tests/build-loop-rules.sh — the Build loop's rules that live only in prose, each in the
# home the step that applies it reads, and the wordings that once broke them gone. Each entry names
# what goes wrong without it. White space and bold markers are collapsed before matching.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PYTHONDONTWRITEBYTECODE=1
python3 - "$ROOT" <<'PY'
import os, re, sys

ROOT = sys.argv[1]
flat = lambda text: re.sub(r"\s+", " ", text.replace("**", ""))
read = lambda path: flat(open(os.path.join(ROOT, path), encoding="utf-8").read())
RS = "skills/build-item/references/run-stops.md"
BI, MP, RR, LC = "skills/build-item/SKILL.md", "skills/merge-story/references/merge-paths.md", \
    "skills/review-story/references/review-routes.md", "skills/local-checks/SKILL.md"

# (home, text that must be there, what goes wrong without it)
MUST = [
    (BI, "never issues the merge without a current risk check (of the story as it now stands: any later commit that changes it",
     "a gate or review fix lands unscreened"),
    ("skills/risk-check/references/story-risk-check.md", "screens only the delta `previousProof.head..HEAD`",
     "a re-issued risk check re-screens the whole story, or nothing"),
    ("skills/risk-check/references/story-risk-check.md", "and still runs every diff-triggered floor on it",
     "a delta that adds a migration skips its verifier"),
    (RS, "Keep the lease (`checkout-pool-commands.md`: a STOP this session will resume keeps it)",
     "a resumable stop hands the checkout back"),
    (BI, "Terminal exit or hand-over only: `return-checkout`, after its own check: `git checkout <working base> && git pull --ff-only`",
     "the checkout is returned dirty after a stop that never reached the sync"),
    (BI, "after `return-checkout` when this run leased and nothing was built in it",
     "a named story held by another agent keeps an unused checkout"),
    (BI, "`resume` with the item first", "a cleared conversation starts a duplicate run and loses the original"),
    (BI, "A `start` refused `run-open` means a run exists: `resume` it", "the refusal is read as a stop"),
    (BI, "An unfinished run first.", "the merged-or-Done guard drops an interrupted run's completion steps"),
    (BI, "Any other stop: read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/run-stops.md` in full before acting on it",
     "the stop rules are never loaded"),
    (BI, "every `next`, `done`, `status` and `resume` names the `item`", "two open runs make each command ambiguous"),
    (RS, "first check whether the commit landed", "a landed merge is resumed and asks for its checks again"),
    (RS, "then `git push --force-with-lease` it", "the moved branch diverges from its pushed copy and the branch step fails"),
    (BI, "selection passes over it until the hold lifts", "a release-held story is rebuilt by the next selection"),
    ("skills/build-item/references/next-unblocked.md", "It also skips a candidate held for release",
     "a release-held story is selected again"),
    (MP, "Landed means landed", "a merge that landed answers BLOCKED and the run cannot recover"),
    (MP, "Never leave HEAD on the local merge commit", "a refused push sends the merge round until its attempts run out"),
    (MP, "another tree (the base moved under an unchanged patch) → `--from` refuses unequal trees",
     "the durable proof is carried to a tree it does not match"),
    (MP, "story merging onto an epic's integration branch is not held", "epic stories stop accumulating under a hold"),
    ("skills/merge-story/SKILL.md", "on a landing onto the train or the base branch only (an epic-branch story accumulates under a hold)",
     "the step summary holds every merge"),
    ("skills/merge-story/SKILL.md", "the review's proof (`reviewProof`)", "after a compaction the merge cannot find the reviewed head"),
    (LC, "`generated.toleratedTypeErrors` is tolerated", "every story with a tolerated generated error fails its gate"),
    (LC, "unless `profileOverrides.storyVerify` (`touched` | `full`) pins it", "an operator's override never reaches the gate"),
    (LC, "`route` `train`, `reviewMoment` `release-deferred`", "the train's full-width rule is decided after the gate ran"),
    (RR, "Nothing configured locally (the payload's `localChecks` proof kind `none-configured`) → the pull-request path, on the release train too",
     "a train one-off with nothing configured reaches a dead end"),
    (RR, "Re-enter through `pr` driven, naming that pull request", "a re-review flips the pull request ready before the pre-ship checks"),
    ("skills/pr/SKILL.md", "Re-entry on a pull request already open", "pr opens a second pull request on a re-review"),
    ("skills/risk-check/SKILL.md", "config's `conventionsDoc` (binding) and `lessonsDoc`", "the risk check applies conventions it never loaded"),
    ("skills/risk-check/SKILL.md", "`${CLAUDE_PLUGIN_ROOT}/skills/ultracode-build/references/engineering-economy.md`",
     "verifier models are chosen without the economy contract"),
    ("skills/story-lifecycle/references/complete.md", "the `deviations` of the build, the risk check and the review",
     "a deviation found in review is reported as shipped as specified"),
    ("skills/story-lifecycle/references/complete.md", "its source the payload's `profileSource`", "the report cannot say where the profile came from"),
    ("skills/capture-findings/SKILL.md", "puts their `deferrals` (each owned by an existing item) on their owners",
     "a deferral owned by an existing item is lost"),
    ("skills/build-item/references/workflow-reports.md", "send the REFUSED object again with that `definition` added",
     "a batch refused for want of the definition is lost"),
    ("skills/release/references/step-skills.md", "goes on the evidence line below it, never on the verdict line",
     "a NOT CONFIGURED verdict with a detail is refused as no verdict"),
    ("skills/ultracode-build/SKILL.md", "Already built.", "a re-routed one-off is built twice"),
    ("skills/branch-feature/SKILL.md", "A pull that cannot fast-forward", "a diverged branch is merged or reset"),
]
# (home, text that must be gone, the fault it was)
GONE = [
    (BI, "exit through step 7's terminal exit", "every stop handed the checkout back"),
    (BI, "a run already open for this item → `resume` instead", "status sees only this session, so the original run was never found"),
    ("skills/ultracode-build/SKILL.md", "toleratedTypeErrors", "the tolerance sat in a step that no longer runs the gate"),
    (RR, "## The gate's width", "the width was decided in a file read after the gate"),
    (RR, "Invoke `review` driven on it", "the re-review skipped the pre-ship hold"),
    ("skills/release/references/step-skills.md", "naming the generic default that applies instead; the caller continues",
     "it invited a detail on a verdict that takes none"),
    ("skills/pr/references/pre-ship-hold.md", "refuses to merge", "build-item no longer merges"),
    ("skills/build-item/references/verification-receipts.md", "`ultracode-build` returns the final story receipt",
     "the receipt moved to local-checks"),
    ("skills/run-workflow/scripts/workflow.py", "resume to check what changed", "a landed merge cannot be resumed"),
]
problems = []
for home, text, why in MUST:
    if flat(text) not in read(home):
        problems.append("%s lacks %r (%s)" % (home, text, why))
for home, text, why in GONE:
    if flat(text) in read(home):
        problems.append("%s still says %r (%s)" % (home, text, why))
for problem in problems:
    print("  FAIL %s" % problem)
if not problems:
    print("  ok   %d Build loop rules are in their homes and %d broken wordings are gone" % (len(MUST), len(GONE)))
sys.exit(1 if problems else 0)
PY
