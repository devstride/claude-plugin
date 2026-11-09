---
load: contract
---
# The seam registry — every hook the plugin calls, and every other config key

Generated from `schemas/seam-registry.json` by `scripts/build-config-schema.py --write`;
never edit it by hand. The same registry generates `schemas/ds-config.schema.json`, which
`${CLAUDE_PLUGIN_ROOT}/skills/doctor/scripts/validate-config.py` checks a repository's
`.claude/ds-config.json` against. Schema version: 3.45.0.

A key written `a[].b` is the field `b` of each entry in the array `a`. `since` is the first
release that carries the key, `pre-registry` for every key older than the registry, and
`unreleased` until the next release names it. Keys under a `repoLocalKeys` prefix, keys
starting with `_` and `$schema` are never reported as unknown.

## Hooks

| Key | Shape | Value | Modes | Payload | Verdict | Called by | When unset | Contract | Since |
|---|---|---|---|---|---|---|---|---|---|
| `docs.updateSkill` | skill | string or null | update, check | the delta payload as a fenced JSON block (docs-hooks.md, The delta payload) | check: PASS or FAIL with the fix; update: the pages changed and where they went | update-docs, release 5c, build-item 8, doctor 7, setup G | no documentation system registered; every docs phase reports itself skipped | `skills/release/references/docs-hooks.md` | pre-registry |
| `docs.releaseNotesSkill` | skill | string or null | publish, draft, check | the delta payload, live: true for publish | check: PASS or FAIL with the fix; publish and draft: where the note is | write-release-notes, release 5e, doctor 7, setup G | release notes cannot be requested; --release-notes reports itself unavailable | `skills/release/references/docs-hooks.md` | pre-registry |
| `docs.knowledgeBaseSyncSkill` | skill | string or null | sync, check | sync: {docsOutcome, live} as a fenced JSON block (a re-run names `sync` too); check: none (the skill checks its own preconditions) | KNOWLEDGE BASE SYNC: DONE \| CURRENT \| FAILED (plus evidence); FAILED never reverts the documentation push | sync-knowledge-base, release 5c, doctor 7 | no knowledge base registered: the step reports NOT CONFIGURED and the release continues | `skills/release/references/docs-hooks.md` | 3.20.0 |
| `release.postDeployCheckSkill` | skill | string or null | check, close-out | check followed by {productionBranch, mergeCommit, deployConfirmedAt} | POST-DEPLOY HEALTH: PASS \| FAIL \| NOT RUN (plus CLOSE-OUT OWED); close-out: POST-DEPLOY CLOSE-OUT: DONE \| PARTIAL | post-deploy, release 5a, release 5d, doctor 7 | the close-out reports the health check as not configured | `skills/release/references/post-deploy-check.md` | pre-registry |
| `release.classifySkill` | skill | string or null | classify | classify followed by {productionBranch, releaseSource, head} | RELEASE CLASS: LIGHT \| FULL, then a one-line reason | classify-release, release 0, doctor 7 | RELEASE CLASS: FULL — a release is never light by default | `skills/release/references/release-safety-hooks.md` | 3.20.0 |
| `release.preMergeSkill` | skill | string or null | check | check followed by {productionBranch, releaseSource, head, pullRequest} | PRE-MERGE: CLEAR \| HOLD \| NOT RUN (plus evidence; HOLD states the action first) | pre-merge-check, release 4, doctor 7 | the go-ahead summary and the recap say: pre-merge production check: not configured | `skills/release/references/release-safety-hooks.md` | 3.20.0 |
| `release.deployApproval` | command | string or null | — | RELEASE_COMMIT in the environment | exit 0 approved and read back; 2 not waiting yet; any other exit STOPS | release 4, release 5a, doctor 7 | the deploy runs without an approval step | `skills/release/references/docs-hooks.md` | pre-registry |
| `release.deployVerification` | command | string or null | — | RELEASE_COMMIT in the environment | exit 0 only when production serves RELEASE_COMMIT | release 5a, doctor 7 | the owner confirms the deploy by hand | `skills/release/references/docs-hooks.md` | pre-registry |
| `release.devDeployVerification` | command | string or null | — | RELEASE_COMMIT in the environment (the head the release merges from the source) | exit 0 deployed to the development environment; 2 not deployed yet; 1 the development deploy failed | release 4 | the release does not wait for a development deploy | `skills/release/SKILL.md` | 3.22.0 |
| `release.clearance` | provider-or-commands | object or null | claim, status, heartbeat, release, adopt, owed | each verb's own arguments appended (--wait, --short, <phase> --branch <b> --pr <n>, --force, --yes) | the verdict is stdout's first line; exit codes 0-5 per the provider contract | release 0, release 5b, branch-hotfix rules, doctor 7 | no clearance: release runs as before and nothing is claimed | `skills/release/references/clearance.md` | pre-registry |
| `claims` | provider-or-commands | object or null | claim, heartbeat, release, get, list | <kind> <key>, then the verb's options (claim: --purpose, --phase, --expiry, --takeover; heartbeat: --phase; release: --outcome; list: --kind); the holder in CLAIM_HOLDER, never on argv | stdout's first line (WON, LOST, OK, NOT HOLDER, ABSENT, FORBIDDEN, UNREACHABLE, ERROR), then the claim JSON; exit 0 won or ok, 2 lost, 4 not the holder, 1 anything else | build-item 0, build-item 6, doctor 7 | no claims: build-item selects and builds exactly as before and claims nothing | `skills/build-item/references/story-claims.md` | 3.21.0 |
| `activeAgents.commands.start` | command | **Required.** string | — | <root>, the plan root's item number (only ^[IF][0-9]+$ is ever substituted); ACTIVE_AGENTS_ROOT, ACTIVE_AGENTS_TAG and ACTIVE_AGENTS_STALE_MINUTES exported | exit 0 marked the session active on that root; any other exit, or more than 10 seconds, is one FAILED line and the loop goes on | build-item 0 | the whole activeAgents block is absent: nothing is placed and nothing runs | `skills/build-item/references/active-agents.md` | 3.25.0 |
| `activeAgents.commands.end` | command | **Required.** string | — | <root> optional; the same environment as start | exit 0 cleared the session's presence; any other exit is one FAILED line, never a stop | build-item 0, build-item 7 | the whole activeAgents block is absent: nothing runs | `skills/build-item/references/active-agents.md` | 3.25.0 |
| `presence.command` | command | **Required.** string | — | PRESENCE_EVENT (start, beat or end), PRESENCE_STATE, PRESENCE_SESSION_ID, PRESENCE_MACHINE, PRESENCE_CHECKOUT, PRESENCE_BRANCH, PRESENCE_ITEM, PRESENCE_PLUGIN_VERSION, PRESENCE_INTERVAL_MINUTES, PRESENCE_END_REASON, PRESENCE_AT (epoch milliseconds the report was queued), PRESENCE_ACTIVE_AT (epoch milliseconds of the session's last activity), CLAUDE_CODE_SESSION_ID and CLAUDE_PID exported; run from the repository root through the shell | none read: the exit code is kept in the session's local record; more than 20 seconds is killed; nothing ever blocks a turn | hooks/presence.py | the whole presence block is absent: no hook sends anything and no keeper starts | `skills/setup/references/session-presence.md` | 3.42.0 |
| `verify.typecheck` | command | string[] | — | none; run from the repository root, in array order | exit 0 passes; an error outside generated.paths fails | ultracode-build 2, push rules, build-item 4a, setup G | push asks for a command; fast story merges stay off | `skills/build-item/references/verification-receipts.md` | pre-registry |
| `verify.typecheckCombined` | command | string or null | — | none | exit 0 passes | push rules | the verify.typecheck array is used; this legacy single command is read only when that array is absent | `skills/build-item/references/verification-receipts.md` | pre-registry |
| `verify.test` | command | string or null | — | none | exit 0 is green; red is a stop | ultracode-build 2, build-item 8, setup G | no full-suite gate; fast story merges stay off | `skills/build-item/references/verification-receipts.md` | pre-registry |
| `verify.testSingle` | command | string or null | — | <path/to/test> replaced with the file to run | exit 0 is green | ultracode-build 2, doctor 6 | the story gate widens to verify.test | `skills/build-item/references/verification-receipts.md` | pre-registry |
| `verify.lint` | command | string or null | — | none | exit 0 is green | ultracode-build 2, setup G | no lint step | `skills/build-item/references/verification-receipts.md` | pre-registry |
| `preShipChecks[].command` | command | **Required.** string | — | none; selected by the entry's when, pathGlobs and runAt (a releaseOnly entry with runAt train is selected at the release-train step, and at release 2b unless it passed at the train on the same snapshot) | exit 0 is green; red blocks the pull request, the train merge or the release | pre-ship, pr 2b, release train step 4b, release 2b | no pre-ship checks: an explicit no-op | `skills/pr/references/pre-ship-hold.md` | pre-registry |
| `localEnvironment.create` | command | string or null | — | <name>, <base>, <branch> placeholders | exit 0 made the instance | local-environment, branch-hotfix local environment, build-item 0 | no isolated instances: the current checkout is the only environment | `skills/setup/references/config-defaults.md` | pre-registry |
| `localEnvironment.recreate` | command | string or null | — | <name> per recreateMode, <base> | exit 0 returned the instance to <base>'s schema | local-environment, branch-hotfix local environment | branch-hotfix names the missing command and offers the manual path | `skills/setup/references/config-defaults.md` | pre-registry |
| `localEnvironment.instanceName` | command | string or null | — | none | stdout is the name of this checkout's instance | local-environment, branch-hotfix local environment | an in-place recreate with <name> stops and asks | `skills/setup/references/config-defaults.md` | pre-registry |
| `localEnvironment.seed` | command | string or null | — | <name> | exit 0 seeded the instance | local-environment, branch-hotfix local environment | nothing is seeded | `skills/setup/references/config-defaults.md` | pre-registry |
| `localEnvironment.migrate` | command | string or null | — | <name> | exit 0 migrated the instance forward | local-environment, branch-hotfix local environment | nothing is migrated | `skills/setup/references/config-defaults.md` | pre-registry |
| `localEnvironment.teardown` | command | string or null | — | <name> | exit 0 removed the instance | local-environment, branch-hotfix local environment | instances are left for the owner to remove | `skills/setup/references/config-defaults.md` | pre-registry |
| `pool.checkout` | command | string or null | — | <member> and <purpose> placeholders | exit 0 held; exit 2 not held (busy or in use); any other exit is an error; the first stdout line is quoted | lease-checkout, build-item floors | the repository's own lease protocol applies when its conventions declare a pool; otherwise there is no pool and no lease | `skills/build-item/references/checkout-pool-commands.md` | 3.20.0 |
| `pool.checkin` | command | string or null | — | <member> placeholder | exit 0 returned; any other exit is a refusal, quoted and never retried blindly | return-checkout, build-item floors | nothing is handed back | `skills/build-item/references/checkout-pool-commands.md` | 3.20.0 |
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
| `repoLocalKeys` | string[] | — | — | dotted prefixes of keys the repository's own local skills read; keys at or under one are never reported as unknown | 3.19.0 |
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
| `planIntegrationBranches` | object | — | — | the plan integration branch a plan marked Release scope: plan releases its epics onto | 3.30.0 |
| `planIntegrationBranches.pattern` | string | — | — | the plan integration branch name pattern (<prefix>, the date token, <plan-number>, <plan-title-slug>); unset, no plan can release as one unit | 3.30.0 |
| `planIntegrationBranches.example` | string | — | — | descriptive only: a sample plan integration branch name; nothing reads it | 3.30.0 |
| `defects` | object | — | — | deferred-work placement | pre-registry |
| `defects.deferredContainerTitle` | string | — | Deferred | the title of the plan root's one deferred container | pre-registry |
| `defects.deferredContainerLegacyTitles` | string[] | — | Deferred defects | earlier container titles still matched; only adds to the built-in Deferred defects | 3.24.0 |
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
| `preShipChecks[].runAt` | string | train | — | a releaseOnly check with runAt train runs on the release-train snapshot before the train merges (outside release clearance under release.clearance.scope cut-to-deploy), and is not repeated at the release's step 2b when it passed there on the same snapshot; only valid with when releaseOnly, never with onlyWhenTouched | 3.28.0 |
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
| `release.holdTimeZone` | string | — | UTC | the IANA time zone a release hold's date is read in ("America/Chicago") | 3.36.0 |
| `release.releaseSource` | string | — | develop | the branch promoted in a release | pre-registry |
| `release.autoDeployOnMerge` | string, null | — | — | one plain-English sentence on what merging to production does | pre-registry |
| `release.releaseBranchPattern` | string | — | — | cut each release as its own protected branch | pre-registry |
| `release.releaseBranchFixExclusions` | string[] | — | — | paths a fix on a release branch may not touch | pre-registry |
| `release.migrationRenumber` | object, null | — | — | allow a migration renumber forced by merging the source into the train snapshot; null reads as absent | 3.22.0 |
| `release.migrationRenumber.sqlGlobs` | string[] | — | — | migration files a renumber may delete and re-add under a new name | 3.22.0 |
| `release.migrationRenumber.metaGlobs` | string[] | — | — | migration metadata files a renumber may change | 3.22.0 |
| `release.syncWorkflow` | string | — | — | the workflow syncing production into the source | pre-registry |
| `release.mergeTrainBeforeCut` | boolean | — | `false` | merge the release train into the source before each cut | pre-registry |
| `release.autoStart` | object | — | — | releases that start themselves under a one-winner release-train claim; contract: skills/release/references/auto-start.md | 3.29.0 |
| `release.autoStart.enabled` | boolean | — | `false` | a train landing or a finished release starts the next release; needs a claims block | 3.29.0 |
| `release.backstop` | object | — | — | start a release when work on the release train has waited too long and nothing is releasing it; contract: skills/release/references/backstop.md | 3.45.0 |
| `release.backstop.mode` | string | off, shadow, live | off | off: no check; shadow: record what the backstop would start and change nothing; live: start the release (only after shadow results were checked); needs a claims block | 3.45.0 |
| `release.backstop.maxWaitMinutes` | integer | >= 15, <= 1440 | `120` | how long the oldest landing on the train may wait, by its committer time, before the backstop starts a release; at most a day, the longest a claim can live | 3.45.0 |
| `release.estimates` | object | — | — | honest estimates of when landed work will be live: a measured range after landing, never a clock time before; contract: skills/release/references/estimates.md | unreleased |
| `release.estimates.deployMinutes` | integer | >= 0, <= 1440 | `0` | minutes from the production merge to live, added to both ends of every estimate range and to a score read from git | unreleased |
| `release.lightRelease` | object | — | — | rules for a light release (one the classify skill calls LIGHT) | 3.29.0 |
| `release.lightRelease.standingYes` | boolean | — | `false` | the owner's standing yes: a light release identical to its reviewed train merges and deploys without an in-the-moment yes; contract: skills/release/references/auto-start.md | 3.29.0 |
| `release.fullRelease` | object | — | — | the owner's written standing yes for releases of any class with every gate green; contract: skills/release/references/auto-start.md | 3.37.0 |
| `release.fullRelease.standingYes` | boolean | — | `false` | a release with every gate green, at its reviewed head, and every migration it carries approved by content, merges and deploys without an in-the-moment yes | 3.37.0 |
| `release.fullRelease.ownerDecision` | string | — | — | YYYY-MM-DD: the day the owner wrote the yes, quoted on every merge it makes; absent or invalid: the route asks | 3.37.0 |
| `release.fullRelease.migrationGlobs` | string[] | — | — | the migration files (branch-patterns.md globs); each one a release adds or changes needs an approval; absent or empty: the route asks | 3.37.0 |
| `release.fullRelease.approvedMigrations` | array | — | — | the owner's migration approvals by content: {blob, path, item, approved}, each added on the owner's own yes | 3.37.0 |
| `release.productionReview` | object | — | — | review-once economy for the production pull request | pre-registry |
| `release.productionReview.reviewIdenticalTree` | boolean | — | — | false skips re-reviewing a tree already reviewed | pre-registry |
| `release.productionReview.highRiskPaths` | string[] | — | — | paths that still get one pass | pre-registry |
| `release.productionReview.highRiskEngine` | string | — | — | the engine for that pass | pre-registry |
| `release.clearance.provider` | string | github, devstride | — | **Required.** the built-in provider: github (a custom git ref) or devstride (a DevStride claim) | pre-registry |
| `release.clearance.ref` | string | — | refs/clearance/release | the custom ref holding the clearance | pre-registry |
| `release.clearance.staleMinutes` | number | — | `20` | heartbeat age that makes a clearance stale | pre-registry |
| `release.clearance.waitMinutes` | number | — | `180` | how long claim --wait polls | pre-registry |
| `release.clearance.phaseBudgetMinutes` | any | — | — | phase to minutes; a bad value is ignored with a status warning | pre-registry |
| `release.clearance.scope` | string | release, cut-to-deploy | release | how long a release holds clearance: release (claim before the train, hand back after the post-deploy check) or cut-to-deploy (claim at the cut, hand back once the deploy is confirmed; the check then runs as owed work and gates the next release's merge) | 3.27.0 |
| `release.clearance.credentialsFile` | string | — | — | a KEY=VALUE file holding the DevStride API credentials for the devstride provider; must not be readable by group or others | 3.21.0 |
| `release.clearance.commands` | object | — | — | **Required.** a provider the repository supplies | pre-registry |
| `release.clearance.commands.claim` | string | — | — | **Required.** the claim command | pre-registry |
| `release.clearance.commands.status` | string | — | — | **Required.** the status command | pre-registry |
| `release.clearance.commands.heartbeat` | string | — | — | **Required.** the heartbeat command | pre-registry |
| `release.clearance.commands.release` | string | — | — | **Required.** the release command | pre-registry |
| `release.clearance.commands.adopt` | string | — | — | **Required.** the adopt command | pre-registry |
| `release.clearance.commands.owed` | string | — | — | the optional owed command | pre-registry |
| `claims.provider` | string | devstride | — | **Required.** the built-in provider: the agent's own DevStride MCP connection | 3.21.0 |
| `claims.expiryMinutes` | object | each value integer, 1..1440, else warned and the default stands | — | kind to minutes a claim lives without a heartbeat; an unset story takes 240, release-train 30, any other kind the server's default; the release permit's own claim expires at release.clearance.staleMinutes, not here | 3.21.0 |
| `claims.commands` | object | — | — | **Required.** a claims store the repository supplies | 3.21.0 |
| `claims.commands.claim` | string | — | — | **Required.** the claim command | 3.21.0 |
| `claims.commands.heartbeat` | string | — | — | **Required.** the heartbeat command | 3.21.0 |
| `claims.commands.release` | string | — | — | **Required.** the release command | 3.21.0 |
| `claims.commands.get` | string | — | — | the optional get command | 3.21.0 |
| `claims.commands.list` | string | — | — | the optional list command | 3.21.0 |
| `consequenceNotices` | object | — | — | the notice build-item posts on an item whose change could add billable infrastructure, remove something callers use, remove someone's access or break a published interface; absent means on, with the four default categories, notifying the item's author | 3.41.0 |
| `consequenceNotices.enabled` | boolean | — | `true` | false posts no notice and repeats none | 3.41.0 |
| `consequenceNotices.notify` | string[] | — |  | DevStride users (name, username or email) mentioned on every notice beside the item's author | 3.41.0 |
| `consequenceNotices.categories` | object[] | — |  | the repository's own categories, added to the four defaults | 3.41.0 |
| `consequenceNotices.categories[].id` | string | — | — | **Required.** lower-case words joined by hyphens, unique, never a default's id | 3.41.0 |
| `consequenceNotices.categories[].title` | string | — | — | **Required.** the notice's heading for a finding, one line of at most 80 characters | 3.41.0 |
| `consequenceNotices.categories[].means` | string | — | — | **Required.** what counts, in plain words; the agent judges the diff against it | 3.41.0 |
| `activeAgents` | object, null | — | — | the Active Agents board, tag and the repository's presence commands; absent or null means the plugin writes nothing to DevStride for this feature and runs nothing | 3.25.0 |
| `activeAgents.boardId` | string, null | — | `null` | the board plan roots are placed on; null until /devstride:setup agents adopts or creates it, and build-item places no root meanwhile | 3.25.0 |
| `activeAgents.tagName` | string | — | agent active | the tag that marks a root an agent is working under, allowed on every plan-root type | 3.25.0 |
| `activeAgents.tagColor` | string | gray-medium-dark, red, pink, orange, yellow, lime, green, teal, blue, blue-medium, purple | green | the tag's colour | 3.25.0 |
| `activeAgents.staleMinutes` | integer | >= 1 | `20` | minutes without a heartbeat after which the repository's presence implementation treats a session as gone; exported to both commands | 3.25.0 |
| `activeAgents.commands` | object | — | — | **Required.** the repository's own start and end commands | 3.25.0 |
| `presence` | object, null | — | — | the repository's own presence command, run by the plugin's hooks for every session (session start, prompts, tool uses and finished turns, throttled; a keeper every intervalMinutes; session end); absent or null, or a blank command, runs nothing and writes nothing | 3.42.0 |
| `presence.intervalMinutes` | integer | 1..60, else warned and the default stands | `5` | minutes between the keeper's beats while the session's process lives; a value outside 1 to 60 is ignored with a warning and reads as 5 | 3.42.0 |
| `release.docsRepo` | any | — | — | **Deprecated (error):** retired pre-1.0 shape the release skill never acts on; run /devstride:setup docs to migrate it into the docs block | pre-registry |
| `releaseTrain` | object, null | — | — | one long-lived branch one-off work batches on; null reads as absent | pre-registry |
| `releaseTrain.branch` | string | — | — | the train's branch | pre-registry |
| `releaseTrain.fastMerges` | boolean | — | `false` | a one-off merges onto the train without its own pull request | pre-registry |
| `releaseTrain.smallFixes` | object, null | — | — | limits under which a fast one-off is a small fix and skips its own local review pass; null reads as absent | 3.23.0 |
| `releaseTrain.smallFixes.maxFiles` | integer | >= 1 | — | **Required.** at most this many changed files | 3.23.0 |
| `releaseTrain.smallFixes.maxChangedLines` | integer | >= 1 | — | **Required.** at most this many changed lines, added plus removed | 3.23.0 |
| `releaseTrain.lateArrivals` | string | restart, offer | offer | restart: a one-off landing during the train's review restarts that review over the whole snapshot; offer: it joins only on the owner's word | 3.23.0 |
| `supportTrain` | object, null | — | — | the old name of releaseTrain, still read when releaseTrain is absent (doctor notes it; both together is an error) | 3.22.0 |
| `supportTrain.branch` | string | — | — | the old name of releaseTrain.branch | 3.22.0 |
| `supportTrain.fastMerges` | boolean | — | — | the old name of releaseTrain.fastMerges | 3.22.0 |
| `supportTrain.smallFixes` | object, null | — | — | limits under which a fast one-off is a small fix and skips its own local review pass; null reads as absent (the old name, read when releaseTrain is absent) | 3.23.0 |
| `supportTrain.smallFixes.maxFiles` | integer | >= 1 | — | **Required.** at most this many changed files (the old name, read when releaseTrain is absent) | 3.23.0 |
| `supportTrain.smallFixes.maxChangedLines` | integer | >= 1 | — | **Required.** at most this many changed lines, added plus removed (the old name, read when releaseTrain is absent) | 3.23.0 |
| `supportTrain.lateArrivals` | string | restart, offer | offer | restart: a one-off landing during the train's review restarts that review over the whole snapshot; offer: it joins only on the owner's word (the old name, read when releaseTrain is absent) | 3.23.0 |
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
| `pool` | object, null | — | — | the repository's checkout-pool commands, set both or neither (one alone is an error); null reads as absent; contract: skills/build-item/references/checkout-pool-commands.md | 3.20.0 |
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
