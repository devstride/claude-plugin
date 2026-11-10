---
load: contract
---
# Delivery profiles — CANONICAL CONTRACT

The single authoritative definition of the **delivery profile**: the one user-facing choice that
sets how much rigor the loop spends per unit of work. Every skill that plans, builds, reviews or
rebalances reads the profile through THIS file by citation; none restates it.

## Why one choice, not many knobs

The knobs are coupled: coarse stories under enterprise-grade review (fix every plausible finding,
extra rounds) draw dozens of findings per diff and run longer than finer stories would; fine
stories under a prototype review are merely wasteful. So the user picks **one word** and the knobs
move together; single knobs can still be tuned (see [Overrides](#overrides)).

## The three profiles

| Knob | `prototype` | `standard` | `extended` (default) |
|---|---|---|---|
| **Who it is for** | A small team validating an idea; no production users yet; small errors are cheap | A working product that wants finer stories | A working product built as fewer, larger stories — the shipped default |
| `grain` — leaf sizing | **One story per vertical slice a user can see or use.** Scaffold, CI, schema and harness work is folded into the first slice that needs it, never its own story | Roughly 1–2 loop-hours: one contract or one subsystem change with its tests; foundation work may stand alone as its own story | **Roughly one release-unit-day**: a full subsystem or workflow with its own tests, sized so a build agent runs unattended for hours; foundation work sits inside the story that needs it |
| `specDepth` — leaf description | Goal, acceptance criteria, the files it touches, Definition of Done. **Cap ~1,500 characters** | The full leaf template (`plan` step 3, Stage C). **Cap ~5,000 characters** | The full leaf template, uncapped |
| `understandReaders` — `ultracode-build` phase 1 fan-out | **0** — read the relevant files inline, no Workflow | **≤ 2** readers, only for angles the spec does not pin | **≤ 4** — a subsystem story crosses more contracts than its spec pins; under six, as the uncapped spec pins more |
| `reviewBreadthCeiling` — generic finder breadth at a merge gate | **NARROW** | **CONTAINED** | HIGH-RISK when the diff warrants it — a multi-hour, multi-module diff clamped at CONTAINED would get a standard story's finders |
| `verificationDefault` | REFUTED unless reproducible | REFUTED unless reproducible | Same as standard |
| `verificationGrouping` — how HIGH-RISK verification fans out | `per-file` | `per-file` | Same as standard |
| `fixFloor` — additional profile floor after the universal P1/serious-P2 floor | **`p1-security`**: P1 correctness and any security finding; the rest is dismissed with a one-line rationale | **`likely-important`**: findings that are both likely to occur and material if they do. The rest is dismissed with a rationale | Same as standard |
| `localCliEngine` — where a configured local CLI reviewer runs | Every direct-PR or release-PR merge boundary; never a fast story with no PR | Same | Same |
| `maxLocalReviewRounds` — local-engine target inside the normal cycle target | **1** | **1** | **1** |
| `targetAdversarialCycles` — fixed, non-overrideable target across every reviewer/recheck | **2** | **2** | **2** |
| `storyVerify` — the local gate before a story merges | Type-checks + touched suites (`verify.testSingle`, widened when broad); full `verify.test` at release PR | Same; full `verify.test` at release PR | Same as standard |
| `perStoryPullRequest` | Fast mode — no per-story PR — whenever `fastStoryMerges.enabled` is absent or `true`; the story risk check and green gate qualify its integration-branch merge, and the release-PR review holds the batch from the base branch. A present `false` wins and is reported | Per `fastStoryMerges.enabled` | Same as standard |
| `fastStoryMerges.enabled` (default written by `setup`) | **true** whenever `verify.typecheck` is set | `true` when `verify.test` and `verify.typecheck` are set; else `false`, saying which precondition was missing | Same as standard |
| `releaseCiOrdering` | Review first; CI starts only on the final review-settled release-PR SHA when the repo supports the draft hold | Same | Same |
| `autoRelease` (default written by `setup`) | **true** — the release unit merges to the base branch when its last leaf lands. `setup` says this out loud when it writes it: on a repo whose base branch is effectively production, the owner must know | false | false |
| `reviewerRegistrationWindowMinutes` — how long to wait for proof that a cloud reviewer was actually asked | 2 | 2 | 2 |
| `pollTimeoutMinutes` — bound on waiting for a REGISTERED cloud reviewer's review (default written by `setup`) — the UPPER bound of the adaptive wait; see `review` step 2 | 5 | 10 | 10 |

Read `prototype` as "rails and guidance, fast"; `standard` as a working product sliced finely; `extended`, the
shipped default, as the same rigor in fewer, larger stories. **`extended` buys size, not lower
rigor**: only the size-shaped knobs (`grain`, `specDepth`, `understandReaders`,
`reviewBreadthCeiling`) move coarser or wider; every safety-shaped knob (`fixFloor`, `storyVerify`,
verification, review cycles, …) and every floor below is exactly `standard`'s.

**Grain order** (`grain` row, finest → coarsest): `standard` < `prototype` < `extended`.

## Shape targets (soft)

How many leaves a release unit, and how many release units a grouping item, usually hold at each
profile's grain (this org: stories per epic, epics per capability). These rows are **not knobs**:
`profileOverrides` does not accept them, and naming one there is reported and ignored like any
unknown knob.

| Measure | `prototype` | `standard` | `extended` |
|---|---|---|---|
| Stories per epic — leaves per release unit | 2–4 | 3–8 | 2–5 |
| Epics per capability — release units per grouping item | 2–4 | 3–7 | 3–7 |

The ranges are starting points from one team's data, tuned as plans report their counts: about 20
epics of a finer-grained plan had a median of 5 stories and a middle half of 3 to 8; one plan
signed off at the larger grain had 22 stories in 7 epics, about 3 per epic (range 1 to 6); a
34-story plan became 18 when re-cut at the larger grain; one program produced 70 stories where 28
sufficed.

**Reported, never enforced.** `plan` quotes the resolved profile's two ranges with its `grain` row
when it proposes leaf titles; a release unit proposed above the upper end is raised ONCE, as a
question about merging, never refused or silently re-cut. `plan`'s final review and `rebalance`'s
report each carry one **shape against target** line: leaves per release unit, release units under
the grouping item, the two ranges, and every unit outside them. No skill refuses or blocks a plan
for missing a range.

## The retired `enterprise` profile (a breaking change in 3.12.0)

`enterprise` — the finest grain (one loop-hour stories, foundation work standing alone), six
readers, the `all-confirmed` fix floor, the full suite per story, two local rounds and a 20-minute
reviewer wait — was retired on the owner's decision of 2026-10-17: its grain cut work into pieces
so small that review and merge ceremony cost more than the error exposure they removed (one
program produced 70 stories where 28 sufficed), and every one of its rigor knobs is expressible
through `profileOverrides` on top of `standard` or `extended`. **A `profile` of `enterprise` — in
config or in a root marker — is an UNKNOWN profile**: every skill that resolves a profile falls
back to `standard` — never to the shipped default, so such a repository keeps the finer grain it
ran — and SAYS SO in its orientation line, never silently, quoting this recipe:

```json
{ "profile": "extended",
  "profileOverrides": { "fixFloor": "all-confirmed", "storyVerify": "full",
                        "maxLocalReviewRounds": 2, "understandReaders": 6 },
  "review": { "pollTimeoutMinutes": 20 } }
```

That reproduces each former `enterprise` knob except its grain, which the owner chose to drop;
`rebalance <root> extended` (or `standard`) rewrites a plan root's marker. `storyVerify: "full"`
is type-checks + the full `verify.test` + `verify.lint` where applicable; `understandReaders` is
the fan-out cap (up to the six the skill defines).

## Floors — what no profile removes

These hold under every profile and every override — the difference between a lighter loop and no
loop:

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
identity. The build engine decides this from the story's DIFF, not the plan's theme: in a plan
"about auth", a scaffold, CI or runbook story does not touch it; the login-callback story does.

The same immediate-risk floor applies to schema/data migrations, irreversible state transitions,
and deployed-runtime contracts whose mismatch can block or corrupt a release. Name the changed
files and concrete invariant; do not escalate an entire plan merely because its theme is risky.

## Resolution order

Every delivery skill resolves the profile the same way, first match wins, and **announces the
result and its source** ("profile: prototype — from the plan root I20100"):

1. An explicit profile in the invoking skill's `$ARGUMENTS` — the bare word `prototype`,
   `standard` or `extended` anywhere in the arguments (`/devstride:plan I20100
   prototype`, `/devstride:rebalance I20100 extended`). `rebalance` requires one; `plan` and
   `build-item` accept one.
2. The **root marker** on the resolved plan root — see below. A one-off item (no plan root) has
   none.
3. `profile` in the consuming repo's `.claude/ds-config.json`.
4. `extended` — the shipped default (it was `standard` through 3.48.0; a repository that wants the
   finer grain sets `"profile": "standard"`).

**Explicit config values win over profile defaults.** For the config keys
`epicIntegrationBranches.autoRelease`, `epicIntegrationBranches.fastStoryMerges.enabled` and
`review.pollTimeoutMinutes`, a PRESENT key is the operator's decision and stands; the profile fills
only an absent one. `setup` writes them consistent with its profile; a hand-edited key that
disagrees is honoured and reported ("profile prototype, but
`autoRelease` is false in config — stopping at release-ready as configured"). The CONFIG
`autoRelease` key also accepts `"ask"` — ask the owner per release unit, behaving as `false` when
nobody can answer. No profile writes it; it is an operator's choice, defined in
`${CLAUDE_PLUGIN_ROOT}/skills/setup/references/config-defaults.md`.

**The three `review.*` CI-ordering booleans describe what the repo's workflows SUPPORT, not what
the profile does with it.** `setup` writes them as detected facts under every profile. Every
profile uses the draft hold when all three are true: review settles first, then the PR is marked
ready and CI runs on the review-settled SHA. Missing support is a setup blocker, reported before a
new loop PR; no profile silently opts into concurrent release CI.

**`review.localCommand` names the engine; it does not schedule it.** A present `localCommand`
puts the local CLI engine on the roster; `localCliEngine` and `maxLocalReviewRounds` then decide
WHERE and HOW OFTEN it runs within the normal `targetAdversarialCycles`. A verified
P1/serious-P2 safety continuation overrides that ordinary local target. A configured engine
reviews direct and release PRs, never an un-PR'd fast story. A `null` `localCommand` removes it
everywhere.

**`review.localAssistCommand` is support, not a reviewer-family round.** When configured,
`ultracode-build` may call it once read-only for the narrow triggers in the engineering-economy
contract. It does not write, invoke MCP, satisfy the merge review, or run on routine work.

## The root marker

The profile travels WITH the plan — planning is repo-agnostic (it reads only the DevStride MCP) and
one repo can run a prototype and an extended plan side by side — as one line in the plan root's
description:

```html
<p><strong>Delivery profile:</strong> prototype</p>
```

Read it with a case-insensitive match on `Delivery profile:` followed by one of the three names;
any other word there (the retired `enterprise` included) is the unknown-profile fallback above.
`plan` writes it at the sign-off that closes its discovery loop; `rebalance` rewrites it. Any
descendant container without its own marker inherits the root's; one WITH its own marker (rare — a
deliberately stricter sub-tree) wins for its subtree. The marker is read with
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

Keys are the table's knob names; values its vocabulary — for the prose-valued `grain` and
`specDepth`, another profile's NAME (`"specDepth": "extended"` = slice at the active profile,
spec at extended depth). The override keys `fixFloor` (`p1-security` | `likely-important` |
`all-confirmed`), `storyVerify` (`touched` | `full`) and `understandReaders` (0–6) carry the
retired `enterprise` profile's rigor, see above. A dedicated config key (`autoRelease`, `fastStoryMerges.enabled`,
`pollTimeoutMinutes`) present beside an override wins — an override adjusts the profile's default,
never an operator's explicit setting. `verificationGrouping` accepts `per-file` | `per-finding`
(`per-finding` restores one verifier per finding at HIGH-RISK; this override IS the mechanism —
there is no top-level key). No override goes below a floor (`reviewBreadthCeiling` never below
NARROW, and it never removes an immediate-risk verifier). `targetAdversarialCycles` is the fixed
two-cycle floor, not an override key: an attempt is reported and ignored. `maxLocalReviewRounds`
is capped by that target but cannot limit P1/serious-P2 safety continuations. Unknown knob names
are reported and ignored.

## What each skill reads

| Skill | Knobs it honours |
|---|---|
| `plan` | `grain`, `specDepth`; writes the root marker; reports against the shape targets |
| `ultracode-build` | `understandReaders`, `fixFloor`, `storyVerify` |
| `review` | `reviewBreadthCeiling`, `verificationDefault`, `verificationGrouping`, `localCliEngine`, `maxLocalReviewRounds`, `targetAdversarialCycles`, `fixFloor`, reviewer timeouts, `releaseCiOrdering` |
| `build-item` | resolves the profile; `perStoryPullRequest`, `storyVerify`, `autoRelease`, `targetAdversarialCycles`, `releaseCiOrdering` |
| `setup` | asks the profile; writes `profile` and the profile-consistent defaults |
| `doctor` | reports the effective profile, its source, and any config key that contradicts it |
| `rebalance` | takes the target profile; rewrites the root marker; re-slices not-started leaves to the new `grain` and `specDepth`; reports against the shape targets |

## Cited by

- The SKILL.md of `plan`, `ultracode-build`, `review`, `build-item`, `setup` (plus
  `setup/references/config-defaults.md`), `doctor` and `rebalance` — each for the knobs listed
  against it in the table above.
- `build-item/references/plan-scope.md` — the `Release scope:` marker is read on the root-marker walk.
