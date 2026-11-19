---
name: local-checks
description: "Run the profile's complete local gate once on the final tree and record the receipt."
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/step-skills.md` first: the rule every step skill follows.

Arguments: $ARGUMENTS — one JSON object, the `local-checks@1` payload
(`${CLAUDE_PLUGIN_ROOT}/schemas/step-contracts.json`): `item`, `profile`, `workingBase`, `route`,
`oneOff`, `branch` and `previousProof` (this step's last proof when it runs again, else null). The
receipt rules: `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/verification-receipts.md`.

## Verdict

`LOCAL CHECKS: PASS [<count>] | NOT CONFIGURED | FAIL [<checks>]`

## Steps

1. **Commands come from config, never from memory**: `verify.*` and `preCommitWiringChecks` in
   `.claude/ds-config.json`. Nothing configured → `NOT CONFIGURED`, proof kind `none-configured`
   (the merge then accepts it only after a pull-request review, where CI is the gate).
2. **The width.** The profile's complete `storyVerify` gate runs once on the final story SHA — a
   floor whose width the profile sets
   (`${CLAUDE_PLUGIN_ROOT}/skills/plan/references/delivery-profiles.md`), widened to full for a
   train landing that gets the LOCAL-FULL review: the decision is in
   `${CLAUDE_PLUGIN_ROOT}/skills/review-story/references/review-routes.md`, section "The gate's
   width". With `fastStoryMerges.requireLocalVerifyGreen` set the fast path's merge needs this gate
   green: **Local suites are the gate**.
3. **Skipped suites.** `verify.skipDuringStoryBuilds` suites are skipped during story builds (gated
   where their entries say); an empty list skips nothing, and a full `verify.test` run still leaves
   listed suites out — except a touched spec of one of them, run directly. Name each in
   `skippedSuites`.
4. **Reuse before running**: an unchanged tree + command set is REUSED (a receipt for this exact
   tree, command list and config hash, per the receipt's validity rules); never repeat an unchanged
   command on an unchanged SHA. With
   `previousProof` set (the tree changed since), run the affected checks plus the required gate.
   Otherwise run the gate once and write the receipt.
5. **Green means observed.** A red required check is stop-and-fix, never commit-anyway. Red is a
   STOP → `FAIL` naming each failed check; the proof is a receipt, never a remembered result.

Record commands, results and counts exactly as the receipt rules define. Commands and counts go in
the merge-commit body of a fast merge, read from the receipt.

## Result

After the verdict and its evidence, one fenced `json` block: `commands` (in the order run),
`results` (`{command, status, count}` each), `receipt` (its path; null when nothing is configured),
`tree` and `head` (the full ids checked), `skippedSuites`, and `proof`: `kind` (`receipt`, or
`none-configured`), `tree`, `head` and `receipt`: the SHA-keyed verification receipt, a verification receipt keyed
to the final tree.
A pass names at least one command.

**Step rules.** This step only; verdict first; safe to re-run; config wins; it never starts a
subagent and never decides what runs next.
