---
name: release-steps
description: "Step: one step of a Release workflow, chosen by the payload's contract."
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/step-skills.md` first: the rule every step skill follows.

**Not switched on yet.** Do a step only when the step runner issued it in a rehearsal. Asked for
alone by name → no verdict line: say releases are made with `/devstride:release`, and stop.

Arguments: $ARGUMENTS — one JSON object, the step's payload
(`${CLAUDE_PLUGIN_ROOT}/schemas/step-contracts.json`). Its reserved `contract` key names the
step; the **mode** is the contract name without `@1` (never the step id).

## Verdict

The mode's own `## Verdict`, equal to the catalog's grammar: that line first, then the evidence.

## Steps

1. **Read `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/<mode>.md` in full** and do that
   step only. The modes, by group:
   - claim and orient: `train-claim`, `tower-claim`, `ground-truth`, `release-shape`,
     `ci-hold-proof`, `merged-release`
   - the release train: `train-finish`, `ship-plan`, `train-snapshot`, `train-pr`, `train-review`,
     `train-merge`, `train-close-out`, `train-level`
   - the cut: `release-delta`, `tower-queue`, `release-branch`, `production-in-branch`,
     `release-pr`, `train-claim-hand-on`
   - checks before the tower: `release-tip`, `dev-deploy-wait`, `release-stamp`,
     `release-stamp-verify`
   - review: `release-review`, `pre-ship-resume`, `release-docs-plan`
   - the go-ahead and the merge: `hotfix-catch-up`, `previous-release`, `owner-go-ahead`,
     `owner-go-ahead-recheck`, `merge-confirmations`, `production-merge`
   - deploy and hand back: `post-deploy-pending`, `estimates-score`, `tower-hand-back`,
     `post-deploy-result`
   - close-out: `release-sync`, `release-branch-delete`, `release-docs`, `release-kb-sync`,
     `release-close-out`, `release-notes`, `release-recap`, `auto-start`
   - Any other contract, or none, or a mode with no reference file → no verdict line: say this
     skill carries only the Release steps, and stop.
2. Before a mode that has a shape or heartbeat rule, read
   `${CLAUDE_PLUGIN_ROOT}/skills/release-steps/references/resume-rules.md` once per run: what the
   payload's `shape` and `tower` mean, which modes answer `NOT APPLICABLE` for an adopted or
   merged release, and when a step heartbeats the tower and the train claim.

**Floors.** Never proceed uncleared; a hotfix never claims; a yes is read only from the
payload's `answer`; never force-push or `--delete-branch` a protected branch.

## Result

After the verdict and its evidence, one fenced `json` block holding the keys its reference names.

**Step rules.** One step per call; verdict first; safe to re-run; config wins; it never decides
what runs next, and starts no subagent except the review engines a review mode runs through
`pr` and `review`.
