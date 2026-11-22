---
load: contract
---
# plan-hand-off — Report the finished plan and where the build loop starts

`plan-steps`'s `plan-hand-off@1` step. Report the finished plan and where the build loop starts.

## Verdict

`PLAN HANDED OFF: HANDED OFF <root> | ANOTHER ROUND WANTED`

## Procedure

Requires `plan-number@1` (the runner refuses the step without a fresh proof of each). Follow
the procedure below, whole and in its order. It starts no subagent and no Workflow.

The DevStride MCP writes PRODUCTION immediately; item numbers are LOOKED UP, never composed; name
the fields you read. Print the verdict line first, then the evidence.

### 7. Final review with the user

- Report: the profile and its source; grouping-item/release-unit/leaf counts (new vs pre-existing
  when extending; deferred container excluded, saying if it exists); the critical-path spine (root story → gate stories → final story); the parallel
  waves; the `[1] … [N]` range; per-release-unit leaf counts (each reads as its own shippable
  increment — a `prototype` plan visibly has a few slices per unit, not a dozen layers); the
  **shape against target** line (reported, never enforced); recorded
  deviations; and zero orphan leaves confirmed.
- Point at the plan root: `/devstride:build-item <root-story-number>` (or bare
  `/devstride:build-item` once it is the earliest unblocked item) now runs it end-to-end. Each release
  unit (this org's Epic) gets its own integration branch; stories batch onto it; when its last story
  merges, its release PR to develop is cut fully reviewed — automatically only if
  `epicIntegrationBranches.autoRelease` is enabled, otherwise stopping at release-ready for an
  owner-cut release.
- **Persist the plan root to project memory** as the execution handoff — root number, title, the
  profile it was planned under, and "ready to execute via /devstride:build-item" — so a bare
  `/devstride:build-item` reads it back instead of guessing. The step-2 marker is the authoritative
  profile; the memory line is a convenience that must never disagree with it.
- Ask whether any release unit or leaf needs another discovery round; re-invoking on the same root
  extends or refines it (step 1 detects the partial plan and treats it as additive).

## Result

After the verdict and its evidence, one fenced `json` block with `root`, `newCount`, `existingCount`.

## Cited by

- `skills/plan-steps/SKILL.md` — the `plan-hand-off@1` dispatch.
