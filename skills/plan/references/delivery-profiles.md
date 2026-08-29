# Delivery profiles — CANONICAL CONTRACT

The single authoritative definition of the **delivery profile**: the one user-facing choice that
sets how much rigor the loop spends per unit of work — how finely a plan is sliced, how deep each
spec goes, how wide the adversarial review fans out, the normal review-cycle target, and which gates a
story passes before it merges. Every skill that plans, builds, reviews, or rebalances reads the
profile through THIS file by citation; none restates the table.

## Why one choice, not many knobs

The values below are coupled. Coarse stories with an enterprise-grade review fan-out is the worst
combination: each large diff draws dozens of findings and the loop spends longer than it would on
finer stories. Fine stories with a prototype review is merely wasteful. So the user picks **one
word**, and the knobs move together. Individual knobs can still be overridden (see
[Overrides](#overrides)) — for tuning, not as the primary interface.

## The three profiles

| Knob | `prototype` | `standard` (default) | `enterprise` |
|---|---|---|---|
| **Who it is for** | A small team validating an idea; no production users yet; small errors are cheap | The default for a working product | Regulated, revenue-bearing, or shared-platform code where a missed defect is expensive |
| `grain` — leaf sizing | **One story per vertical slice a user can see or use.** Scaffold, CI, schema and harness work is folded into the first slice that needs it, never its own story | Roughly 1–2 loop-hours: one contract or one subsystem change with its tests | Roughly one loop-hour; foundation work (schema, harness, CI) stands as its own story |
| `specDepth` — leaf description | Goal, acceptance criteria, the files it touches, Definition of Done. **Cap ~1,500 characters** | The full leaf template (`plan` step 3, Stage C). **Cap ~5,000 characters** | The full leaf template, uncapped |
| `understandReaders` — `ultracode-build` phase 1 fan-out | **0** — read the relevant files inline, no Workflow | **≤ 2** readers, only for angles the spec does not pin | Up to the six the skill defines |
| `reviewBreadthCeiling` — generic finder breadth at a merge gate | **NARROW** | **CONTAINED** | HIGH-RISK when the diff warrants it |
| `verificationDefault` | REFUTED unless reproducible | REFUTED unless reproducible | REFUTED unless reproducible |
| `verificationGrouping` — how HIGH-RISK verification fans out | `per-file` | `per-file` | `per-file` |
| `fixFloor` — additional profile floor after the universal P1/serious-P2 floor | **`p1-security`**: P1 correctness and any security finding. Everything else is deferred with a one-line rationale (to the item that owns it, or the untracked-deferral list) | **`likely-important`**: findings that are both likely to occur and material if they do. The rest is dismissed with a rationale | **`all-confirmed`**: every CONFIRMED and PLAUSIBLE finding |
| `localCliEngine` — where a configured local CLI reviewer runs | Every direct-PR or release-PR merge boundary; never a fast story with no PR | Same | Same |
| `maxLocalReviewRounds` — local-engine target inside the normal cycle target | **1** | **1** | **2** |
| `targetAdversarialCycles` — fixed, non-overrideable target across every reviewer/recheck | **2** | **2** | **2** |
| `storyVerify` — the local gate before a story merges | Type-checks + touched suites (`verify.testSingle`, widened when broad); full `verify.test` at release PR | Same; full `verify.test` at release PR | Type-checks + full `verify.test` + `verify.lint` where applicable |
| `perStoryPullRequest` | Fast mode — no per-story PR — whenever `fastStoryMerges.enabled` is absent or `true`; the story risk check and green gate qualify its integration-branch merge, and the release-PR review holds the batch from the base branch. A present `false` wins and is reported | Per `fastStoryMerges.enabled` | Per `fastStoryMerges.enabled` |
| `fastStoryMerges.enabled` (default written by `setup`) | **true** whenever `verify.typecheck` is set | `true` when `verify.test` and `verify.typecheck` are set; else `false`, saying which precondition was missing | Same rule as `standard` |
| `releaseCiOrdering` | Review first; CI starts only on the final review-settled release-PR SHA when the repo supports the draft hold | Same | Same |
| `autoRelease` (default written by `setup`) | **true** — the release unit merges to the base branch when its last leaf lands. `setup` says this out loud when it writes it: on a repo whose base branch is effectively production, the owner must know | false | false |
| `reviewerRegistrationWindowMinutes` — how long to wait for proof that a cloud reviewer was actually asked | 2 | 2 | 2 |
| `pollTimeoutMinutes` — bound on waiting for a REGISTERED cloud reviewer's review (default written by `setup`) — the UPPER bound of the adaptive wait; see `review` step 2 | 5 | 10 | 20 |

Read the `prototype` column as "rails and guidance, fast"; the `enterprise` column as "high
resolution, minimum exposure to error"; `standard` as the middle a working product wants.

## Floors — what no profile removes

These hold under every profile and under every override. They are the difference between a
lighter loop and no loop:

1. **Every story gets a bounded self-check and green local gate.** The profile sets the gate's
   `storyVerify` width; it cannot make the check or gate disappear.
2. **Auth, migration, irreversible-state and deployed-contract changes get immediate focused
   verification** on `opus`/`xhigh`, even on a fast story. These risk verifiers are additions to,
   not constrained by, `reviewBreadthCeiling`. See [The auth boundary](#the-auth-boundary).
3. **Full adversarial review runs at the merge boundary, not twice per story.** A direct story PR
   is a boundary; otherwise the release-unit PR reviews the batched full diff with every configured
   engine before CI.
4. **Two adversarial cycles is the normal target, not a release-safety cap.**
   `targetAdversarialCycles` covers Claude, local CLI, cloud, rebase/pre-ship and real-CI repair
   rechecks together. After that target, only a verified P1 or **serious P2** — below P1, with
   likelihood = likely **and** impact = material — opens another contextual cycle. Fix, check and repeat
   until a cycle finds none; no numeric target or local-round sub-cap may stop those safety cycles.
   While one remains open, an unchanged patch, no progress or unavailable required reviewer STOPS
   for human help instead of spinning or merging. A clean cycle may finish before the target.
5. **Every follow-up receives the cumulative review ledger** — prior findings, verdicts,
   dispositions, fixes and checked SHAs — and inspects the delta rather than restarting from zero.

## The auth boundary

A diff touches the auth boundary when it changes any of: authentication or session code; token
issuance, validation, storage or encryption; permission checks or role assignment; secrets
handling; cryptographic primitives; or the request boundary of a deployed handler that reads
identity. The build engine decides this from the DIFF of the story in hand — not from the plan's
theme. In a plan that is "about auth", a scaffold story, a CI story or a runbook story does not
touch the boundary; the login-callback story does.

The same immediate-risk floor applies to schema/data migrations, irreversible state transitions,
and deployed-runtime contracts whose mismatch can block or corrupt a release. Name the changed
files and concrete invariant; do not escalate an entire plan merely because its theme is risky.

## Resolution order

Every delivery skill resolves the profile the same way, first match wins, and **announces the
result and its source** ("profile: prototype — from the plan root I20100"):

1. An explicit profile passed in `$ARGUMENTS` of the invoking skill — the bare word
   `prototype`, `standard` or `enterprise` anywhere in the arguments (`/devstride:plan I20100
   prototype`, `/devstride:rebalance I20100 standard`). `rebalance` requires one; `plan` and
   `build-item` accept one.
2. The **root marker** on the resolved plan root — see below. A one-off item (no plan root) has
   none.
3. `profile` in the consuming repo's `.claude/ds-config.json`.
4. `standard`.

**Explicit config values win over profile defaults.** Three knobs above also exist as their own
config keys — `epicIntegrationBranches.autoRelease`, `epicIntegrationBranches.fastStoryMerges.enabled`
and `review.pollTimeoutMinutes`. For those, a key PRESENT in the file is the operator's decision
and stands, whatever the profile says; the profile supplies the value only when the key is absent. `setup`
writes those keys consistent with the profile it was told, so a fresh config and its profile
agree; a hand-edited key that disagrees is honoured and reported ("profile prototype, but
`autoRelease` is false in config — stopping at release-ready as configured").

**The three `review.*` CI-ordering booleans are different again: they describe what the repo's
workflows SUPPORT, not what the profile does with it.** `setup` writes them as detected facts under
every profile. Every profile uses the draft hold when all three are true: review settles first,
then the PR is marked ready and CI runs on the review-settled SHA. Missing support is reported as a
setup blocker before a new loop PR; no profile silently opts into concurrent release CI.

**`review.localCommand` is different: it names the engine, it does not schedule it.** A present
`localCommand` puts the local CLI engine on the roster; `localCliEngine` and
`maxLocalReviewRounds` then decide WHERE and HOW OFTEN it runs within the normal
`targetAdversarialCycles`. A verified P1/serious-P2 safety continuation overrides that ordinary
local target. A configured engine reviews direct and release PRs, never an un-PR'd fast
story. A `null` `localCommand` removes it everywhere.

**`review.localAssistCommand` is support, not a reviewer-family round.** When configured,
`ultracode-build` may call it once read-only for the narrow triggers in the engineering-economy
contract. It does not write, invoke MCP, satisfy the merge review, or run on routine work.

## The root marker

The profile travels WITH the plan, because planning is repo-agnostic (it reads only the DevStride
MCP) and because one repo can run a prototype plan and an enterprise plan side by side. It is a
single line in the plan root item's description:

```html
<p><strong>Delivery profile:</strong> prototype</p>
```

Read it with a case-insensitive match on `Delivery profile:` followed by one of the three names.
`plan` writes it at the sign-off that closes its discovery loop; `rebalance` rewrites it. Any
descendant container without its own marker inherits the root's. A descendant WITH its own marker
(rare — a deliberately stricter sub-tree) wins for its subtree. The marker is read with
`get_item(view: 'full')` — the default projection omits `description`, so a summary read finds
no marker and silently falls through to the config default.

## Overrides

`profileOverrides` in `.claude/ds-config.json` pins individual knobs for every profile:

```json
{
  "profile": "standard",
  "profileOverrides": {
    "maxLocalReviewRounds": 2,
    "reviewBreadthCeiling": "HIGH-RISK"
  }
}
```

Keys are the knob names in the table above; values are the table's vocabulary — and for the two
prose-valued knobs, `grain` and `specDepth`, the value is another profile's NAME (`"specDepth":
"enterprise"` means "slice at standard but spec at enterprise depth"). When a knob also has a
dedicated config key (`autoRelease`, `fastStoryMerges.enabled`, `pollTimeoutMinutes`) and both are
present, the dedicated key wins — an override adjusts the profile's default, it does not outrank
an operator's explicit setting. `verificationGrouping` accepts `per-file` | `per-finding`
(`per-finding` restores one verifier per finding at HIGH-RISK, the only breadth the grouping
changed — this override IS the mechanism; there is no top-level key). An override
cannot go below a floor (`reviewBreadthCeiling` cannot be lower than NARROW, and setting it does
not remove an immediate-risk verifier). `targetAdversarialCycles` is the fixed two-cycle floor,
not an override key; an attempted override is reported and ignored. `maxLocalReviewRounds` is
capped by that normal target, but cannot limit P1/serious-P2 safety continuations. Unknown knob
names are reported and ignored.

## What each skill reads

| Skill | Knobs it honours |
|---|---|
| `plan` | `grain`, `specDepth`; writes the root marker |
| `ultracode-build` | `understandReaders`, `fixFloor`, `storyVerify` |
| `review` | `reviewBreadthCeiling`, `verificationDefault`, `verificationGrouping`, `localCliEngine`, `maxLocalReviewRounds`, `targetAdversarialCycles`, `fixFloor`, reviewer timeouts, `releaseCiOrdering` |
| `build-item` | resolves the profile; `perStoryPullRequest`, `storyVerify`, `autoRelease`, `targetAdversarialCycles`, `releaseCiOrdering` |
| `setup` | asks the profile; writes `profile` and the profile-consistent defaults |
| `doctor` | reports the effective profile, its source, and any config key that contradicts it |
| `rebalance` | takes the target profile; rewrites the root marker; re-slices not-started leaves to the new `grain` and `specDepth` |

## Cited by

- `plan` SKILL.md (grain, spec depth, root marker)
- `ultracode-build` SKILL.md (readers, story risk check, fix floor, story verify)
- `review` SKILL.md (merge-boundary breadth, cycle targets/safety continuation, fix floor, registration window)
- `build-item` SKILL.md (resolution, per-story PR, auto-release)
- `setup` SKILL.md and `setup/references/config-defaults.md` (the `profile` key)
- `doctor` SKILL.md (effective profile)
- `rebalance` SKILL.md (re-slicing)
