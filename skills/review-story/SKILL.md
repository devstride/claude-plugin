---
name: review-story
description: "Review a built change before it lands: fast local review or the full pull-request review."
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/step-skills.md` first: the rule every step skill follows.

Arguments: $ARGUMENTS — one JSON object, the `review@1` payload
(`${CLAUDE_PLUGIN_ROOT}/schemas/step-contracts.json`): `item`, `profile`, `reviewMoment`,
`workingBase`, `route`, and the results of the risk check (`riskCheck`), the build (`build`) and
the local checks (`localChecks`). **Read
`${CLAUDE_PLUGIN_ROOT}/skills/review-story/references/review-routes.md` in full before choosing the
path**: both paths, the train's landing review and the proof are spelled there.

## Verdict

`REVIEW: SETTLED | COVERED [<reason>] | BLOCKED [<reason>]`

## Steps

1. **The path comes from `reviewMoment`**, which the loop decided and announced:
   `release-deferred` → the fast local path, `pr-boundary` → the pull-request path. Never both.
2. **The floor.** A risk check with no ledger, or local checks with no valid receipt, sends the
   story to the pull-request path, saying why.
3. **Fast path**: `review` in LOCAL-ONLY mode (LOCAL-FULL on the release train, per the reference;
   a small, clean train fix answers `COVERED` by the train's release review). Fix what it returns
   for this story, route what is worth filing, dismiss the rest with reasons. No pull request, no
   cloud request, no CI.
4. **Pull-request path**: `pr` in its driven mode, the working base pre-answered and the profile
   by name; asked again with the pull request open, `review` on it, carrying its ledger.
5. A stall, an unavailable required reviewer, or a red check `review` cannot settle → `BLOCKED`.
6. Report the fixes it made: the runner, never this step, decides what they make stale.

## Result

After the verdict and its evidence, one fenced `json` block: `path` (`fast-local` or
`pull-request`), `cycles` (a whole number; 0 when covered), `untrackedDeferrals`, `dismissed`,
`pullRequest` (its number, or null), `mergeBody` (the fast merge's body lines, or null), and
`proof`: `path`, `head` (the full reviewed commit), `base` (`origin/<workingBase>`), `patchId`
(the runner's verbatim patch id of `<base>...<head>`, computed as the reference spells) and
`pullRequest` (or null).

**Step rules.** This step only; verdict first; safe to re-run (an open pull request is reviewed
again, never opened twice); config wins; it starts no subagent beyond `review` and `pr` and never
decides what runs next.
