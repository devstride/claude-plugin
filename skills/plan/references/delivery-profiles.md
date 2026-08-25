# Delivery profiles — CANONICAL CONTRACT

The single authoritative definition of the **delivery profile**: the one user-facing choice that
sets how much rigor the loop spends per unit of work — how finely a plan is sliced, how deep each
spec goes, how wide the adversarial review fans out, how many review rounds run, and which gates a
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
| `reviewBreadthCeiling` — the widest breadth `ultracode-build` phase 3 may pick | **NARROW**, plus the security lens whenever the diff touches an [auth boundary](#the-auth-boundary) | **CONTAINED**; HIGH-RISK only for a story whose OWN diff touches an auth boundary or a migration | As the skill's sizing rule says — HIGH-RISK is available for any story that warrants it |
| `verificationDefault` | REFUTED unless reproducible | REFUTED unless reproducible | REFUTED unless reproducible |
| `fixFloor` — which verified findings get fixed in-story | **`p1-security`**: P1 correctness and any security finding. Everything else is deferred with a one-line rationale (to the item that owns it, or the untracked-deferral list) | **`likely-important`**: findings that are both likely to occur and material if they do. The rest is dismissed with a rationale | **`all-confirmed`**: every CONFIRMED and PLAUSIBLE finding |
| `localCliEngine` — does the local CLI reviewer (Codex, by default) run on stories | **No** — Claude's build-time pass is the local gate | Yes, when configured | Yes, when configured |
| `maxLocalReviewRounds` — total runs of the local CLI engine per story, re-reviews included | 0 | **1** — one review; its findings are fixed; **no re-review of the fixes** | **2** — one review, one re-review of the fixes, then stop |
| `storyVerify` — the local gate before a story merges | Type-checks + the touched test suites (`verify.testSingle`, widened when the change is broad). The full `verify.test` runs once, at the release PR | Type-checks + full `verify.test` | Type-checks + full `verify.test` + `verify.lint` where applicable |
| `perStoryPullRequest` | Fast mode — no per-story PR — whenever `fastStoryMerges.enabled` is absent or `true`; Claude's build-time pass is the ≥ 1 local engine the floor needs. A present `false` wins and is reported | Per `fastStoryMerges.enabled` | Per `fastStoryMerges.enabled` |
| `fastStoryMerges.enabled` (default written by `setup`) | **true** whenever `verify.typecheck` is set — Claude's pass is the local engine, and the story gate is type-checks + touched suites | `true` only when a local CLI engine is configured AND `verify.test` and `verify.typecheck` are set (the existing rule); else `false`, saying which precondition was missing | Same rule as `standard` |
| `releaseCiOrdering` | CI runs **concurrently** with review on the release PR — the draft hold is not used at runtime, whatever the three `review.*` CI-ordering booleans say | Per the three `review.*` CI-ordering booleans | Per the three `review.*` CI-ordering booleans |
| `autoRelease` (default written by `setup`) | **true** — the release unit merges to the base branch when its last leaf lands. `setup` says this out loud when it writes it: on a repo whose base branch is effectively production, the owner must know | false | false |
| `reviewerRegistrationWindowMinutes` — how long to wait for proof that a cloud reviewer was actually asked | 2 | 2 | 2 |
| `pollTimeoutMinutes` — bound on waiting for a REGISTERED cloud reviewer's review (default written by `setup`) | 5 | 10 | 20 |

Read the `prototype` column as "rails and guidance, fast"; the `enterprise` column as "high
resolution, minimum exposure to error"; `standard` as the middle a working product wants.

## Floors — what no profile removes

These hold under every profile and under every override. They are the difference between a
lighter loop and no loop:

1. **One adversarial pass always runs.** Claude's build-time review (`ultracode-build` phase 3)
   runs on every story at NARROW breadth or wider, with `effort: 'max'` on its agents. A profile
   sets the ceiling, never zero.
2. **The security lens is mandatory on an auth boundary**, at every breadth. See
   [The auth boundary](#the-auth-boundary).
3. **A fast-merged story has at least one engine behind it** — the existing floor in
   `build-item` step 4a; Claude's pass satisfies it.
4. **A story's local gate is green before it merges.** The gate's WIDTH is the profile's
   `storyVerify`; that it must be green is not negotiable.
5. **The release PR still gets every configured cloud engine and CI over the full diff.** Profiles
   move cost off the story; the release unit is still the safety unit.

## The auth boundary

A diff touches the auth boundary when it changes any of: authentication or session code; token
issuance, validation, storage or encryption; permission checks or role assignment; secrets
handling; cryptographic primitives; or the request boundary of a deployed handler that reads
identity. The build engine decides this from the DIFF of the story in hand — not from the plan's
theme. In a plan that is "about auth", a scaffold story, a CI story or a runbook story does not
touch the boundary; the login-callback story does.

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
every profile. Under `standard` and `enterprise` they govern the draft hold exactly as today. Under
`prototype` the hold is not used at runtime whatever they say — `pr` opens the release PR non-draft
and `review` settles CI concurrently with review, with no flip, gate assertion or close+reopen —
so `doctor` never reports them as contradicting the profile.

**`review.localCommand` is different: it names the engine, it does not schedule it.** A present
`localCommand` puts the local CLI engine on the roster; `localCliEngine` and
`maxLocalReviewRounds` then decide WHERE and HOW OFTEN it runs. So under `prototype` a configured
Codex still reviews every release PR and every PR-path item at full effort — it simply gets zero
rounds on fast-mode stories. A `null` `localCommand` removes the engine everywhere, as today.

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
an operator's explicit setting. An override
cannot go below a floor (`reviewBreadthCeiling` cannot be lower than NARROW, and setting it does
not remove the auth-boundary security lens). Unknown knob names are reported and ignored, never
silently honoured as something else.

## What each skill reads

| Skill | Knobs it honours |
|---|---|
| `plan` | `grain`, `specDepth`; writes the root marker |
| `ultracode-build` | `understandReaders`, `reviewBreadthCeiling`, `verificationDefault`, `fixFloor`, `storyVerify` |
| `review` | `localCliEngine`, `maxLocalReviewRounds`, `fixFloor`, `reviewerRegistrationWindowMinutes`, `pollTimeoutMinutes`, `releaseCiOrdering` |
| `build-item` | resolves the profile for the run; `perStoryPullRequest`, `storyVerify`, `autoRelease`, `releaseCiOrdering` |
| `setup` | asks the profile; writes `profile` and the profile-consistent defaults |
| `doctor` | reports the effective profile, its source, and any config key that contradicts it |
| `rebalance` | takes the target profile; rewrites the root marker; re-slices not-started leaves to the new `grain` and `specDepth` |

## Cited by

- `plan` SKILL.md (grain, spec depth, root marker)
- `ultracode-build` SKILL.md (readers, breadth ceiling, fix floor, story verify)
- `review` SKILL.md (round cap, fix floor, registration window)
- `build-item` SKILL.md (resolution, per-story PR, auto-release)
- `setup` SKILL.md and `setup/references/config-defaults.md` (the `profile` key)
- `doctor` SKILL.md (effective profile)
- `rebalance` SKILL.md (re-slicing)
