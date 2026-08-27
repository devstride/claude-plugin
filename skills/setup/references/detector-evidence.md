# Detector evidence — why each rule in Phase A is shaped the way it is

The rules live in the body; this file holds the evidence and the failure stories behind them, per
detector, for explaining an `ambiguous` row's candidates to the user or for whoever changes a
detector.

## Why detection comes before questions

Every question the user answers by hand is friction at the worst possible moment — the first ten
minutes with a new tool, before it has done anything for them. Nearly every value in this config
is already sitting in the repository: the lockfile knows the package manager, `package.json`
knows the test command, git knows the branches, `PATH` knows which review engines exist. The
corollary matters as much as the rule: a wrong detected value arrives wearing the authority of
evidence, and the user accepts it without reading — which is why `unknown` is an honest answer
and never a failure.

## A2 — two lockfiles, and the placeholder trap's cousin

Two lockfiles usually mean a half-finished migration, and picking the loser produces commands
that fail on every machine but the one that ran them — which is why the rule is to list both and
never silently pick. Corepack's `"packageManager": "pnpm@10.0.0"` is a declaration of exactly
what the repository uses, and a repository that gitignores its lockfile still has it; a field
that contradicts a lockfile is a disagreement worth surfacing rather than resolving. The
ecosystem is worth recording even when it prefills nothing — it lets the interview ask an
ecosystem-shaped question instead of a blank one.

## A4 — npm init, and why `run` is mandatory

`npm init` writes `"test": "echo \"Error: no test specified\" && exit 1"`, which matches `test`
exactly and fails by design. Reporting it `detected` hands the user a value that makes every
merge gate fail on first use — precisely the class of wrong answer the status column exists to
prevent. The bare command form (`pnpm lint`) works in pnpm, yarn and bun but not in npm, where
only a handful of names are built-in verbs; a detector that drops `run` emits a config that fails
on the first npm repository it meets while looking perfectly correct in review. And several
workspaces with test scripts stay `ambiguous` because the loop runs ONE test command — only the
user knows whether that is a root script that fans out or one particular workspace, and a `&&`
chain nobody has ever run is an invention, not a detection. Silently dropping workspaces from
`verify.typecheck` hides type errors the user believes are covered.

## A5 — the draft-gate traps

The `needs`-closure rule exists because GitHub's default job condition requires every dependency
to *succeed*, so one skipped dependency skips the dependent — exactly how real workflows are
built: one cheap job carries the draft condition and the expensive ones hang off it. Requiring
the whole closure to be gated, or checking only for an explicit `if`, reads a correctly-gated
repository as ungated and then writes all three hold booleans `false`, turning a working setup
off.

The `types` rule is the commonest shape of the bug precisely because nothing looks wrong: without
`ready_for_review`, marking a pull request ready creates **no workflow run at all** — the draft
condition is never even evaluated — and the loop waits for a run that will never exist. A list
naming `ready_for_review` and nothing else is its own trap: a fix push after a red run starts no
run either, and the close-and-reopen fallback has no `reopened` to fire on. `converted_to_draft`
earns its place once per-PR `concurrency` is on: the run it creates (every job skips) cancels the
run a mistaken non-draft open started. And `opened` matters because the loop's own pull requests
open as drafts — it only ever produces a skipped run for them — but a standalone review on a
non-draft pull request settles against CI it assumes is already running.

The mixed row (some jobs gated, others not) is real and common — a repository part-way through
adopting the hold, or one that deliberately runs a cheap check on drafts. Neither `true` nor
`false` is honest there: `true` claims a hold part of CI ignores, `false` discards the part that
works. The second row (types missing) is the one worth being stubborn about: prefilling `true`
would configure the loop to rely on a hold the repository cannot deliver. The third row (nothing
gated) is a legitimate configuration whose cost — CI on open and again after every fix push — is
the user's to accept.

## A6 — why enumerate first, and why the cache lies

Probing only for `develop`/`main`/`master` would not merely miss a repository whose long-lived
branches are `production`, `trunk`, `release` or `staging` — it would report a four-branch
repository as single-branch and hand every role to the one name it recognized. Both halves of the
enumeration matter: a fresh clone commonly has exactly one local branch, and keeping the
`origin/` prefix writes `origin/develop` as `baseBranch`, which reads plausibly and fails at the
loop's first checkout. Remote-tracking refs go stale — `origin/develop` can outlive the branch it
names — and since the loop's first act is to fetch and pull against `origin`, a role assigned
from a stale ref fails immediately; `origin/HEAD` is set at clone time and frequently absent, so
an error there is ordinary. The single-branch prefill exists because the four role keys all have
shipped defaults: an unstated role is not neutral — it silently becomes `develop` or `master`,
and the failure surfaces much later, at the first release or hotfix. The release source is the
`protectedBranches` entry people leave out because it is usually the base branch and looks
covered; where it is not, it is the *head* of the production pull request, and an unlisted branch
is fair game to rebase and force-push.

## A6 — the enumeration procedure and the branch-role path table

The commands: `git branch --format='%(refname:short)'` and `git branch -r --format='%(refname:short)'`
— both, because a fresh clone commonly has exactly one local branch. Normalize: enumerate
`refs/remotes/origin/*`, strip the `origin/` prefix, drop the symbolic `origin/HEAD` entry,
deduplicate against local names. Default branch: `git symbolic-ref refs/remotes/origin/HEAD`,
set at clone time and frequently absent — an error is ordinary; the fallback is
`git remote show origin`, a network call under the ground rules.

The path table, when the unambiguous-pair rule does not decide (constants in the body: all four
keys on every path; topic branches never candidates; no silent promotion to production):

| Situation | Assignment |
|---|---|
| One **production-role candidate** (or `trunk`) plus topic branches | All four roles to it, `ambiguous`, saying so |
| Only one branch at all | All four to it, `ambiguous` each — single-branch is legitimate, but so is a repository whose second branch is not created yet, and they want different answers |
| One development-role candidate, no production-role one | `baseBranch` + `release.releaseSource` suggested; production and hotfix roles `ambiguous` |
| Multiple candidates in either role set | Those roles `ambiguous`; show the matches and ask |
| Branches but no conventional name | All four `ambiguous`, every branch offered, the `origin/HEAD` default named likeliest; `protectedBranches` offers the long-lived ones |

## A7 — why a missed probe is not a detected null

One probe that missed is not evidence of absence: the tool may be a shell alias a non-interactive
shell never loaded, or a reviewer with a name nobody thought to check. A `detected` row is
advertised as copyable, so a detected `null` would quietly switch off a review engine the user
has installed — and they would never see the moment it happened. On the cloud side, a
half-populated reviewer entry silently requests nothing (the request mutation returns success
either way), and entitlement, repository settings and organization policy are all invisible from
here — which is why a positive probe is a candidate to confirm, never a fact, and why only a real
pull request ever settles it.

## A8 — why the template detection is thorough

Once setup writes the generic sections, the pull-request skill treats them as authoritative and
quietly stops using the format the team actually agreed on — detection is what turns "should be
replaced" into a question that gets asked. Checking one spelling in one directory reports "no
template" for most repositories that have one, which is worse than not looking. And a heading
captured without its guidance drops the instructions or checklist the team wrote underneath from
every pull request thereafter.

## A9 — why recreate is asked, not inferred

`recreate` exists because `migrate` and `seed` usually only go forward, so neither can bring an
instance back to an older base — the transition `branch-hotfix` performs. Nothing in a file
distinguishes a command that rebuilds from one that reseeds, a compose file proves a stack exists
rather than that `docker compose up` is how this team starts it, and whether a second checkout
gets its own database is a property of the tooling's design that no file states — which is why
`recreateMode` and `instanceBoundTo` are never `detected`, and why `null` (no such command) is an
answer only the owner can give.

## Cited by

- `skills/setup/SKILL.md` — the Phase A pointer (run A5/A6, explain an `ambiguous` row, change a
  detector), A5's traps line (§A5), A6's enumeration line (§A6), and A6's path-table line.
- `skills/doctor/SKILL.md` §5 — the four-events evidence citation (§A5).
- `skills/doctor/references/silent-failures.md` §5 — the same citation (one home, two citers).
