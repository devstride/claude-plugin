---
name: risk-check
description: "Check a built change for risk before review; fix what matters, report the rest."
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/step-skills.md` first: the rule every step skill follows.

Arguments: $ARGUMENTS — one JSON object, the `risk-check@1` payload
(`${CLAUDE_PLUGIN_ROOT}/schemas/step-contracts.json`): `item`, `profile`, `reviewMoment`
(`release-deferred` or `pr-boundary`), `workingBase`, `build` (the build step's result: its four
lists, scope line and head) and `answer` (a person's reply to this step's question, or null).
**Read `${CLAUDE_PLUGIN_ROOT}/skills/risk-check/references/story-risk-check.md` in full before
inspecting the diff**: every rule below is spelled there.

## Verdict

`RISK CHECK: CLEAR | FIXED [<count>] | NEEDS DECISION <question> | BLOCKED [<reason>]`

## Steps

1. Inspect the hand-written diff of the story against `origin/<workingBase>` once, generated files
   excluded. No `reviewMoment` (a standalone run) → run the check anyway and report the missing
   caller context; never assume a full review followed.
2. Every story: the main agent's own self-check.
3. The DIFF decides, under every profile: sign-in or authorization, a migration or irreversible
   state change, or a deployed-runtime contract → focused verifiers (at most two, grouped by
   boundary); each matching `review.mandatoryLenses` entry → its own verifier, even on a routine
   diff.
4. A configured `review.localAssistCommand` may add one read-only, advisory call.
5. Fix every verified P1 or serious P2 and re-verify with the cumulative ledger, with no numeric cap;
   then apply the profile's `fixFloor`. A stall → `BLOCKED`, for a person.
6. Leave nothing unaccounted for: each unfixed finding is deferred with a home, put on the
   untracked list, or dismissed with its reason.
7. A genuinely ambiguous risky finding → `NEEDS DECISION` with the question and your recommendation;
   with `answer` set, apply it and finish.
8. Write the story review ledger and the one-line report; commit fixes per
   `commitConventions.reviewFixFormat`.

`FIXED` counts the findings fixed; `CLEAR` means none needed fixing.

## Result

After the verdict and its evidence, one fenced `json` block: `ledger`, `report`, `counts` (whole
numbers: `raised`, `fixed`, `deferred`, `dismissed`), `untrackedDeferrals`, `dismissed`, and
`proof`: `base` and `head` (the full commits checked), `triggers` (each immediate-risk boundary and
`lens:<name>` matched; empty for a routine diff), `verifiers` (how many ran) and `lenses` (the
names of the lenses that ran). A proof naming a trigger with no verifier is refused.

**Step rules.** This step only; verdict first; safe to re-run (it checks the diff as it is); config
wins; it starts no subagent beyond its verifiers and never decides what runs next.
