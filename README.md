# DevStride for Claude Code

DevStride's agentic delivery loop, packaged as a Claude Code plugin. Plan a roadmap into
existence, then let the loop walk it one story at a time — branch, build, adversarially review,
merge, and release — against your own repository and your own DevStride organization.

> **Status: early.** The fifteen delivery-loop skills and the DevStride MCP connection are both
> bundled — installing the plugin is all the *configuration* the connection needs, though you still
> sign in once. The guided setup command that writes your repo config is still to come.

## Install

```
/plugin marketplace add devstride/claude-plugin
/plugin install devstride@devstride
```

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

## Setup

The skills read a per-repo config file, `.claude/ds-config.json`, for everything repo-specific:
branch names, verify/test/lint commands, review engines, and release settings. Every key has a
shipped default, so the skills degrade sensibly before you write one — but the file is where you
adapt the loop to your repository, and where it disagrees with a default, the file wins.

A guided setup command that inspects your repo and writes that file for you is in progress.

## Skills

Skills are namespaced by the plugin, so they invoke as `/devstride:<name>`.

**Planning** — shape and maintain a roadmap in DevStride:

| Skill | What it does |
|---|---|
| `plan` | Drives a roadmap into existence under a parent item through an interactive discovery loop |
| `comprehend-plan` | Recursively reads a plan — descriptions and comment threads, every level — before any edit |
| `insert-story` / `insert-defect` | Splices new work into a live plan's dependency chain, dated and ordered |
| `rationalize-gantt` | Backfills dates and rationalizes the dependency graph so the timeline reads as a clean cascade |

**Delivery** — walk the plan one item at a time:

| Skill | What it does |
|---|---|
| `build-item` | The orchestrator: select → branch → build → review → merge → completion ritual → repeat |
| `ultracode-build` | The build engine for a single scoped item, including an adversarial review pass |
| `review` | Runs a PR through every configured review engine, settles every finding, then releases CI |
| `pr` | Opens a pull request and runs the review-and-settle loop |
| `push` | Stages, commits, type-checks, and pushes following the repo's commit conventions |
| `branch-feature` / `branch-hotfix` | Cuts a working branch from the development or production branch |
| `create-story` / `create-defect` | Creates a one-off item outside any plan and delivers it end to end |
| `release` | Promotes the release branch to production, with a full gated review and a docs pass |

## Versioning & updates

Current version: **0.3.3** — see [CHANGELOG.md](CHANGELOG.md) for what changed, and
[RELEASING.md](RELEASING.md) for how releases are cut.

**Getting a new release.** Updates are **not** applied automatically — an installed plugin stays at
its version until you ask for the new one. Two steps, and both are needed:

```bash
claude plugin marketplace update devstride   # refresh the catalog
claude plugin update devstride@devstride     # upgrade the installed plugin
```

Then restart Claude Code to apply it. Two things to watch:

- The update command needs the **fully-qualified** `devstride@devstride`; the bare plugin name
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
flag — the ref goes in the source itself:

```bash
claude plugin marketplace remove devstride
claude plugin marketplace add devstride/claude-plugin@devstride--v<version>
```

Every release is tagged, so any version in the [changelog](CHANGELOG.md) is pinnable. Unpin by
removing it and re-adding the bare `devstride/claude-plugin`.

## License

MIT — see [LICENSE](./LICENSE).
