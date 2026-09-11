---
load: rationale
---
# Silent failures — why doctor exists, and the long-form explanations

The checks live in the body; this file holds the symptom table and the extended reasoning, read
when writing the "what it breaks" line of a FAIL.

## Every prerequisite of this loop fails silently

Not one announces its own absence — each produces a confusing downstream symptom instead of an
error, usually much later:

| What is wrong | What you actually see |
|---|---|
| `gh` missing or not logged in | The loop gets as far as opening a pull request, then fails — no pull requests, no review threads, no ready-flip |
| `python3` missing from `PATH` | The session-start version check never runs, and the reviewer wait exits immediately with a usage-error `RESULT` that reads like a finished wait |
| Two DevStride MCP servers connected | Tools exist under two namespaces (`mcp__devstride__*` and `mcp__plugin_devstride_devstride__*`), so calls can land in either organization and nothing says which |
| Signed out of DevStride | "I can't find any DevStride tools" — no prompt, no auth error |
| A typo in `ds-config.json` | Nothing. The key reads as absent and the skill improvises |
| Workflows missing `ready_for_review` | The ready-flip creates **no run at all**; the loop waits forever |
| Workflow jobs not gated on draft | CI runs on open and again after every fix — the run-once design never engages |
| `verify.test` unset with fast merges on | Items merge with no LOCAL gate — under fast mode the local suites are the only gate the item itself gets |
| `statusLine` set to a script that is not there | A blank status line. No error, no warning — it simply renders nothing |
| A `statusLine` in `.claude/settings.local.json` | The personal line masks the shared one while the shared script's direct test still passes |
| A status line set only in `~/.claude/settings.json` | It renders perfectly for the person who set it up and for nobody else. Every other clone is blank, and the author has no way to see that |
| `stage.resolve` printing more than one line | The wrong stage renders, confidently, wherever a stage is shown |
| `profile: prototype` beside a hand-set `autoRelease: false` | The loop stops at release-ready and the profile looks ignored. It is not — the explicit key wins, and nothing says so |
| `autoRelease: "ask"` beside a profile that writes `true` or `false` | Nothing errors and nothing is wrong: at zero remaining leaves the build pauses to ask per release unit. Read as a two-valued key it looks like a stall, or like `true` that failed to fire |

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

## §4 — why `autoRelease` has three values, and why the table is enough

`true` and `false` decide the release-unit merge in advance; `"ask"` defers the decision to the
moment it is made — at zero remaining leaves `build-item` stops and asks, per release unit, before
merging. So doctor treats a present `"ask"` exactly as it treats a present `true` or `false`: a
legal explicit value that wins over the profile, informational when it differs from what the
profile would have written, never a type error. The comparison itself needs only the
`| Key | prototype | standard | enterprise |` table at the top of
`${CLAUDE_PLUGIN_ROOT}/skills/setup/references/config-defaults.md`; the rest of that file is the
shipped JSON and its commentary, and reading all 27KB of it to compare three keys is load the
report never uses.

## §5 — why the gate test stops at the first gated dependency

Real workflows gate one cheap job and fan the result out, and GitHub's default job condition
requires every dependency to *succeed*, so one skipped dependency skips the dependent. Requiring
the whole `needs` closure to be gated is therefore the wrong test, and false-FAILs exactly the
layout the draft gate exists for: a gated job beside an ungated utility job, both feeding the
expensive one. The exception is a job that opts out of that default — `if: always()` or similar —
which runs whatever its dependencies did and is genuinely ungated. The cost of missing a real
ungated job is not an error but a bill: CI fires on open and again on every review-fix push, and
the run-once guarantee is gone without anything reporting it.

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

## §6 — why a missing read-only flag is a FAIL, and why the migration is a tradeoff

A review engine's sandbox flag is the only thing standing between "second opinion" and "an agent
with write access to the tree it is judging". Where the flag is absent the command does not fail —
it inherits the machine's own default, which is a per-machine setting no repository can see. In a
field run that default was the fully permissive one, and a review round wrote files into the
checkout under review, including one carrying a live credential. That is why
`${CLAUDE_PLUGIN_ROOT}/skills/setup/scripts/check-review-engine.sh` reports the default it found
alongside the missing flag, and why a catalogued engine — one whose read-only flag is known — is a
FAIL rather than a warning when the flag is not there. The flags are not interchangeable between
subcommands of the same CLI, which is the whole reason the script exists rather than a grep: a
non-interactive exec subcommand may take `--sandbox read-only` while the review subcommand refuses
`--sandbox` outright and needs the equivalent config override. An engine the catalogue does not
know cannot be checked this way at all, so it is UNVERIFIABLE with the contract restated — being
unrecognised is never itself a fault.

Migrating a legacy base-only command to context mode is a tradeoff rather than an upgrade. Context
mode buys the cumulative ledger, so cycle N+1 can check whether the previous fix held; a base-only
invocation cannot be fed one and gets a single cycle. But some engines' dedicated review
subcommands return a structured findings item that the general exec path does not, and that
structure is lost in the move. Where `review.maxLocalReviewRounds` is 1 there is no cycle N+1 to
buy, so the ledger is worth nothing and only the loss remains. Say which side the repository is on
instead of recommending the migration flatly.

## §6 — why the fix must match their config

`epicIntegrationBranches.enabled: false` only changes anything when the working base is being
derived per-epic; an explicit `integrationBranch` value takes precedence over the flag
entirely, so with one set, flipping the flag changes nothing — which is why the body checks
`integrationBranch` first and names which case applies.

## Cited by

- `skills/doctor/SKILL.md` — the pointer under "How to report" ("Read … when writing the 'what
  it breaks' line of a FAIL").
