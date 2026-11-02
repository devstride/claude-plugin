---
load: contract
---
# The seam registry — every hook the plugin calls, and every other config key

Generated from `schemas/seam-registry.json` by `scripts/build-config-schema.py --write`;
never edit it by hand. The same registry generates `schemas/ds-config.schema.json`, which
`${CLAUDE_PLUGIN_ROOT}/skills/doctor/scripts/validate-config.py` checks a repository's
`.claude/ds-config.json` against. Schema version: 3.18.1.

A key written `a[].b` is the field `b` of each entry in the array `a`. `since` is the first
release that carries the key, `pre-registry` for every key older than the registry, and
`unreleased` until the next release names it. Keys under a `repoLocalKeys` prefix, keys
starting with `_` and `$schema` are never reported as unknown.

## Hooks

| Key | Shape | Value | Modes | Payload | Verdict | Called by | When unset | Contract | Since |
|---|---|---|---|---|---|---|---|---|---|
| `docs.updateSkill` | skill | string or null | update, check | the delta payload as a fenced JSON block (docs-hooks.md, The delta payload) | check: PASS or FAIL with the fix; update: the pages changed and where they went | release 5c, build-item 8, doctor 7, setup G | no documentation system registered; every docs phase reports itself skipped | `skills/release/references/docs-hooks.md` | pre-registry |
| `docs.releaseNotesSkill` | skill | string or null | publish, draft, check | the delta payload, live: true for publish | check: PASS or FAIL with the fix; publish and draft: where the note is | release 5e, doctor 7, setup G | release notes cannot be requested; --release-notes reports itself unavailable | `skills/release/references/docs-hooks.md` | pre-registry |
| `release.postDeployCheckSkill` | skill | string or null | check, close-out | check followed by {productionBranch, mergeCommit, deployConfirmedAt} | POST-DEPLOY HEALTH: PASS \| FAIL \| NOT RUN (plus CLOSE-OUT OWED); close-out: POST-DEPLOY CLOSE-OUT: DONE \| PARTIAL | release 5a, release 5d, doctor 7 | the close-out reports the health check as not configured | `skills/release/references/post-deploy-check.md` | pre-registry |
| `release.deployApproval` | command | string or null | — | RELEASE_COMMIT in the environment | exit 0 approved and read back; 2 not waiting yet; any other exit STOPS | release 4, release 5a, doctor 7 | the deploy runs without an approval step | `skills/release/references/docs-hooks.md` | pre-registry |
| `release.deployVerification` | command | string or null | — | RELEASE_COMMIT in the environment | exit 0 only when production serves RELEASE_COMMIT | release 5a, doctor 7 | the owner confirms the deploy by hand | `skills/release/references/docs-hooks.md` | pre-registry |
| `release.clearance` | provider-or-commands | object or null | claim, status, heartbeat, release, adopt, owed | each verb's own arguments appended (--wait, --short, <phase> --branch <b> --pr <n>, --force, --yes) | the verdict is stdout's first line; exit codes 0-5 per the provider contract | release 0, release 5b, branch-hotfix rules, doctor 7 | no clearance: release runs as before and nothing is claimed | `skills/release/references/clearance.md` | pre-registry |
| `verify.typecheck` | command | string[] | — | none; run from the repository root, in array order | exit 0 passes; an error outside generated.paths fails | ultracode-build 2, push rules, build-item 4a, setup G | push asks for a command; fast story merges stay off | `skills/build-item/references/verification-receipts.md` | pre-registry |
| `verify.typecheckCombined` | command | string or null | — | none | exit 0 passes | push rules | the verify.typecheck array is used; this legacy single command is read only when that array is absent | `skills/build-item/references/verification-receipts.md` | pre-registry |
| `verify.test` | command | string or null | — | none | exit 0 is green; red is a stop | ultracode-build 2, build-item 8, setup G | no full-suite gate; fast story merges stay off | `skills/build-item/references/verification-receipts.md` | pre-registry |
| `verify.testSingle` | command | string or null | — | <path/to/test> replaced with the file to run | exit 0 is green | ultracode-build 2, doctor 6 | the story gate widens to verify.test | `skills/build-item/references/verification-receipts.md` | pre-registry |
| `verify.lint` | command | string or null | — | none | exit 0 is green | ultracode-build 2, setup G | no lint step | `skills/build-item/references/verification-receipts.md` | pre-registry |
| `preShipChecks[].command` | command | string | — | none; selected by the entry's when and pathGlobs | exit 0 is green; red blocks the pull request or the release | pr 2b, release 2b | no pre-ship checks: an explicit no-op | `skills/pr/references/pre-ship-hold.md` | pre-registry |
| `localEnvironment.create` | command | string or null | — | <name>, <base>, <branch> placeholders | exit 0 made the instance | branch-hotfix local environment, build-item 0 | no isolated instances: the current checkout is the only environment | `skills/setup/references/config-defaults.md` | pre-registry |
| `localEnvironment.recreate` | command | string or null | — | <name> per recreateMode, <base> | exit 0 returned the instance to <base>'s schema | branch-hotfix local environment | branch-hotfix names the missing command and offers the manual path | `skills/setup/references/config-defaults.md` | pre-registry |
| `localEnvironment.instanceName` | command | string or null | — | none | stdout is the name of this checkout's instance | branch-hotfix local environment | an in-place recreate with <name> stops and asks | `skills/setup/references/config-defaults.md` | pre-registry |
| `localEnvironment.seed` | command | string or null | — | <name> | exit 0 seeded the instance | branch-hotfix local environment | nothing is seeded | `skills/setup/references/config-defaults.md` | pre-registry |
| `localEnvironment.migrate` | command | string or null | — | <name> | exit 0 migrated the instance forward | branch-hotfix local environment | nothing is migrated | `skills/setup/references/config-defaults.md` | pre-registry |
| `localEnvironment.teardown` | command | string or null | — | <name> | exit 0 removed the instance | branch-hotfix local environment | instances are left for the owner to remove | `skills/setup/references/config-defaults.md` | pre-registry |
| `stage.resolve` | command | string or null | — | none; run from the repository root | stdout's one line is the stage; empty means no stage; non-zero with output, or several lines, is a fault | doctor 4, release 4, setup E3 | no per-environment infrastructure: no stage renders and doctor reports N/A | `skills/setup/references/config-defaults.md` | pre-registry |
| `review.localCommand` | command | string or null | — | <context> replaced with - and the prompt on stdin; <effort>; legacy <base> | findings on stdout; a failed run is this-run degradation | review 1, review 5, doctor 6, setup G | no local CLI engine on the roster | `skills/setup/references/review-engines.md` | pre-registry |
| `review.localAssistCommand` | command | string or null | — | <context> and <effort>, as review.localCommand | advisory findings on stdout | ultracode-build 1, ultracode-build 3, doctor 6, setup G | no read-only support call | `skills/setup/references/review-engines.md` | pre-registry |
| `generated.regenCommand` | command | string or null | — | none | exit 0 regenerated the build output | push rules, ultracode-build 2 | generated files cannot be regenerated by the loop | `skills/push/SKILL.md` | pre-registry |

## Settings

| Key | Type | Allowed | Default | Meaning | Since |
|---|---|---|---|---|---|
| `profile` | string | prototype, standard, extended | standard | the delivery profile; contract: skills/plan/references/delivery-profiles.md | pre-registry |
| `profileOverrides` | object | — | — | pins one knob under the profile; operator hand-edit, never written by setup | pre-registry |
| `profileOverrides.grain` | string | — | — | overrides the profile's grain knob | pre-registry |
| `profileOverrides.specDepth` | string | — | — | overrides the profile's specDepth knob | pre-registry |
| `profileOverrides.understandReaders` | integer | — | — | overrides the profile's understandReaders knob | pre-registry |
| `profileOverrides.reviewBreadthCeiling` | string | — | — | overrides the profile's reviewBreadthCeiling knob | pre-registry |
| `profileOverrides.verificationDefault` | string | — | — | overrides the profile's verificationDefault knob | pre-registry |
| `profileOverrides.verificationGrouping` | string | — | — | overrides the profile's verificationGrouping knob | pre-registry |
| `profileOverrides.fixFloor` | string | — | — | overrides the profile's fixFloor knob | pre-registry |
| `profileOverrides.localCliEngine` | any | — | — | overrides the profile's localCliEngine knob | pre-registry |
| `profileOverrides.maxLocalReviewRounds` | integer | — | — | overrides the profile's maxLocalReviewRounds knob | pre-registry |
| `profileOverrides.storyVerify` | any | — | — | overrides the profile's storyVerify knob | pre-registry |
| `profileOverrides.perStoryPullRequest` | any | — | — | overrides the profile's perStoryPullRequest knob | pre-registry |
| `profileOverrides.releaseCiOrdering` | any | — | — | overrides the profile's releaseCiOrdering knob | pre-registry |
| `profileOverrides.reviewerRegistrationWindowMinutes` | number | — | — | overrides the profile's reviewerRegistrationWindowMinutes knob | pre-registry |
| `profileOverrides.pollTimeoutMinutes` | number | — | — | overrides the profile's pollTimeoutMinutes knob | pre-registry |
| `profileOverrides.autoRelease` | any | — | — | overrides the profile's autoRelease knob | pre-registry |
| `baseBranch` | string | — | develop | the branch work merges into and branches are cut from | pre-registry |
| `hotfixBaseBranch` | string | — | master | the production-safe branch a hotfix starts from | pre-registry |
| `protectedBranches` | string[] | — | — | branches never rebased, force-pushed or deleted; exact names or patterns | pre-registry |
| `integrationBranch` | string, null | — | `null` | one integration branch for all work; null derives one per release unit | pre-registry |
| `conventionsDoc` | string, null | — | — | the coding-standards file the build engine obeys | pre-registry |
| `lessonsDoc` | string | — | .claude/ds-lessons.md | the lessons store the review skill writes | pre-registry |
| `itemTagFormat` | string | — | [I#####] | the item tag commit messages carry | pre-registry |
| `repoLocalKeys` | string[] | — | — | dotted prefixes of keys the repository's own local skills read; keys at or under one are never reported as unknown | unreleased |
| `branchNaming` | object | — | — | how branches are named | pre-registry |
| `branchNaming.pattern` | string | — | <prefix>/<MM-DD-YY>/<slug> | the branch name pattern | pre-registry |
| `branchNaming.prefixSource` | string | — | — | prose the branch skills follow to choose the prefix | pre-registry |
| `branchNaming.dateFormat` | string | — | MM-DD-YY | the date token's format | pre-registry |
| `epicIntegrationBranches` | object | — | — | per-release-unit integration branches | pre-registry |
| `epicIntegrationBranches.enabled` | boolean | — | `true` | turns integration branches on | pre-registry |
| `epicIntegrationBranches.pattern` | string | — | — | the integration branch name pattern | pre-registry |
| `epicIntegrationBranches.slugRule` | string | — | — | prose rule for the epic slug | pre-registry |
| `epicIntegrationBranches.example` | string | — | — | descriptive only: a sample integration branch name; nothing reads it | pre-registry |
| `epicIntegrationBranches.releaseTarget` | string | — | baseBranch | where a finished release unit lands; baseBranch means the base branch itself | pre-registry |
| `epicIntegrationBranches.fastStoryMerges` | object | — | — | story merges onto the integration branch without a pull request | pre-registry |
| `epicIntegrationBranches.fastStoryMerges.enabled` | boolean | — | — | decided per repository by setup | pre-registry |
| `epicIntegrationBranches.fastStoryMerges.requireLocalVerifyGreen` | boolean | — | `true` | the local gate must be green | pre-registry |
| `epicIntegrationBranches.fastStoryMerges.epicReleaseIsFirstCloudPass` | boolean | — | `true` | the release pull request is the first cloud review | pre-registry |
| `epicIntegrationBranches.fastStoryMerges.localEngines` | any | — | — | descriptive only: the expected local review roster for a fast story merge; the skills resolve behaviour from the active settings | pre-registry |
| `epicIntegrationBranches.autoRelease` | boolean, string | `true`, `false`, ask | `false` | true, false or "ask": whether a finished release unit's pull request merges unasked | pre-registry |
| `epicIntegrationBranches.deleteBranchAfterRelease` | boolean | — | `true` | delete the integration branch after its release | pre-registry |
| `epicIntegrationBranches.mergedStatusName` | string, null | — | Review | the status a landed story moves to, by name | pre-registry |
| `defects` | object | — | — | deferred-defect placement | pre-registry |
| `defects.deferredContainerTitle` | string | — | Deferred defects | the container deferred defects are parked under | pre-registry |
| `commitConventions` | object | — | — | commit message formats | pre-registry |
| `commitConventions.messageFormat` | string | — | — | the commit message format | pre-registry |
| `commitConventions.reviewFixFormat` | string | — | — | the review-fix commit format | pre-registry |
| `commitConventions.epicMergeFormat` | string | — | — | the story merge subject on an integration branch | pre-registry |
| `prBodyTemplate` | object | — | — | pull-request body sections | pre-registry |
| `prBodyTemplate.sections` | object[] | — | — | the body sections, in order | pre-registry |
| `prBodyTemplate.sections[].heading` | string | — | — | **Required.** the section heading | pre-registry |
| `prBodyTemplate.sections[].guidance` | string | — | — | **Required.** how to fill the section | pre-registry |
| `prBodyTemplate.noAiAttribution` | boolean | — | `true` | keeps AI attribution out of pull-request bodies | pre-registry |
| `ci` | object | — | — | CI facts the loop reads | pre-registry |
| `ci.workflowGlobs` | string[] | — | — | the workflow files the CI checks read | pre-registry |
| `ci.draftGateCondition` | string | — | github.event.pull_request.draft == false | the expression every pull-request job gates on | pre-registry |
| `ci.gateJobName` | string, null | — | `null` | the job proving the ready-flip released CI | pre-registry |
| `ci.expectedRunsPerPullRequest` | integer | >= 0 | `1` | executed runs per workflow per pull request | pre-registry |
| `ci.freezeBaseWhileReleasePrReady` | any | — | — | **Deprecated (warn):** ignored since 3.8.0 whatever its value; remove it | pre-registry |
| `preShipChecks` | object[] | — | — | slow suites run locally at the ship boundary | pre-registry |
| `preShipChecks[].name` | string | — | — | the check's name | pre-registry |
| `preShipChecks[].when` | string | perPr, releaseOnly, always | — | **Required.** when the check runs; an entry without it is never selected by pr or release | pre-registry |
| `preShipChecks[].pathGlobs` | string[] | — | — | the paths that select the check | pre-registry |
| `preShipChecks[].timeoutNote` | string | — | — | surfaced before the check runs | pre-registry |
| `preShipChecks[].onlyWhenTouched` | boolean | — | — | a releaseOnly check runs only when the release touches its pathGlobs | pre-registry |
| `preCommitWiringChecks` | array | — | — | repository-specific wiring assertions | pre-registry |
| `verify` | object | — | — | the verification commands | pre-registry |
| `verify.testDir` | string | — | — | where tests live | pre-registry |
| `verify.skipDuringStoryBuilds` | object[] | — | — | slow cloud suites deferred during story builds; each needs a matching CI job | pre-registry |
| `verify.skipDuringStoryBuilds[].name` | string | — | — | **Required.** the suite's display name | pre-registry |
| `verify.skipDuringStoryBuilds[].alwaysRunWhenBase` | string[] | — | — | branch roles (baseBranch, productionBranch) where the suite always applies, paths irrelevant | pre-registry |
| `verify.skipDuringStoryBuilds[].manualTriggerLabel` | string | — | — | the label that requests the suite by hand; the workflow reacts only to it | pre-registry |
| `verify.skipDuringStoryBuilds[].runWhenChangedPaths` | string[] | — | — | globs matched against the complete final diff, both sides of renames | pre-registry |
| `verify.skipDuringStoryBuilds[].ciChecksByBase` | object | — | — | **Required.** required check names per branch role; a role with no mapping requires nothing there | pre-registry |
| `verify.skipDuringStoryBuilds[].ciChecksByBase.baseBranch` | string[] | — | — | check names required on pull requests into the base branch | pre-registry |
| `verify.skipDuringStoryBuilds[].ciChecksByBase.productionBranch` | string[] | — | — | check names required on pull requests into the production branch | pre-registry |
| `generated` | object | — | — | generated build output | pre-registry |
| `generated.paths` | string[] | — | — | paths of generated files | pre-registry |
| `generated.toleratedTypeErrors` | array | — | — | type errors tolerated in generated files | pre-registry |
| `hierarchyRoles` | object, null | — | — | which work types are leaves and release units; null reads as absent | pre-registry |
| `hierarchyRoles.leaf` | string[] | — | — | the one-day leaf work types | pre-registry |
| `hierarchyRoles.releaseUnit` | string | — | — | the release-unit work type | pre-registry |
| `review` | object | — | — | review engines and the CI hold | pre-registry |
| `review.localReviewerName` | string | — | — | the name local findings are attributed to | pre-registry |
| `review.localEffort` | object | — | — | the <effort> tier per round kind | pre-registry |
| `review.localEffort.initial` | string | — | — | the first full round's tier | pre-registry |
| `review.localEffort.followUp` | string | — | — | an ordinary follow-up's tier | pre-registry |
| `review.localEffort.safety` | string | — | — | a P1 or serious-P2 fix check's tier | pre-registry |
| `review.localReReviewScope` | string | — | — | "full" pins every follow-up to the whole diff | pre-registry |
| `review.automatedReviewers` | object[] | — | — | cloud reviewers requested on pull requests | pre-registry |
| `review.automatedReviewers[].name` | string | — | — | **Required.** the reviewer's display name | pre-registry |
| `review.automatedReviewers[].how` | string | requested_reviewer | — | **Required.** how the reviewer is requested; requested_reviewer (a bot through GraphQL by its node id) is the one mechanism the review flow implements | pre-registry |
| `review.automatedReviewers[].bot` | string | — | — | **Required.** the reviewer's bot login | pre-registry |
| `review.automatedReviewers[].value` | string | — | — | **Required.** the identifier the request uses | pre-registry |
| `review.automatedReviewers[].graphqlBotId` | string | — | — | **Required.** the bot's GraphQL node id | pre-registry |
| `review.automatedReviewers[].baseBranches` | string[] | — | — | exact base branches the reviewer is requested on | pre-registry |
| `review.automatedReviewers[].requestPolicy` | string | — | — | every-round (also any other value) or final-head | pre-registry |
| `review.openPullRequestsAsDraft` | boolean | — | — | open pull requests as drafts | pre-registry |
| `review.readyForReviewReleasesCi` | boolean | — | — | marking a draft ready starts CI | pre-registry |
| `review.ciHeldUntilReviewSettled` | boolean | — | — | CI waits for review to settle | pre-registry |
| `review.pollTimeoutMinutes` | number | > 0 | — | the upper bound on waiting for a registered cloud reviewer | pre-registry |
| `review.adaptiveReviewerWait` | boolean | — | `true` | bound the wait by learned reviewer latency | pre-registry |
| `review.resolveAddressedThreads` | boolean | — | — | resolve each addressed review thread | pre-registry |
| `review.notifyWhenSettled` | boolean | — | — | notify when a standalone review settles | pre-registry |
| `review.mandatoryLenses` | object[] | — | — | path-selected review lenses | pre-registry |
| `review.mandatoryLenses[].name` | string | — | — | **Required.** the lens name | pre-registry |
| `review.mandatoryLenses[].paths` | string[] | — | — | **Required.** anchored globs that select the lens | pre-registry |
| `review.mandatoryLenses[].question` | string | — | — | **Required.** the question the lens's finder answers | pre-registry |
| `release` | object | — | — | production release settings | pre-registry |
| `release.productionBranch` | string | — | master | the production release target | pre-registry |
| `release.releaseSource` | string | — | develop | the branch promoted in a release | pre-registry |
| `release.autoDeployOnMerge` | string, null | — | — | one plain-English sentence on what merging to production does | pre-registry |
| `release.releaseBranchPattern` | string | — | — | cut each release as its own protected branch | pre-registry |
| `release.releaseBranchFixExclusions` | string[] | — | — | paths a fix on a release branch may not touch | pre-registry |
| `release.syncWorkflow` | string | — | — | the workflow syncing production into the source | pre-registry |
| `release.mergeTrainBeforeCut` | boolean | — | `false` | merge the support train into the source before each cut | pre-registry |
| `release.productionReview` | object | — | — | review-once economy for the production pull request | pre-registry |
| `release.productionReview.reviewIdenticalTree` | boolean | — | — | false skips re-reviewing a tree already reviewed | pre-registry |
| `release.productionReview.highRiskPaths` | string[] | — | — | paths that still get one pass | pre-registry |
| `release.productionReview.highRiskEngine` | string | — | — | the engine for that pass | pre-registry |
| `release.clearance.provider` | string | github | — | **Required.** the built-in provider | pre-registry |
| `release.clearance.ref` | string | — | refs/clearance/release | the custom ref holding the clearance | pre-registry |
| `release.clearance.staleMinutes` | number | — | `20` | heartbeat age that makes a clearance stale | pre-registry |
| `release.clearance.waitMinutes` | number | — | `180` | how long claim --wait polls | pre-registry |
| `release.clearance.phaseBudgetMinutes` | any | — | — | phase to minutes; a bad value is ignored with a status warning | pre-registry |
| `release.clearance.commands` | object | — | — | **Required.** a provider the repository supplies | pre-registry |
| `release.clearance.commands.claim` | string | — | — | **Required.** the claim command | pre-registry |
| `release.clearance.commands.status` | string | — | — | **Required.** the status command | pre-registry |
| `release.clearance.commands.heartbeat` | string | — | — | **Required.** the heartbeat command | pre-registry |
| `release.clearance.commands.release` | string | — | — | **Required.** the release command | pre-registry |
| `release.clearance.commands.adopt` | string | — | — | **Required.** the adopt command | pre-registry |
| `release.clearance.commands.owed` | string | — | — | the optional owed command | pre-registry |
| `release.docsRepo` | any | — | — | **Deprecated (error):** retired pre-1.0 shape the release skill never acts on; run /devstride:setup docs to migrate it into the docs block | pre-registry |
| `supportTrain` | object, null | — | — | one long-lived branch one-off work batches on; null reads as absent | pre-registry |
| `supportTrain.branch` | string | — | — | the train's branch | pre-registry |
| `supportTrain.fastMerges` | boolean | — | `false` | a one-off merges onto the train without its own pull request | pre-registry |
| `releaseTower` | object | — | — | the release-tower check's settings | pre-registry |
| `releaseTower.overrideLabel` | string | — | release-tower-override | the label passing an owner-approved pull request | pre-registry |
| `releaseTower.hotfixPattern` | string | — | */hotfix/** | heads never held | pre-registry |
| `docs` | object | — | — | documentation hooks | pre-registry |
| `docs.updateOnEpicRelease` | boolean | — | `false` | update docs after each epic release | pre-registry |
| `plugin` | object | — | — | plugin update behaviour | pre-registry |
| `plugin.updateCheck` | boolean | — | `true` | check for a newer release at session start | pre-registry |
| `plugin.autoUpdate` | boolean | — | `true` | update a repository-bound install at session start | pre-registry |
| `plugin.pin` | string, null | — | `null` | a version this repository holds at | pre-registry |
| `session` | object, null | — | — | session job classes; null reads as absent | pre-registry |
| `session.jobClassGate` | boolean | — | `true` | block mixing authoring and execution in one session | pre-registry |
| `localEnvironment` | object, null | — | — | this repository's isolated local instances; null reads as absent | pre-registry |
| `localEnvironment.recreateMode` | string, null | inPlace, newInstance, `null` | `null` | which shape recreate is | pre-registry |
| `localEnvironment.instanceBoundTo` | string | none, directory, branch | none | what the tooling keys an instance on | pre-registry |
| `localEnvironment.fetchOnSessionStart` | boolean | — | `false` | a bounded fetch at session start | pre-registry |
| `stage` | object | — | — | the cloud stage this checkout deploys to | pre-registry |
| `stage.productionStages` | string[] | — | — | stage names that are production | pre-registry |
| `statusLine` | object | — | — | the shipped status line's settings | pre-registry |
| `statusLine.hiddenSegments` | string[] | — | — | segments confirmed not to apply | pre-registry |
| `statusLine.autoUpdate` | boolean | — | `true` | the session-start hook may refresh the copied script | pre-registry |

## Cited by

- `doctor` SKILL.md — §4, the config shape check (runs the validator).
- `skills/setup/references/validation-checklist.md` — check 0, config shape.
