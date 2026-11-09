---
load: contract
---
# The release pull request — its body and the gated review (steps 1–2c)

The `release` body keeps the order of steps 1–2c, their verdict lines and the hard floors; this
file holds how each is carried out, and is read in full before step 1 (before step 2 when step 1
did not run).

## Step 1 — the release-flavored body

`prBodyTemplate.sections` in order, flavor by POSITION:

1. 1st (fallback `## Simple Description`) — what consumers get in this deploy, in plain language,
   then the constituent epics/items (`I##### — title`).
2. 2nd (`## Technical Description`) — the aggregate technical delta (subsystems, design changes,
   migrations).
3. 3rd (`## Notable Changes to System Architecture or Behavior`) — user-visible behaviour, public
   contract, permission and migration changes across the release (the docs pass mines it; "None"
   only if truly none).
4. 4th (`## Testing Steps`) — how the release was validated and any post-deploy smoke.

AI attribution only when `prBodyTemplate.noAiAttribution` is false (shipped default true → none).
End with `<!-- devstride:loop -->`, as `pr` does (the convention-only workflow's marker, never a
bypass of the draft hold) and, on a release branch, a second marker line
`<!-- devstride:release-branch <name> cut <sha> -->` (the cut point, read back on adoption).

## Step 2 — invoking `review`

- **The profile never loosens this step.** It sets the review's normal cycle target and fix floor;
  a production release is a PR-path review under every profile, so the configured CLI engine and
  every in-scope cloud reviewer run — unless `release.productionReview` is set: then
  `${CLAUDE_PLUGIN_ROOT}/skills/release/references/review-once.md`, read first, decides how much of
  step 2 runs.
- **What the invocation declares.** **DRIVEN** — undeclared, `review`'s standalone ask-gates and
  notifications pause an autonomous release — and, on a release branch, `release-branch: true` (its
  7.1 then hands a moved base back to the hotfix rule). Pass `review-moment: production-release`,
  critical merge-gate routing, and a scope manifest from step 0: files/symbols where epics
  interact, conflict-resolution commits, migrations/public contracts, and commits with no settled
  reviewed-head record.
- **Seed prior dispositions.** Load each constituent PR's
  sanitized `<!-- devstride:review-context -->` final marker and the fast-story ledgers, namespace
  their ids by PR/item, and seed prior dispositions so production does not rediscover settled
  findings. Local Claude and a context-capable CLI review that surface; cloud reviewers may cover
  the whole PR.
- **Enforce the release-surface scope with that manifest**, not narrative alone; never blindly
  re-read approved code (why: `${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-gates.md`).
  Pre-ship checks stay non-negotiable. Consume `review`'s findings summary and untracked-deferral
  list before step 4.
- **The pre-ship hold.** Declared whenever any `preShipChecks` entry has `when` ∈
  {`releaseOnly`, `always`}: `pre-ship release select`, run here without `--ran-at-train`, prints
  `PRE-SHIP SELECTED`. No such entry → no hold, skip 2c.
  The release head is protected so `review`'s 7.1 never rebases it — the hold still fires.
- **Order**: merge-gate Claude + local CLI + cloud review concurrently (every finding
  verified/triaged/fixed/replied/resolved) → the pre-ship checks (2b) → the ready-flip releases CI,
  once, on the final reviewed diff.
- **Where suites run.** `preShipChecks` suites run LOCALLY only (`pre-ship`);
  `verify.skipDuringStoryBuilds` governs slow CLOUD suites (moving one between them:
  `release-gates.md`).

## Step 2 — the head, re-validated before the flip

On a release branch the head advances only by this run's fix commits and a hotfix merge
(`${CLAUDE_PLUGIN_ROOT}/skills/release/references/release-branch.md` §4), each re-reviewed; without
one it must still equal `<sourceHead>`. Anything else → recompute the delta and restart step 2 on
the new head with the same ledger, target and safety triggers. Record the SHA that finally settles
as `<reviewedHead>` (after `review` 7.3's empty re-trigger commit if one fired — same tree).
Nothing is frozen: an advance after the flip goes back through step 2 — a ready PR is first
returned to draft (`gh pr ready --undo`), so CI waits — never merged over; any return to step 2
voids any owner yes given.

## Step 2 — findings

Only genuinely ambiguous/risky findings stall — surface them with a recommendation. A dismissed
finding stays dismissed; each entry on this release's or the step-0b train pull request's
untracked-deferral list → `create-defect deferred <item#>` (a bug) or
`create-story deferred <item#>` (the item it concerns; discovered scope: `insert-story`) with a plan root, else noted for
the owner — never spliced.

## Step 2b — running the checks

Run `classify-release` again at the head 2b tests (a merge, fix or hotfix changes the delta), then
`pre-ship release run` with THAT class. Add `--ran-at-train <names>@<sha>` only from THIS release's
`PRE-SHIP TRAIN: PASS` line, else every `runAt: train` entry runs here. Report each entry's result
in step 4's recap. The owner may explicitly waive one ("skip <name>") — pass `--skip <name>`,
reported `WAIVED`; "not run" is legitimate, silent omission is not.

## Step 2c — discharging the hold

`review` in PRE-SHIP RESUME mode re-enters at 7.1, re-checks the unresolved threads, flips the PR
ready and settles CI. Carry the same ledger, target and safety triggers: a verified P1/serious-P2
fix keeps receiving contextual passes until clear; lower severity never extends the target. A
declared hold left undischarged leaves the PR a draft, CI never released.

## Cited by

- `skills/release/SKILL.md` — step 1's pointer ("Read … in full before step 1"), and steps 2–2c.
