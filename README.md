# DevStride for Claude Code

DevStride's agentic delivery loop, packaged as a Claude Code plugin. Plan a roadmap into
existence, then let the loop walk it one story at a time — branch, build, adversarially review,
merge, and release — against your own repository and your own DevStride organization.

> **Status: early.** The twenty delivery-loop skills and the DevStride MCP connection are both
> bundled — installing the plugin is all the *configuration* the connection needs, though you still
> sign in once. `/devstride:setup` then configures the plugin for your repository and proves the
> config by running it.

## Install

```
/plugin marketplace add devstride/claude-plugin
/plugin install devstride@devstride
```

<details>
<summary>The shorter <code>ds</code> spelling</summary>

The marketplace carries a second entry, `ds`, pointing at the same plugin:

```
/plugin install ds@devstride
```

**It is the same plugin** — same skills, same version, one manifest. `devstride` is the canonical
entry; `ds` exists only so the install line is shorter to type.

**It does not shorten the commands.** Measured on an actual alias install: the skill namespace comes
from the plugin manifest's name, not from the marketplace entry you installed through, so skills
still invoke as `/devstride:plan`, `/devstride:build-item` and so on either way. If you were hoping
for `/ds:plan`, this is not that — and giving you that would mean a second plugin manifest, which
this project does not do.

**Install one or the other, never both.** Nothing stops you, but the two entries install as separate
plugins from the same source: you get two copies of the tree on disk and every skill twice in the
picker.

**And remember which one you installed.** Every command that names a plugin needs the id you
actually installed under, so a `ds` install updates with:

```bash
claude plugin marketplace update devstride
claude plugin update ds@devstride
```

Running the `devstride@devstride` form against an alias install reports the plugin as not installed —
which reads like something broke, when in fact you are simply on the other id. `claude plugin list`
tells you which you have. From plugin 3.1.0, a direct `/devstride:update` resolves the installed
alias and scope for you.

</details>

<details>
<summary>Rolling it out to a team</summary>

You can declare the marketplace and enable the plugin for a whole repository by committing
`.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "devstride": { "source": { "source": "github", "repo": "devstride/claude-plugin" } }
  },
  "enabledPlugins": { "devstride@devstride": true }
}
```

**This registers and enables the plugin — it does not install it.** Each person still runs
`claude plugin install devstride@devstride` once on their machine. Worth saying out loud in your
onboarding docs, because the failure is silent: the skills simply are not there, with nothing
explaining why.

Two more things to know before a team relies on this. If your repository's `.gitignore` excludes
`.claude/`, the settings file needs an explicit exception or it will never be committed. And an
installed plugin stays on its version until someone updates it, so teammates who install at
different times can be running different versions — see
[Versioning & updates](#versioning--updates).

</details>

## Connect to DevStride

The plugin bundles the DevStride MCP server, so there is nothing to configure — but there **is** one
step: you have to sign in once.

```
/mcp
```

Connect the server listed as **`plugin:devstride:devstride`**. That opens your browser, you sign in
to DevStride and pick an organization, and you are done. Installing the plugin never asks for a
credential and never stores one.

**Do this before running any skill.** Until you sign in the server contributes *no tools at all* —
DevStride rejects unauthenticated requests, including the tool listing — and nothing prompts you.
A skill will simply report that it cannot find DevStride tools. That is the signed-out symptom;
it is not a misconfiguration. (An *authorization* error is different, and means your session
expired or a key is wrong.)

> **Signing in grants read _and write_ access** to the organization you choose, at the same level
> you have in the DevStride app — creating, updating and deleting items included. There is no
> sandbox or dry-run mode, and no narrower scope to grant: the skills write to live data by design.
> Read the consent screen before accepting.

A plain `devstride` entry in `/mcp` is **not** this server — that is one you or your project
configured separately. The bundled one always carries the `plugin:` prefix.

**Switching organization.** Your sign-in is bound to the single organization you picked; there is no
in-session switch. To move to another, run `claude mcp logout plugin:devstride:devstride` and connect
again.

<details>
<summary>Connecting without a browser (CI, containers, headless agents)</summary>

Browser sign-in needs a browser. Where there isn't one, add your own server with an API key.
Generate one under **Profile Settings → API Keys**, then:

```bash
claude mcp add --transport http --scope user devstride https://api.devstride.com/mcp \
  --header "X-DevStride-Api-Key: $DEVSTRIDE_API_KEY" \
  --header "X-DevStride-Api-Secret: $DEVSTRIDE_API_SECRET" \
  --header "X-DevStride-Organization-Id: $DEVSTRIDE_ORG_ID"
```

Only those three are required. `X-DevStride-Organization-Slug` is optional — supplying it just saves
the server one round trip resolving the slug on startup.

Prefer this command over hand-writing a project `.mcp.json`: project-scoped servers need interactive
approval before they connect, which is precisely what an unattended environment cannot give. Keep the
credentials in environment variables as shown and never paste the key or secret in literally — MCP
config files are routinely committed.

Your server and the bundled one **coexist**; the plugin's is `plugin:devstride:devstride`, yours is
`devstride`. That is safe **only while the bundled one is signed out**, because a server you never
sign in to contributes nothing. If you sign in to both, they expose identically-named tools and the
skills — which call tools by bare name — cannot tell them apart. Two authenticated DevStride servers
is how work intended for one organization lands in another. Keep exactly one signed in, using
`claude mcp logout plugin:devstride:devstride` to clear the bundled one if you have already
connected it.

The same applies to pointing at a non-production DevStride: define your own server and sign out of
the bundled one, which is production-only by design. The bundled server cannot be removed on its
own — disabling it means disabling the plugin, and that takes the skills with it.

</details>

<details>
<summary>Trimming the tool catalog</summary>

By default the server advertises its full tool catalog, which is a meaningful share of your context
budget in every session. Adding the header `X-DevStride-Toolset: core` advertises only the everyday
groups instead, cutting that roughly by a third.

The bundled configuration does **not** set it, deliberately: `core` un-lists groups the delivery
skills use, including pull requests and analytics. Unlisted tools remain callable by name, so the
skills are expected to keep working — but that is a trade to make knowingly. Add the header on your
own server if you want the smaller catalog.

</details>

## Configure it for your repo

The skills read one file in **your** repository — `.claude/ds-config.json` — for everything
repo-specific: branch names, how to type-check and test, which review engines exist, release
settings. Every key has a deterministic shipped fallback, but delivery can use it only when the
named branch or command actually exists. The file is how you adapt the loop to your repository, and
**where it disagrees with a fallback, the file wins**. The plugin never ships anyone's config.

Prefer `/devstride:setup`: it enumerates branches that actually exist on `origin`, recognizes common
development names such as `develop`, `staging`, `canary` and `test`, recognizes production names
such as `main`, `master`, `production` and `prod`, and asks instead of guessing when several match.
It writes explicit branch roles, so the static no-config fallbacks are not silently aimed at refs
this repository does not have.

The example below illustrates a repository that promotes `staging` to `production`. Use your
repository's real branch names rather than copying those two values:

```json
{
  "baseBranch": "staging",
  "hotfixBaseBranch": "production",
  "protectedBranches": ["staging", "production"],
  "release": {
    "releaseSource": "staging",
    "productionBranch": "production"
  },
  "conventionsDoc": "AGENTS.md",

  "verify": {
    "typecheck": ["pnpm check:ts"],
    "test": "pnpm test",
    "testSingle": "pnpm test -- <path/to/test.spec.ts>",
    "lint": "pnpm lint"
  },

  "review": {
    "localCommand": null,
    "localAssistCommand": null,
    "automatedReviewers": [],
    "openPullRequestsAsDraft": true
  },
  "plugin": {
    "updateCheck": true,
    "autoUpdate": true,
    "pin": null
  }
}
```

| Key | What it controls |
|---|---|
| `baseBranch` | The branch work merges into and branches are cut from. |
| `hotfixBaseBranch` | The production-safe branch an urgent fix starts from. |
| `protectedBranches` | Branches never rebased, force-pushed, or deleted. |
| `release.releaseSource` | The branch promoted during a production release, normally the same as `baseBranch`. |
| `release.productionBranch` | The production release target. |
| `conventionsDoc` | Your coding-standards file. The build skill reads it and obeys it — this is how the loop writes code that looks like yours. |
| `verify.typecheck` | Type checks; unchanged-tree receipts prevent identical reruns. |
| `verify.test` | Your test suite. Green is a gate, not a suggestion. |
| `verify.testSingle` | How to run one test file, for the tight build loop. |
| `verify.lint` | Linter, run when the diff touches the paths it covers. |
| `review.localCommand` | A local CLI for PR/release merge-boundary review. Context-first templates receive the cumulative ledger; `<effort>` is routed by risk. |
| `review.localAssistCommand` | Optional read-only support for ambiguous cross-module work, critical boundaries, or stubborn diagnosis; never a routine story call. |
| `review.automatedReviewers` | Cloud reviewers to request on each pull request. `[]` means none; nothing is requested or waited on. |
| `review.openPullRequestsAsDraft` | Open pull requests as drafts so review and pre-ship checks settle before CI runs once. With PR workflows, disabling the hold makes the optimized loop not ready. |
| `review.adaptiveReviewerWait` | Absent means on: the wait for a cloud reviewer is bounded by that reviewer's learned latency (p95 + slack) instead of the full timeout. `false` pins the fixed bound. |
| `review.localReReviewScope` | Legacy-named shared follow-up scope. Absent means computed delta/full; `"full"` pins every stream to the whole diff. |
| `profileOverrides.verificationGrouping` | `"per-finding"` restores one verifier per finding at HIGH-RISK; the default `"per-file"` verifies findings one agent per file-group, auth-boundary findings always singly. |
| `docs.updateSkill` | Name of a local skill in your repo (`.claude/skills/<name>/`) that updates your documentation for a shipped delta. `null` means no documentation system; the release skill's docs pass reports itself skipped. |
| `docs.releaseNotesSkill` | Name of a local skill that writes and publishes a release note. Used only when you pass `--release-notes` to the release skill — notes are never written unasked. |
| `plugin.autoUpdate` | Setup writes `true`: session start may update only a repository-bound project/local install. Shared user installs hand off to `/devstride:update`; managed installs stay with their administrator. After verified changes, reload the plugin (restart only if reload fails). |

The full contract — every key, its shape and default — is in the
[configuration reference](https://docs.devstride.com/developer-experience/agentic-skills/configuration-reference).

**CI cost.** The loop runs CI once per pull request, on the final reviewed diff — the draft hold
guarantees it. What the hold does not cover is the rest of the bill: superseded runs, a
production-branch push re-testing the tree the base branch just tested, a release pull request
re-run every time something merges beneath it. `/devstride:ci-audit` measures all of it;
`/devstride:setup ci` applies the workflow mechanics that remove it (as reviewed diffs); the loop
rules — freeze the release source while a release is ready, report executed runs per workflow
per pull request — are on by default (`ci.freezeBaseWhileReleasePrReady`, `ci.expectedRunsPerPullRequest`).

**Documentation and release notes.** The plugin never edits your documentation itself. `setup` asks
where your docs live, how they are updated, and how release notes are pushed, then scaffolds two
local skills in your repository that hold those answers; the config only names them. A production
release updates core documentation by default — after the merge is confirmed and the deploy verified,
never before (suppress with `no docs`) — and writes a release note **only** when you pass
`--release-notes` (`true`, or `draft` to review it first) — and only after the
production merge is confirmed and the deploy verified live. Nothing in the loop decides on its own
that a release "deserves" a note.

**Plain-English questions and recaps.** Every skill translates agent and tool output into the
simplest accurate words before showing it. Questions lead with the real decision and consequence;
technical commands and identifiers remain as evidence. Each built item says what changed, what was
checked and what happens next; every merge or release lists what landed and whether it is live; and
doctor explains each finding, why it matters, what it fixed and the final result. The shared rule is
loaded once per top-level run so composed skills do not repeatedly spend context on it.

> **Or run `/devstride:setup` and let it write this for you.** It inspects your repository, maps your
> DevStride work types onto the loop's roles, asks only about what it could not work out, writes the
> file, and then executes it — running your verify commands, resolving your branches, probing your
> declared review engines — so you find out it is right while you are still here to fix it. Re-run it
> whenever the repository changes shape: it proposes only what changed and merges, preserving hand
> edits and anything it does not recognize.
>
> The block above stays useful either way, as a minimal working file to start from.

## Choose a delivery profile

One word sets how much rigor the loop spends per unit of work — how finely a plan is sliced, how
deep each spec goes, how wide merge review fans out, how many contextual review cycles run,
and which gates a story passes before it merges:

| Profile | For | Shape |
|---|---|---|
| `prototype` | A small team validating an idea; no production users yet | One story per user-visible slice; light specs; bounded story risk screen; touched tests; no per-story PR; full review when the release unit auto-releases |
| `standard` (default) | A working product | Stories of an hour or two; capped specs; targeted story checks; contained review with configured engines once at the merge boundary; full suite at release |
| `enterprise` | Regulated, revenue-bearing, or shared-platform code | Fine stories; full specs; full story gate; widest merge review; two-cycle normal target |

`/devstride:setup` asks which one and writes `"profile"` into `.claude/ds-config.json`; a plan can
carry its own choice as a `Delivery profile:` line in its root item's description; an explicit
profile word in a skill's arguments wins over both. Floors hold under every profile: each story
gets a risk screen and green local gate; authentication, migrations and deployed contracts get
focused verification immediately; the initial full adversarial pass runs at the direct/release-unit
merge boundary; P1/serious-P2 fixes are re-reviewed until clear; and CI waits for that final head. The full contract is
`skills/plan/references/delivery-profiles.md`.

Picked too heavy a profile and watching the loop take far too long? `/devstride:rebalance <root>
<profile>` re-slices the not-started part of a live plan in place.

## Your first plan

With the plugin installed, DevStride connected, and a config file in place:

```
/devstride:plan I1234
```

Pass the item you want to plan under — a Module, Capability, or Epic in your DevStride
organization. This is an interactive discovery loop, not a document generator: it asks about scope,
sequencing and trade-offs, and creates nothing until you have signed off on the shape.

Then execute what you planned, one item at a time:

```
/loop /devstride:build-item
```

Each pass selects the next unblocked item, marks it in progress, branches, builds, reviews, merges,
and updates the item — then picks up the next one. Run `/devstride:build-item` without `/loop` to do
exactly one.

## Skills

Skills are namespaced by the plugin, so they invoke as `/devstride:<name>`.

**Planning** — shape and maintain a roadmap in DevStride:

| Skill | What it does |
|---|---|
| `plan` | Drives a roadmap into existence under a parent item through an interactive discovery loop |
| `comprehend-plan` | Recursively reads a plan — descriptions and comment threads, every level — before any edit |
| `insert-story` / `insert-defect` | Splices new work into a live plan's dependency chain, dated and ordered |
| `rationalize-gantt` | Backfills dates and rationalizes the dependency graph so the timeline reads as a clean cascade |
| `rebalance` | Re-slices a live plan's not-started leaves to a different delivery profile — merging or splitting stories, preserving every absorbed spec, archiving originals with a pointer |

**Delivery** — walk the plan one item at a time:

| Skill | What it does |
|---|---|
| `build-item` | The orchestrator: select → branch → build → review → merge → completion ritual → repeat |
| `ultracode-build` | The build engine for one scoped item: fast feedback, exact-tree verification receipt, bounded risk screen, and focused critical-boundary verification when needed |
| `review` | Runs every configured reviewer, settles findings, then releases CI — re-reviewing from the latest common cycle anchor and continuing P1/serious-P2 fixes until clear |
| `pr` | Opens a pull request and runs the review-and-settle loop |
| `push` | Stages, commits, type-checks, and pushes following the repo's commit conventions |
| `branch-feature` / `branch-hotfix` | Cuts a working branch from the development or production branch |
| `create-story` / `create-defect` | Creates a one-off item outside any plan and delivers it end to end |
| `release` | Promotes the release branch to production with a full gated review; updates docs through your local docs skill by default, and writes release notes only on `--release-notes`, after the deploy is confirmed |
| `setup` | Inspects your repo, maps your work types onto the loop's roles, writes `.claude/ds-config.json`, then proves it by running it |
| `doctor` | Checks git, `gh`, the plugin, DevStride, config, CI gates, docs and personal status-line settings; after the shared replacement is committed and verified, it can separately remove only the personal `statusLine` key you approve while preserving every other setting and script |
| `update` | Updates the exact loaded copy, verifies its official tag and files, then stops for a checked plugin reload (restart is the fallback) |
| `ci-audit` | Measures what CI actually costs: executed runs per workflow per pull request (the design is one each), post-merge push minutes, release pull requests re-run by a moving base — and names the offenders. Read-only |

## Versioning & updates

2.5.0 loads roughly a quarter less skill text per invocation than 2.4.0 — every body sits
under a committed token budget, with rationale moved to per-skill references loaded only at
the step that needs them; the full before/after table is in the CHANGELOG.

Current version: **3.2.0** — see [CHANGELOG.md](CHANGELOG.md) for what changed, and
[RELEASING.md](RELEASING.md) for how releases are cut.

**Getting a new release.** Claude's marketplace auto-update is off by default for a manually added
marketplace. Separately, Setup defaults `plugin.autoUpdate` on only for a project/local install
bound to that repository; it never gives one repo authority over a shared user or managed copy.

*Once, to stop thinking about it:* open `/plugin`, select the devstride marketplace, and choose
**Enable auto-update**. Claude Code then refreshes the marketplace and its installed plugins for you.

*From version 3.1.0 onward:* invoke `/devstride:update`. It finds the exact copy that loaded the
command, verifies the official tag and installed files, and updates that copy. When reload is
needed, run `/reload-plugins` and confirm it reports no DevStride load error; restart if reload is
unavailable or fails. Do not invoke another DevStride command first.

*To get 3.1.0 from 3.0.0 or older, or when the skill is unavailable:* use two commands, and
**both** are needed —

```bash
claude plugin marketplace update devstride   # refresh the catalog
claude plugin update devstride@devstride     # upgrade the installed plugin
```

Then run `/reload-plugins` and confirm it reports no DevStride load error; restart Claude Code if
reload is unavailable or fails. Two things to watch:

- The update command needs a **fully-qualified** id — `devstride@devstride`, or `ds@devstride` if you
  installed through the [short alias](#install). `claude plugin list` shows which you have, and using
  the wrong one reports the plugin as not installed rather than doing nothing visible; the bare plugin name
  reports "not found".
- It acts on the **user** scope by default. If you installed with `--scope project`, `local` or
  `managed`, pass the same `--scope` or it will report the plugin isn't installed and change nothing.

Running only the first command is a common mistake — it refreshes marketplace metadata and reports
success while leaving your installed copy exactly where it was.

**Compatibility.** An existing skill name (`/devstride:<name>`) and an existing
`.claude/ds-config.json` key keep working, and keep meaning the same thing, until a **MAJOR** bump.
New skills, new config keys, and changed skill behavior arrive in MINOR bumps; wording fixes in
PATCH.

**Pinning.** Append `@<tag>` to the marketplace source to pin to a release. There is no `--ref`
flag — the ref goes in the source itself.

> **`marketplace remove` also uninstalls every plugin that came from it.** Re-adding the marketplace
> does *not* bring the plugin back, so the reinstall line below is required, not optional. Skip it
> and you are left with a registered marketplace and no skills, and nothing says why.

```bash
claude plugin marketplace remove devstride
claude plugin marketplace add devstride/claude-plugin@devstride--v<version>
claude plugin install devstride@devstride
```

Every release is tagged, so any version in the [changelog](CHANGELOG.md) is pinnable. To unpin, run
the same three commands with the bare `devstride/claude-plugin` as the source. Reload the plugin
afterwards; restart only if reload fails.

### The plugin tells you when it is behind

From 1.2.0 the plugin checks at every session start, using a six-hour release cache so most starts
make no network request. It is silent when current or offline, reads the version *this session* is
running, and always finishes under a deadline. Per-repository config may disable checks, update a
project/local copy bound to that repo, or pin a version. A shared user copy hands off to
`/devstride:update`; a managed copy stays with its administrator; an ambiguous copy hands off to
Doctor. Claude marketplace auto-update remains the automatic option for user-scope installs.
`DEVSTRIDE_PLUGIN_UPDATE_CHECK=0` disables the check for CI/headless runs. Doctor reports the last
result. Repository automatic updates remain session-start-only; direct `/devstride:update` is
separate user authority and stops before newly loaded behavior can enter an active delivery loop.

## License

MIT — see [LICENSE](./LICENSE).
