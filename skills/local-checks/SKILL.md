---
name: local-checks
description: "Run the profile's complete local gate once on the final tree and record the receipt."
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/step-skills.md` first: the rule every step skill follows.

Arguments: $ARGUMENTS — one JSON object, the `local-checks@1` payload
(`${CLAUDE_PLUGIN_ROOT}/schemas/step-contracts.json`): `item`, `profile`, `workingBase`, `route`,
`oneOff`, `branch`, `previousProof` (its last proof, or null) and `reviewMoment`. **Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/verification-receipts.md`
in full before the first command**: the receipt rules.

## Verdict

`LOCAL CHECKS: PASS [<count>] | NOT CONFIGURED | FAIL [<checks>]`

## Steps

1. **Commands come from config, never from memory**: `verify.*` and `preCommitWiringChecks` in
   `.claude/ds-config.json`. Nothing configured → `NOT CONFIGURED`, proof kind `none-configured`
   (the review then takes the pull-request path, CI its gate).
2. **The width**, decided here before anything runs. The profile's complete `storyVerify` gate
   runs once on the final story SHA, at the profile's width (`delivery-profiles.md`) unless
   `profileOverrides.storyVerify` (`touched` | `full`) pins it, a train one-off too. **The full suite
   runs only where it is needed**: when a change is broad (the repository's own gate decides, where it
   does), and once in CI on the pull request that carries the work to the release source; never as a
   second pass after a passing gate. **Local suites are the gate** (`fastStoryMerges.requireLocalVerifyGreen`).
3. **Skipped suites.** `verify.skipDuringStoryBuilds` suites are skipped during story builds (gated
   where their entries say); an empty list skips nothing, and a full `verify.test` run still leaves
   listed suites out — except a touched spec of one of them, run directly. Name each in
   `skippedSuites`.
4. **Reuse before running**: an unchanged tree + command set is REUSED (the receipt's validity
   rules); never repeat an unchanged command on an unchanged SHA. With `previousProof` set (the
   tree changed since), the affected checks plus the required gate (after a base merge, the gate
   alone, never wider); else the gate once; then the receipt.
5. **Green means observed.** A red required check is stop-and-fix, never commit-anyway. Red is a
   STOP → `FAIL` naming each failed check; the proof is a receipt, never a remembered result.
   **Generated files**: a type error in a `generated.paths` file matching
   `generated.toleratedTypeErrors` is tolerated, named in the evidence (the generator owns it,
   fixed by `generated.regenCommand`, never by hand); any other is red.

Commands and counts go in the merge-commit body of a fast merge, read from the receipt.

## Result

After the verdict and its evidence, one fenced `json` block: `commands` (in the order run),
`results` (`{command, status, count}` each), `receipt` (its path; null when nothing is configured),
`tree` and `head` (the full ids checked), `skippedSuites`, and `proof`: `kind` (`receipt`, or
`none-configured`), `tree`, `head` and `receipt`: the SHA-keyed verification receipt for the final tree.
A pass names at least one command.

**Step rules.** This step only; verdict first; safe to re-run; config wins; it never starts a
subagent and never decides what runs next.
