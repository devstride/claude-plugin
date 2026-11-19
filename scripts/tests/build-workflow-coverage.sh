#!/bin/bash
# scripts/tests/build-workflow-coverage.sh — every imperative that stood in build-item steps 1 to
# 6.5, or in ultracode-build's gate bullets and risk-check phase, before the Build loop became a
# step list, now lives in exactly one of the Build step skills or their references, and no longer
# in either of those two bodies. The base is PINNED to the last release before the move (never the
# moving main, which holds the moved bodies once merged); whitespace, line wraps and bold markers
# are collapsed before matching. A needle that named an old step number, or was reworded, has NEW
# wording (one text or several, each required), checked in place of the old one. The needles are
# copied from the old text, never retyped, and each carries its imperative, not only its heading:
# a rule cut down to its bold lead-in fails. Every reference that is a home must also be LOADED at
# its step: its step skill names it in a "read ... in full" instruction.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BASE="${BUILD_SPLIT_BASE:-devstride--v4.2.0}"
if ! git -C "$ROOT" rev-parse --verify -q "$BASE^{commit}" >/dev/null; then
  echo "  FAIL the base $BASE is not in this clone: run \`git fetch origin tag $BASE\` (or set BUILD_SPLIT_BASE to a ref that holds the bodies before the move), then run this test again — never skipped, or it proves nothing"
  exit 1
fi
export PYTHONDONTWRITEBYTECODE=1
python3 - "$ROOT" "$BASE" <<'PY'
import glob, os, re, subprocess, sys

ROOT, BASE = sys.argv[1], sys.argv[2]
BI, UB = "skills/build-item/SKILL.md", "skills/ultracode-build/SKILL.md"
STEPS = ["claim-story", "story-lifecycle", "risk-check", "local-checks", "review-story", "merge-story",
         "capture-findings", "sync-base"]
HOMES = sorted([os.path.join("skills", s, "SKILL.md") for s in STEPS]
               + [os.path.relpath(p, ROOT) for s in STEPS for p in glob.glob(os.path.join(ROOT, "skills", s, "references", "*.md"))]
               + ["skills/branch-feature/SKILL.md"])


def flat(text):
    # bold markers are dropped too, so a rule copied without its emphasis still counts as a copy
    return re.sub(r"\s+", " ", text.replace("**", ""))


def old(path):
    done = subprocess.run(["git", "-C", ROOT, "show", "%s:%s" % (BASE, path)], capture_output=True, text=True)
    return flat(done.stdout) if done.returncode == 0 else ""


def now(path):
    with open(os.path.join(ROOT, path), encoding="utf-8") as handle:
        return flat(handle.read())


OLD = {BI: old(BI), UB: old(UB)}
NOW = {path: now(path) for path in HOMES + [BI, UB]}

# (where it stood, the old text, its new home, the new wording when the old one named a step number)
N = [
    # build-item step 0's claim bullet and step 1
    (BI, "**Claim it** (`claims` set) BEFORE step 1", "skills/claim-story/SKILL.md",
     "Claim it before the item moves to In Progress"),
    (BI, "held → next candidate, named → STOP", "skills/claim-story/SKILL.md",
     "a selected story gives way to the next candidate, while a story the person named or the handoff resumed stops the run"),
    (BI, "`item-status.py decide`, `event: start`", "skills/story-lifecycle/references/start.md",
     "item-status.py decide` the request with `event: start`"),
    (BI, "its step 0 places the item first", "skills/story-lifecycle/references/start.md", None),
    (BI, "confirm it moved before branching", "skills/story-lifecycle/references/start.md", None),
    # step 2
    (BI, "passing the working base explicitly", "skills/branch-feature/SKILL.md", None),
    # step 3
    (BI, "a verification receipt keyed to the final tree", "skills/local-checks/SKILL.md",
     "the SHA-keyed verification receipt for the final tree"),
    # step 4, 4a, 4b
    (BI, "the working base picks the path, never the diff", "skills/review-story/references/review-routes.md",
     "The working base picks the path, never the diff"),
    (BI, "Never mix: 4a toward develop reaches production never cloud-reviewed.", "skills/review-story/references/review-routes.md",
     "Never mix: a fast review toward develop reaches production never cloud-reviewed"),
    (BI, "**THE FLOOR:** no completed `ultracode-build` risk check (immediate-risk verifiers and matched lenses included) or no valid verification receipt → 4b, saying why.",
     "skills/review-story/references/review-routes.md",
     ["THE FLOOR: no completed risk check", "immediate-risk verifiers and matched lenses included) or no valid verification receipt",
      "for this tree) → the pull-request path, saying why"]),
    (BI, "no second engine, but it owns triage, fixes and lessons", "skills/review-story/references/review-routes.md", None),
    (BI, "a small fix may skip it", "skills/review-story/references/review-routes.md", None),
    (BI, "**Fix every fix-in-story finding it returns** (its `fixFloor` triage", "skills/review-story/references/review-routes.md", None),
    (BI, "a reasoned deferral is not re-imposed", "skills/review-story/references/review-routes.md", None),
    (BI, "**Local suites are the gate** (`fastStoryMerges.requireLocalVerifyGreen`)", "skills/local-checks/SKILL.md", None),
    (BI, "an unchanged tree + command set is REUSED", "skills/local-checks/SKILL.md", None),
    (BI, "Commands and counts go in the merge-commit body", "skills/local-checks/SKILL.md", None),
    (BI, "Red is a STOP", "skills/local-checks/SKILL.md", None),
    (BI, "**No PR, no draft, no cloud request, no CI poll** — an absent check is neither pending nor skipped", "skills/review-story/references/review-routes.md", None),
    (BI, "an absent check is neither pending nor skipped", "skills/review-story/references/review-routes.md", None),
    (BI, "Never open a PR \"for the record\"", "skills/review-story/references/review-routes.md", None),
    (BI, "`review` owns the cycle target, P1/serious-P2 continuation and fix floor", "skills/review-story/references/review-routes.md", None),
    (BI, "It opens a draft wherever the repo holds CI on drafts (`prototype` too)", "skills/review-story/references/review-routes.md", None),
    (BI, "requests every in-scope cloud reviewer in the same call", "skills/review-story/references/review-routes.md", None),
    (BI, "Deferrals, deviations and dismissals (with rationale) go in the PR body", "skills/review-story/references/review-routes.md", None),
    (BI, "step 5 never reads `skipping` as green", "skills/review-story/references/review-routes.md",
     "the merge step never reads `skipping` as green"),
    # step 5, 5a, 5b
    (BI, "**Release holds first**, before any merge onto the train or `baseBranch` (one-off or plan story): a hold on the item or an ancestor",
     "skills/merge-story/references/merge-paths.md",
     ["Release holds first, before any merge onto the train or `baseBranch` (one-off or plan story",
      "a hold on the item or an ancestor (`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/release-holds.md`) → no merge"]),
    (BI, "just before 5a's or 5b's merge command", "skills/merge-story/references/merge-paths.md",
     "just before the merge command, on the head that merges"),
    (BI, "every profile, never a gate", "skills/merge-story/references/merge-paths.md", None),
    (BI, "the BODY listing each dismissed finding", "skills/merge-story/references/merge-paths.md",
     "The BODY carries the review's `mergeBody`"),
    (BI, "merge the refreshed epic INTO the story", "skills/merge-story/references/merge-paths.md",
     "merge the refreshed base INTO the story"),
    (BI, "**Only once that push SUCCEEDS** delete the story branch locally AND remotely", "skills/merge-story/references/merge-paths.md", None),
    (BI, "**The rebase already happened** in `review` step 7; rebase again only if the base moved, via `/devstride:push`",
     "skills/merge-story/references/merge-paths.md", None),
    (BI, "Compare patches: CHANGED returns to `review` with its cumulative ledger, target and safety state, never a fresh budget; tree-identical keeps its receipt and carries its proof",
     "skills/merge-story/references/merge-paths.md",
     ["Compare patches: the runner does, on the review's proof — a changed patch sends the story back through the review with its ledger",
      "an identical patch keeps the review, and the local checks rerun on the new tree", "the same tree → carry the proof"]),
    (BI, "with its cumulative ledger, target and safety state, never a fresh budget", "skills/review-story/references/review-routes.md", None),
    (BI, "RECOMPUTE `verify.skipDuringStoryBuilds` applicability", "skills/merge-story/references/merge-paths.md", None),
    (BI, "**Observe greenness**: non-draft, every applicable check succeeded — actually RAN — at the CURRENT head SHA",
     "skills/merge-story/references/merge-paths.md", None),
    (BI, "never `gh pr checks --watch`", "skills/merge-story/references/merge-paths.md", None),
    (BI, "Never merge red; never quit after one failure", "skills/merge-story/references/merge-paths.md", None),
    (BI, "an empty list settles an absent check. **Read the config before concluding either.**", "skills/merge-story/references/merge-paths.md", None),
    (BI, "**Zero unresolved threads immediately before merging** (`review`'s paginated query); else back through `review` steps 3–6",
     "skills/merge-story/references/merge-paths.md", None),
    (BI, "never the live one", "skills/merge-story/references/merge-paths.md", None),
    (BI, "never `--delete-branch` on a head matching", "skills/merge-story/references/merge-paths.md", None),
    # step 6
    (BI, "`item-status.py decide`, `event: landed`, sets status and comment", "skills/story-lifecycle/references/complete.md", None),
    (BI, "(never `mark_done`)", "skills/story-lifecycle/references/complete.md", None),
    (BI, "`startDate`/`dueDate` = branch creation → merge", "skills/story-lifecycle/references/complete.md", None),
    (BI, "A train or base landing is then quoted", "skills/story-lifecycle/references/complete.md", None),
    (BI, "**The item points at its code**: 4b — confirm the PR auto-linked, else `link_pull_request`", "skills/story-lifecycle/references/complete.md",
     "The item points at its code: pull-request path: confirm the pull request auto-linked, else `link_pull_request`"),
    (BI, "Never invent a PR number", "skills/story-lifecycle/references/complete.md", None),
    (BI, "**Reconcile as-built** on a material deviation", "skills/story-lifecycle/references/complete.md",
     ["Reconcile as-built on a material deviation",
      "read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/as-built.md` in full before acting on it"]),
    (BI, "None → report \"shipped as specified\" and write nothing", "skills/story-lifecycle/references/complete.md", None),
    (BI, "**Release the claim** (`claims` set): outcome `done`", "skills/story-lifecycle/references/complete.md",
     "Release the claim (`claims` set): `release_claim` with outcome `done`"),
    (BI, "item + `[N]`, status, dates, PR link or SHA + branch, profile + source, reconciled", "skills/story-lifecycle/references/complete.md", None),
    # step 6.5
    (BI, "any other is dismissed, never filed", "skills/capture-findings/SKILL.md", None),
    (BI, "related to the item whose review produced it", "skills/capture-findings/SKILL.md", None),
    (BI, "**Never splice a deferred finding into the chain**, under any profile", "skills/capture-findings/SKILL.md", None),
    (BI, "**Discovered scope → `/devstride:insert-story`**, spliced so selection reaches it", "skills/capture-findings/SKILL.md", None),
    (BI, "A deferral owned by an EXISTING item goes on that item", "skills/capture-findings/SKILL.md", None),
    (BI, "Report what went where", "skills/capture-findings/SKILL.md", "Report what went where: each finding and its new or existing item"),
    # step 7's first bullet
    (BI, "**assert a clean tree** — dirty → name the drift and STOP", "skills/sync-base/SKILL.md",
     ["assert a clean tree with `git status --porcelain`", "Anything listed → `DIRTY` naming the drift"]),
    (BI, "never auto-reset or `git add .`", "skills/sync-base/SKILL.md", None),
    # ultracode-build: its floors and gate bullets
    (UB, "**The immediate-risk verifier and mandatory lenses fire from the DIFF**, not the plan's theme, under every profile",
     "skills/risk-check/references/story-risk-check.md", None),
    (UB, "**Verified P1 and serious-P2 findings are always fixed** — no numeric cap; a stall STOPS for human help",
     "skills/risk-check/references/story-risk-check.md", None),
    (UB, "**Green means observed.** A red required check is stop-and-fix, never commit-anyway", "skills/local-checks/SKILL.md", None),
    (UB, "the gate's proof is a verification receipt, never a remembered result", "skills/local-checks/SKILL.md",
     "the proof is a receipt, never a remembered result"),
    (UB, "**The profile's complete `storyVerify` gate runs once on the final story SHA**", "skills/local-checks/SKILL.md",
     "The profile's complete `storyVerify` gate runs once on the final story SHA"),
    (UB, "never repeat an unchanged command on an unchanged SHA", "skills/local-checks/SKILL.md", None),
    (UB, "a type error is tolerated only in a `generated.paths` file matching `generated.toleratedTypeErrors`", "skills/local-checks/SKILL.md",
     "a type error in a `generated.paths` file matching `generated.toleratedTypeErrors` is tolerated"),
    (BI, "width = effective `storyVerify`", "skills/local-checks/SKILL.md",
     "at the profile's width (`delivery-profiles.md`) unless `profileOverrides.storyVerify` (`touched` | `full`) pins it"),
    (UB, "suites are skipped** during story builds", "skills/local-checks/SKILL.md",
     "suites are skipped during story builds"),
    (UB, "a full `verify.test` run still leaves listed suites out — except a touched spec of one of them, run directly", "skills/local-checks/SKILL.md", None),
    (UB, "SHA-keyed verification receipt", "skills/local-checks/SKILL.md", None),
    # ultracode-build phase 3, the story risk check
    (UB, "Inspect the hand-written diff against the working base once, generated files excluded", "skills/risk-check/references/story-risk-check.md", None),
    (UB, "`review-moment: release-deferred` means a fast story", "skills/risk-check/references/story-risk-check.md", None),
    (UB, "never guess that a full review happened", "skills/risk-check/references/story-risk-check.md", None),
    (UB, "gets a main-agent self-check", "skills/risk-check/references/story-risk-check.md", None),
    (UB, "launch no generic fan-out", "skills/risk-check/references/story-risk-check.md", None),
    (UB, "**Immediate risk floor.** When the DIFF touches authentication/authorization, a migration or irreversible state transition, or a deployed-runtime contract",
     "skills/risk-check/references/story-risk-check.md", None),
    (UB, "focused `opus`/`xhigh` verifier per independent boundary, maximum two", "skills/risk-check/references/story-risk-check.md", None),
    (UB, "REFUTED is the default and \"could not rule it out\" is not evidence", "skills/risk-check/references/story-risk-check.md", None),
    (UB, "The profile cannot remove this floor", "skills/risk-check/references/story-risk-check.md", None),
    (UB, "**Mandatory lenses.** A `review.mandatoryLenses` entry whose `paths` match a hand-written file is an immediate-risk boundary of its own",
     "skills/risk-check/references/story-risk-check.md", None),
    (UB, "an unmatched entry is not mentioned; a malformed one is named once and ignored", "skills/risk-check/references/story-risk-check.md", None),
    (UB, "advisory, never a second mandatory pass", "skills/risk-check/references/story-risk-check.md", None),
    (UB, "never a bare \"verified\"", "skills/risk-check/references/story-risk-check.md", None),
    (UB, "**Universal fix floor.** A verified P1 or serious P2 (defined in `review-fanout`) is fixed", "skills/risk-check/references/story-risk-check.md", None),
    (UB, "`all-confirmed` (override) — **fix every CONFIRMED and PLAUSIBLE.**", "skills/risk-check/references/story-risk-check.md", None),
    (UB, "**Nothing is silently dropped**: an unfixed finding worth filing (a P1, a security finding, or one both likely and material) is DEFERRED",
     "skills/risk-check/references/story-risk-check.md", None),
    (UB, "any other is DISMISSED with its reason, never filed. Drop REFUTED.", "skills/risk-check/references/story-risk-check.md", None),
    (UB, "regenerating artifacts if routes changed", "skills/risk-check/references/story-risk-check.md", None),
    (UB, "A genuinely ambiguous risky finding is asked about, with a recommendation", "skills/risk-check/references/story-risk-check.md", None),
    (UB, "**Story review ledger**: item-number namespace, base/head SHA", "skills/risk-check/references/story-risk-check.md", None),
    (UB, "never rediscovers or reverses a settled finding without new evidence", "skills/risk-check/references/story-risk-check.md", None),
    (UB, "**Risk-check report**, one line: profile, review moment, routine vs immediate-risk", "skills/risk-check/references/story-risk-check.md", None),
]

problems = []
for source, needle, home, new in N:
    wants = [flat(w) for w in (new if isinstance(new, list) else [new or needle])]
    if flat(needle) not in OLD[source]:
        problems.append("never in %s at %s: %s" % (source, BASE, needle))
    for wanted in wants:
        holders = [path for path in HOMES if wanted in NOW[path]]
        if holders != [home]:
            problems.append("%r should be in %s alone, is in %s" % (wanted, home, holders or "none"))
    for body in (BI, UB):
        for text in set([flat(needle)] + wants):
            if text in NOW[body]:
                problems.append("still in %s: %s" % (body, text))
    if re.fullmatch(r"\*\*[^*]+\*\*[.:,]?|`[^`]+`", needle.strip()) and new is None:
        problems.append("a bare heading or token proves nothing: carry the imperative after it: %s" % needle)

# every reference home is loaded at its step: its step skill says to read it in full
loaded = 0
for home in sorted(set(h for _, _, h, _ in N)):
    if "/references/" not in home:
        continue
    skill = os.path.join(home.split("/references/")[0], "SKILL.md")
    if not re.search(r"(?i)read\s+`\$\{CLAUDE_PLUGIN_ROOT\}/%s`\s+in\s+full" % re.escape(home), NOW.get(skill) or now(skill)):
        problems.append("%s is a home but %s never says to read it in full" % (home, skill))
    loaded += 1
for problem in problems:
    print("  FAIL %s" % problem)
if not problems:
    print("  ok   %d imperatives that stood in build-item or ultracode-build at %s live in exactly one Build step home and left both bodies;"
          " the %d reference homes are each read in full by their step skill" % (len(N), BASE, loaded))
sys.exit(1 if problems else 0)
PY
