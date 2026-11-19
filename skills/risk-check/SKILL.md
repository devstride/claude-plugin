---
name: risk-check
description: "Check a built change for risk before review; fix what matters, report the rest."
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/step-skills.md` first: the rule every step skill follows.

Arguments: $ARGUMENTS — one JSON object, the `risk-check@1` payload
(`${CLAUDE_PLUGIN_ROOT}/schemas/step-contracts.json`): `item`, `profile`, `reviewMoment`,
`workingBase`, `build` (the build's result), `answer` (a person's reply, or null), and
`previousProof` and `previousResult` (its last ACCEPTED screen; null: a full screen) and
`baselineUnreadable` (true: screen in full). **Read
`${CLAUDE_PLUGIN_ROOT}/skills/risk-check/references/story-risk-check.md` in full before
inspecting the diff**: every rule below is spelled there. Then load, once per story and after a
compaction, what it applies: config's `conventionsDoc` (binding) and `lessonsDoc` (fallback
`.claude/ds-lessons.md`, advisory), and, before choosing a verifier's model or effort,
`${CLAUDE_PLUGIN_ROOT}/skills/ultracode-build/references/engineering-economy.md`.

## Verdict

`RISK CHECK: CLEAR | FIXED [<count>] | NEEDS DECISION <question> | BLOCKED [<reason>]`

## Steps

1. Inspect the hand-written diff of the story against `origin/<workingBase>` once, generated files
   excluded. `previousProof` set → only the story's own change since its `head`, floors included,
   never upstream work ("Screened again"). No `reviewMoment` (a standalone run) → check anyway,
   reporting the missing caller context; never assume a full review followed.
2. Every story: the main agent's own self-check.
3. The DIFF decides, every profile: sign-in or authorization, a migration or irreversible
   state change, or a deployed-runtime contract → focused verifiers (at most two, grouped by
   boundary); each matching `review.mandatoryLenses` entry → its own verifier, even on a routine
   diff.
4. A configured `review.localAssistCommand` may add one read-only, advisory call.
5. Fix every verified P1 or serious P2 and re-verify with the cumulative ledger, no numeric cap;
   then apply the profile's `fixFloor`. A stall → `BLOCKED`, for a person.
6. Nothing unaccounted for: each unfixed finding is deferred with a home, untracked, or dismissed
   with its reason.
7. A genuinely ambiguous risky finding → `NEEDS DECISION` with the question and your recommendation;
   with `answer` set, apply it and finish.
8. Write the story review ledger and the one-line report; commit fixes per
   `commitConventions.reviewFixFormat`.

`FIXED` counts the fixes; `CLEAR`: none needed.

## Result

After the verdict and its evidence, one fenced `json` block: `ledger`, `report`, `counts` (whole
numbers: `raised`, `fixed`, `deferred`, `dismissed`), `untrackedDeferrals`, `dismissed`,
`deferrals` (each with its home and why), `deviations` (how the story now differs from its
spec), each entry with an `id`, `resolved` (earlier ids fixed or overtaken), and `proof`: `base` (`origin/<workingBase>`, never a commit id) and `head` (HEAD after your own fixes), `triggers` (each immediate-risk boundary and
`lens:<name>` matched; none: empty), `verifiers` (how many ran) and `lenses` (the
names of the lenses that ran); a trigger needs a verifier.

**Step rules.** This step only; verdict first; safe to re-run (it checks the diff as it is); config
wins; it starts no subagent beyond its verifiers and never decides what runs next.
