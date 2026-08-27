# Interview and merge rationale — Phases C, D, E and F

The rules live in the body; this file holds the reasoning, for justifying an answer to the user
or when a re-run proposes removing or migrating a key.

## Phase C — why the mapping is confirmed even when obvious

The `hierarchyRoles` answer decides where the loop branches, what it counts down to, and what "a
release" means for this repository; getting it wrong plans work at one size and releases it at
another. Spellings are read from the organization because organizations rename these levels and
have typos — one real organization's capability level is spelled `Capabilty` — and the returned
string, misspellings included, is what the loop compares against. On a missing connection, a
guessed `hierarchyRoles` naming work types the organization does not have is worse than an absent
one: absent is visible and reported as follow-up, wrong silently matches nothing and the loop
treats every item as a one-off. The signed-out server contributes no tools at all — the failure
mode to avoid is a wall of tool errors that reads like a bug when it is one browser sign-in.

## Phase D — why the questions are shaped this way

Interview length is the product's first impression: asking someone to re-approve forty facts
their own repository just proved is how a good setup feels bad — hence bulk confirmation for
`detected` rows and questions only for the rest. The profile is never `detected` because nothing
in a repository says how much rigor its owners want. `release.autoDeployOnMerge` is asked because
it is the sentence the release skill quotes back to an owner at the production gate, so they know
exactly what they are approving — left unasked, it gets improvised at the one moment improvising
is least acceptable. The `prototype` warning exists because `autoRelease: true` means a release
unit merges to the base branch the moment its last item lands, with no human saying so; where
that branch is production, or promotes to it without a gate, that is production with nobody's
hand on it — and the owner must hear it from setup, not from a deploy. The lessons store keeps a
single writer because a file created here would be a second writer producing a store with no
lessons in it; the review skill creates it the first time it has a lesson worth keeping.

## Phase E — why the roster must be literal

Every later run reads the roster keys as fact, so an aspirational config does real damage
quietly: a claimed engine is never probed again, it simply never reviews. Fast story merges get
no pull request and no CI of their own — the local engines and suites are the only gate — so
enabling them with nothing behind them merges code nothing checked. The defaults are copied
verbatim because the delivery skills compare against those strings literally: a default
paraphrased into something that means the same thing no longer matches.

## Phase F — why the merge is shaped this way

Setup being re-runnable is the difference between a command people run again and one they run
once, and a re-run that cannot tell a hand-edit from a stale value overwrites deliberate work.
"Propose only what would change" is wider than detection because restricting it to detector
values silently drops changed interview answers and missing keys — which is how a stale setting
survives a re-run the user thought had removed it. `_`-prefixed annotations survive because real
configs carry `_readme` notes documenting hard-won reasons beside the values they explain; a
rewrite that drops them destroys the reasoning while leaving the config working. The one allowed
deletion (a documentation hook the owner says no longer applies) exists because leaving it in
place is not conservative: the release skill reads a present name as a registered hook and would
invoke a skill with nothing left to update. The `release.docsRepo` migration exists because
configs written before 1.0 carry docs settings the plugin itself used to act on; on refusal the
block stays and the release skill reports it deprecated.

## Cited by

- `skills/setup/SKILL.md` — the pointer at the end of Phase D ("Read … when a Phase C/D answer
  needs justifying … or when a re-run (Phase F) proposes removing or migrating a key").
