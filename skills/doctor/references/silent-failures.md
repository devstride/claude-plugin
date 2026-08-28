# Silent failures — why doctor exists, and the long-form explanations

The checks live in the body; this file holds the symptom table and the extended reasoning, read
when writing the "what it breaks" line of a FAIL.

## Every prerequisite of this loop fails silently

Not one announces its own absence — each produces a confusing downstream symptom instead of an
error, usually much later:

| What is wrong | What you actually see |
|---|---|
| `gh` missing or not logged in | The loop gets as far as opening a pull request, then fails |
| Signed out of DevStride | "I can't find any DevStride tools" — no prompt, no auth error |
| A typo in `ds-config.json` | Nothing. The key reads as absent and the skill improvises |
| Workflows missing `ready_for_review` | The ready-flip creates **no run at all**; the loop waits forever |
| Workflow jobs not gated on draft | CI runs on open and again after every fix — the run-once design never engages |
| `verify.test` unset with fast merges on | Items merge with no LOCAL gate — under fast mode the local suites are the only gate the item itself gets |
| `statusLine` set to a script that is not there | A blank status line. No error, no warning — it simply renders nothing |
| A status line set only in `~/.claude/settings.json` | It renders perfectly for the person who set it up and for nobody else. Every other clone is blank, and the author has no way to see that |
| `stage.resolve` printing more than one line | The wrong stage renders, confidently, wherever a stage is shown |
| `profile: prototype` beside a hand-set `autoRelease: false` | The loop stops at release-ready and the profile looks ignored. It is not — the explicit key wins, and nothing says so |

The value of doctor is not the checks. It is turning silence into a sentence.

## §4 — why the branch-role check argues the way it does

Explicit configured names win even when unconventional, because a heuristic that overwrites a
valid explicit choice destroys the one thing the config exists to record. The candidate
vocabulary applies only to ABSENT-key fallbacks that point at branches which do not exist —
there the shipped default (`develop`/`master`) is aimed at a ref that is not there, and the
loop's first checkout, hotfix or release would fail at a distance from its cause. Whole-name
matching matters because `production-fix` is not `production` and `contest` is not `test`; and
the first list entry is never picked because candidate order is vocabulary, not ranking.

## §4 — why a profile contradiction is informational

A present key wins over the profile by contract, so `profile: prototype` beside a hand-set
`autoRelease: false` is working as designed — but someone who chose `prototype` for its speed
and meets a release-ready stop debugs the wrong thing unless doctor says which key, which
value, and what the profile would have written. A present `review.localCommand` under
`prototype` is not a contradiction at all: the contract says it names the engine without
scheduling it — the engine still reviews release and PR paths and simply gets no rounds on
fast-mode stories.

## §5 — the four-events trap and the tree skip

The evidence behind the four-events rule — why `ready_for_review` is missing from GitHub's
defaults, why an explicit `types` list REPLACES the defaults, why `opened` looks droppable and
is not, and what `converted_to_draft` buys — lives in
`${CLAUDE_PLUGIN_ROOT}/skills/setup/references/detector-evidence.md` §A5 (one home, two
citers). The tree-identical skip is judged on whether it CAN FIRE because the failure shape is
"present but inert": the step exists, fires while the base tip has not moved (the fallback
path), and silently stops as soon as it has — a step-exists test calls it done while
`ci-audit` shows the minutes unexplained. A step in a job with no checkout is harsher: it
fails the gate job and everything that `needs` it on every production push.

## §4 — why stage is reported, never inferred

A stage is the only thing in the config naming infrastructure that already exists and that the
loop does not own: `localEnvironment` describes instances the loop creates and destroys, while
`stage.resolve` reads a stack somebody else provisioned. So doctor runs the command and reports
what it says, and refuses two tempting shortcuts. It never derives a stage from the branch name,
because a branch is not proof of what deploys and a confidently wrong "prod" is worse than
silence. And it never reports `localEnvironment.instanceName`'s answer as the stage: both produce
a per-checkout name, so the substitution reads perfectly and is wrong in the one direction that
matters.

## §6 — why the fix must match their config

`epicIntegrationBranches.enabled: false` only changes anything when the working base is being
derived per-epic; an explicit `integrationBranch` value takes precedence over the flag
entirely, so with one set, flipping the flag changes nothing — which is why the body checks
`integrationBranch` first and names which case applies.

## Cited by

- `skills/doctor/SKILL.md` — the pointer under "How to report" ("Read … when writing the 'what
  it breaks' line of a FAIL").
