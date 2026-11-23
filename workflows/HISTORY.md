# Workflow and step contract history

Generated from [`registry.json`](registry.json) by `scripts/workflow-registry.py history --write`,
which the release's prepare step runs; never edit this page by hand. Every version of every
built-in workflow and every revision of every step contract is listed, newest first. A
version marked *shipped unused* was published as data before any released plugin could run it.

## Contents

- [Build (`build`)](#build-build): version 2
- [Hotfix (`hotfix`)](#hotfix-hotfix): version 1
- [Plan (`plan`)](#plan-plan): version 1
- [Rebalance (`rebalance`)](#rebalance-rebalance): version 1
- [Release (`release`)](#release-release): version 1
- [Release (clearance from cut to deploy) (`release-cut-to-deploy`)](#release-clearance-from-cut-to-deploy-release-cut-to-deploy): version 1
- [Release: documentation only (`release-docs`)](#release-documentation-only-release-docs): version 1
- [Release (clearance for merge and deploy) (`release-merge-and-deploy`)](#release-clearance-for-merge-and-deploy-release-merge-and-deploy): version 1
- [Release: release notes only (`release-notes`)](#release-release-notes-only-release-notes): version 1
- [Release: post-deploy only (`release-post-deploy`)](#release-post-deploy-only-release-post-deploy): version 1
- [Step contracts](#step-contracts): 100 contracts
  - [4.8.0, 2026-11-22](#480-2026-11-22)
  - [4.3.0, 2026-11-19](#430-2026-11-19)
  - [4.2.0, 2026-11-18](#420-2026-11-18)

## Build (`build`)

Current version **2**, minimum plugin version **4.3.0**, 2 row(s) recorded.

| Version | Plugin release | Date | Steps changed | Note |
| --- | --- | --- | --- | --- |
| 2 | 4.3.0 | 2026-11-19 | added `capture`, `review`; removed `file-findings`, `pull-request-review`, `review-local`, `select`; contract changed: `claim` (claim-item@1 → claim@1), `complete` (complete-item@1 → complete@1), `start` (start-item@1 → start@1) | The Build loop now runs from this list: eleven steps, each its own step skill, and a stopped run resumes at the exact step it stopped on. |
| 1 | 4.1.0 | 2026-11-18 | first version: 13 steps | The Build loop first written down as a step list of four phases and thirteen named steps, a description of the loop that nothing ran yet. *Shipped unused: no released plugin could run it.* |

## Hotfix (`hotfix`)

Current version **1**, minimum plugin version **4.8.0**, 1 row(s) recorded.

| Version | Plugin release | Date | Steps changed | Note |
| --- | --- | --- | --- | --- |
| 1 | 4.8.0 | 2026-11-22 | first version: 13 steps | A hotfix as a step list the runner can walk: the branch, the fix, its review, the merge into production and the deploy, each on the person's word. |

## Plan (`plan`)

Current version **1**, minimum plugin version **4.8.0**, 1 row(s) recorded.

| Version | Plugin release | Date | Steps changed | Note |
| --- | --- | --- | --- | --- |
| 1 | 4.8.0 | 2026-11-22 | first version: 12 steps | Planning as a named step list of twelve steps in five phases, with nothing created before the recorded sign-off and the approved drafts. |

## Rebalance (`rebalance`)

Current version **1**, minimum plugin version **4.8.0**, 1 row(s) recorded.

| Version | Plugin release | Date | Steps changed | Note |
| --- | --- | --- | --- | --- |
| 1 | 4.8.0 | 2026-11-22 | first version: 13 steps | Rebalancing a plan as a named step list of thirteen steps in five phases, each write needing the previous write's proof. |

## Release (`release`)

Current version **1**, minimum plugin version **4.8.0**, 1 row(s) recorded.

| Version | Plugin release | Date | Steps changed | Note |
| --- | --- | --- | --- | --- |
| 1 | 4.8.0 | 2026-11-22 | first version: 45 steps | The full release as a step list for the default clearance scope, generated from one source with the other release definitions. *Shipped unused: no released plugin could run it.* |

## Release (clearance from cut to deploy) (`release-cut-to-deploy`)

Current version **1**, minimum plugin version **4.8.0**, 1 row(s) recorded.

| Version | Plugin release | Date | Steps changed | Note |
| --- | --- | --- | --- | --- |
| 1 | 4.8.0 | 2026-11-22 | first version: 49 steps | The full release as a step list for clearance held from the cut to the deploy. *Shipped unused: no released plugin could run it.* |

## Release: documentation only (`release-docs`)

Current version **1**, minimum plugin version **4.8.0**, 1 row(s) recorded.

| Version | Plugin release | Date | Steps changed | Note |
| --- | --- | --- | --- | --- |
| 1 | 4.8.0 | 2026-11-22 | first version: 4 steps | A partial release entry that runs only the documentation update. *Shipped unused: no released plugin could run it.* |

## Release (clearance for merge and deploy) (`release-merge-and-deploy`)

Current version **1**, minimum plugin version **4.8.0**, 1 row(s) recorded.

| Version | Plugin release | Date | Steps changed | Note |
| --- | --- | --- | --- | --- |
| 1 | 4.8.0 | 2026-11-22 | first version: 62 steps | The full release as a step list for clearance held only to merge and deploy. *Shipped unused: no released plugin could run it.* |

## Release: release notes only (`release-notes`)

Current version **1**, minimum plugin version **4.8.0**, 1 row(s) recorded.

| Version | Plugin release | Date | Steps changed | Note |
| --- | --- | --- | --- | --- |
| 1 | 4.8.0 | 2026-11-22 | first version: 3 steps | A partial release entry that writes only the release notes. *Shipped unused: no released plugin could run it.* |

## Release: post-deploy only (`release-post-deploy`)

Current version **1**, minimum plugin version **4.8.0**, 1 row(s) recorded.

| Version | Plugin release | Date | Steps changed | Note |
| --- | --- | --- | --- | --- |
| 1 | 4.8.0 | 2026-11-22 | first version: 4 steps | A partial release entry that runs only the post-deploy health check. *Shipped unused: no released plugin could run it.* |

## Step contracts

Each contract is `name@major`. A major version only grows by additions; a *revision* is a
later published content of the same major, and a *slip* is one that changed more than that
without a new major.

### 4.8.0, 2026-11-22

| Contract | Note |
| --- | --- |
| `auto-start@1` | Decide whether the next release starts now (first published for the Release workflow). |
| `branch@1` (revision) | Additive revision: adds `satisfiedBy`. |
| `build@1` (revision) | Additive revision: adds `satisfiedBy`. |
| `ci-hold-proof@1` | Prove pull-request CI waits for the ready flip before a release opens (first published for the Release workflow). |
| `classify-at-checks@1` | Classify the release again at the head the checks test (first published for the Release workflow). |
| `classify-at-pre-ship@1` | Classify the release again at the reviewed head before the pre-ship checks (first published for the Release workflow). |
| `classify-release@1` | Say whether the release is light or full; anything unclear is full (first published for the Release workflow). |
| `deploy-approval@1` | Approve the production deploy of one merge, only on the person's yes for that merge (first published for the Hotfix and Release workflows). |
| `deploy-confirm@1` | Confirm production serves the merge, or ask the person to confirm it (first published for the Hotfix and Release workflows). |
| `dev-deploy-wait@1` | Wait for the staging deploy of the release commit to be serving (first published for the Release workflow). |
| `estimates-score@1` | Score the estimates the shipped items carried (first published for the Release workflow). |
| `ground-truth@1` | Fetch both branches and read what other sessions landed (first published for the Release workflow). |
| `hotfix-branch@1` | Cut the hotfix branch from the production branch and push it (first published for the Hotfix workflow). |
| `hotfix-catch-up@1` | Merge a hotfix that reached production into the release branch (first published for the Release workflow). |
| `hotfix-close@1` | Close out the hotfix and say whether an open release branch must take it (first published for the Hotfix workflow). |
| `hotfix-environment@1` | Bring the local environment back to production code: a backward transition (first published for the Hotfix workflow). |
| `hotfix-fix@1` | Make the smallest change that fixes the production problem, then commit and push it (first published for the Hotfix workflow). |
| `hotfix-merge@1` | Merge the reviewed hotfix pull request into the production branch, only on the person's yes (first published for the Hotfix workflow). |
| `hotfix-preflight@1` | Check the working tree and name the hotfix branch from the repository's config (first published for the Hotfix workflow). |
| `hotfix-report@1` | Report the cut in one line and say what comes next (first published for the Hotfix workflow). |
| `hotfix-stage@1` | Name the environment this checkout deploys to, and stop before touching a production one (first published for the Hotfix workflow). |
| `local-checks@1` (slip) | Content changed without a version bump: the payload's `item` became optional. |
| `merge-confirmations@1` | Confirm the head, CI, pre-ship results, threads and tower before the merge (first published for the Release workflow). |
| `merged-release@1` | Find the newest merged release and recompute its delta (first published for the Release workflow). |
| `owner-go-ahead@1` | Show the recap and take the owner's yes or the standing yes before the production merge (first published for the Release workflow). |
| `plan-create@1` | Create the approved tree top-down, only the items that are missing (first published for the Plan workflow). |
| `plan-discovery@1` | Ask the questions that change the shape, until the person says 'yes, build this' (first published for the Plan workflow). |
| `plan-draft@1` | Draft the specs for the signed-off shape; the drafting agents never write to DevStride (first published for the Plan workflow). |
| `plan-draft-approval@1` | Walk the person through the drafts until they approve them (first published for the Plan workflow). |
| `plan-ground@1` | Read what the plan already holds, read-only (first published for the Plan and Rebalance workflows). |
| `plan-hand-off@1` | Report the finished plan and where the build loop starts (first published for the Plan workflow). |
| `plan-number@1` | Number the leaves in the order the build loop will pick them (first published for the Plan workflow). |
| `plan-orient@1` | Resolve the plan root, its delivery profile and the organization's shape (first published for the Plan workflow). |
| `plan-sign-off-record@1` | Record the sign-off, and nothing else, in DevStride (first published for the Plan workflow). |
| `plan-wire@1` | Wire the dependency edges and prove no new leaf is left without one (first published for the Plan workflow). |
| `post-deploy-check@1` | Run the post-deploy health check (first published for the Release workflow). |
| `post-deploy-pending@1` | Post the pending post-deploy status on the merge commit (first published for the Release workflow). |
| `post-deploy-result@1` | Post the health check's result as the release/post-deploy status (first published for the Release workflow). |
| `pre-merge-at-checks@1` | Ask whether production needs anything before the merge, at the checks head (first published for the Release workflow). |
| `pre-merge-check@1` | Ask whether production needs anything before the merge (first published for the Release workflow). |
| `pre-merge-recheck@1` | Ask the pre-merge question again once the tower is claimed (first published for the Release workflow). |
| `pre-ship-at-checks@1` | Run the release's pre-ship checks before claiming the tower (first published for the Release workflow). |
| `pre-ship-release@1` | Run the release's pre-ship checks at the reviewed head (first published for the Release workflow). |
| `pre-ship-resume@1` | Discharge the review's pre-ship hold, which flips the pull request ready once (first published for the Release workflow). |
| `previous-release@1` | Check the previous release's post-deploy status before merging (first published for the Release workflow). |
| `production-in-branch@1` | Merge production into the release branch when it is behind (first published for the Release workflow). |
| `production-merge@1` | Merge the release into production through the merge gate, never a push (first published for the Release workflow). |
| `rationalize-gantt@1` | Date the plan from its dependency graph, with the auto-scheduler off (first published for the Plan and Rebalance workflows). |
| `rebalance-archive@1` | Archive the originals only after their successors have edges (first published for the Rebalance workflow). |
| `rebalance-gates@1` | Check that nothing else is writing to the plan and the arguments are whole (first published for the Rebalance workflow). |
| `rebalance-marker@1` | Rewrite the plan root's delivery profile line, and only that line (first published for the Rebalance workflow). |
| `rebalance-partition@1` | Separate the leaves that may be re-sliced from the ones that are untouchable (first published for the Rebalance workflow). |
| `rebalance-probe@1` | Prove the auto-scheduler will not overwrite what the rebalance writes (first published for the Rebalance workflow). |
| `rebalance-proposal@1` | Propose the merges or splits and wait for 'yes, rebalance' (first published for the Rebalance workflow). |
| `rebalance-renumber@1` | Give each successor the number slot of its first absorbed item (first published for the Rebalance workflow). |
| `rebalance-report@1` | Report the re-sliced plan and the next item the build loop will pick (first published for the Rebalance workflow). |
| `rebalance-rewire@1` | Move every absorbed item's edges to its successor, adding before removing (first published for the Rebalance workflow). |
| `rebalance-successors@1` | Create each merged story with the original specs preserved (first published for the Rebalance workflow). |
| `release-branch@1` | Cut the protected release branch from the release source (first published for the Release workflow). |
| `release-branch-delete@1` | Delete the release branch once both branches contain it (first published for the Release workflow). |
| `release-close-out@1` | Run the post-deploy close-out when the health check said one is owed (first published for the Release workflow). |
| `release-delta@1` | Work out what the release carries and check its holds (first published for the Release workflow). |
| `release-docs@1` | Publish documentation for the shipped release and settle the docs owed item (first published for the Release workflow). |
| `release-docs-plan@1` | Plan which documentation hooks run after the deploy is confirmed (first published for the Release workflow). |
| `release-kb-sync@1` | Refresh the knowledge base after documentation was published (first published for the Release workflow). |
| `release-notes@1` | Write release notes, only when they were asked for (first published for the Release workflow). |
| `release-pr@1` | Open the release pull request into production as a draft (first published for the Release workflow). |
| `release-recap@1` | Write the plain-language recap of the release (first published for the Release workflow). |
| `release-review@1` | Run the full production-release review and settle it (first published for the Release workflow). |
| `release-shape@1` | Say whether this release is new, an open release to adopt, or a merged one to close out (first published for the Release workflow). |
| `release-stamp@1` | Stamp the head, tree and production tip the checks passed on (first published for the Release workflow). |
| `release-stamp-verify@1` | Verify the checks stamp still matches the branch and production (first published for the Release workflow). |
| `release-sync@1` | Sync production back into the release source (first published for the Release workflow). |
| `release-tip@1` | Record the production tip the checks run against (first published for the Release workflow). |
| `rerun-at-merge@1` | Re-run the pre-ship entries marked to run again at the merge (first published for the Release workflow). |
| `review@1` (slip) | Content changed without a version bump: the payload's `item` became optional. |
| `risk-check@1` (slip) | Content changed without a version bump: the payload's `item` became optional. |
| `session-model@1` | Check the session's model against the role this workflow wants, and only report it (first published for the Plan and Rebalance workflows). |
| `ship-plan@1` | Wait a bounded time for work a peer says is nearly ready for the train (first published for the Release workflow). |
| `splice@1` | Splice one story or defect into a live plan, wired and dated for the build loop (first published, for steps no built-in workflow names). |
| `tower-claim@1` | Claim release clearance from the tower, waiting while another release holds it (first published for the Release workflow). |
| `tower-hand-back@1` | Hand release clearance back to the tower, naming what is still owed (first published for the Release workflow). |
| `tower-queue@1` | Wait in the release queue behind any older release pull request (first published for the Release workflow). |
| `train-claim@1` | Claim the release train so only one session runs it (first published for the Release workflow). |
| `train-claim-hand-on@1` | Hand the train claim on once the cut exists so the next release can start (first published for the Release workflow). |
| `train-close-out@1` | Mark the one-offs the train carried as reached (first published for the Release workflow). |
| `train-finish@1` | Finish the items an earlier merged release train carried (first published for the Release workflow). |
| `train-level@1` | Bring the release train level with the release source (first published for the Release workflow). |
| `train-merge@1` | Merge the train pull request through the merge gate, never a push (first published for the Release workflow). |
| `train-pr@1` | Open the release train's pull request into the release source (first published for the Release workflow). |
| `train-pre-ship@1` | Run the local pre-ship checks the train needs (first published for the Release workflow). |
| `train-review@1` | Review what no landing receipt covers on the train pull request (first published for the Release workflow). |
| `train-snapshot@1` | Cut a snapshot of the release train merged with the release source (first published for the Release workflow). |

### 4.3.0, 2026-11-19

| Contract | Note |
| --- | --- |
| `complete@1` (revision) | Additive revision: adds `profileSource`. |
| `local-checks@1` (revision) | Additive revision: adds `reviewMoment`. |
| `merge@1` (revision) | Additive revision: adds `localChecks` and `reviewProof`. |
| `review@1` (revision) | Additive revision: adds `localChecksProof`, `deferrals` and `deviations`. |
| `risk-check@1` (slip) | Content changed without a version bump: the proof now binds to the story's patch instead of nothing, and the payload and result gained keys for re-screens. |

### 4.2.0, 2026-11-18

| Contract | Note |
| --- | --- |
| `branch@1` | Create the item's branch from its working base (first published with the step contract catalog). |
| `build@1` | Build the item on its branch and hand back what was deferred, changed or dismissed (first published with the step contract catalog). |
| `capture@1` | File the follow-up work the build, the risk check and the review left untracked (first published with the step contract catalog). |
| `claim@1` | Claim the item so no other session builds it at the same time (first published with the step contract catalog). |
| `complete@1` | Record the landed work on the item: its status, dates, links and claims (first published with the step contract catalog). |
| `custom@1` | A repository's own step: it passes, fails or holds, with evidence (first published with the step contract catalog). |
| `local-checks@1` | Run the repository's local checks on the final tree and leave a receipt (first published with the step contract catalog). |
| `merge@1` | Land the reviewed change on its target (first published with the step contract catalog). |
| `review@1` | Review the change with the configured reviewers and settle every finding (first published with the step contract catalog). |
| `risk-check@1` | Check the finished build for the risks its changes carry, and fix or raise what it finds (first published with the step contract catalog). |
| `start@1` | Move the item to its in-progress status (first published with the step contract catalog). |
| `sync@1` | Bring the working base up to date and confirm the tree is clean (first published with the step contract catalog). |
