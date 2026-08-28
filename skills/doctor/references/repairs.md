# Phase 2 — what doctor may repair, and what it must only report

Phase 1 diagnoses and touches nothing. Phase 2 offers to fix. This file decides which findings are
eligible, because that decision must be a **fixed classification and not a judgement made in the
moment**. A diagnostic people trust enough to run first is one whose blast radius they already
know; a skill that decides case by case how much to repair has no blast radius anyone can state.

## The tiers

**Tier A — doctor performs the repair itself.** A finding qualifies only when its fix meets every
one of these:

- every write lands inside **this repository's `.claude/`** directory;
- it needs **no network** and no external account;
- it changes **no git state** — no stage, commit, checkout, branch, remote or push;
- it is **undone by deleting or reverting a file**, with nothing else to unwind;
- and doctor can **verify it worked** by re-running a Phase 1 check.

**Tier B — doctor offers to run the command that owns the fix.** The repair exists already, in a
skill or a CLI built for it. Doctor never reimplements one of these; a second implementation of
`setup`'s config writer would drift from it, and the copy that drifts is the one running while
somebody believes they ran setup. Doctor names the exact command, runs it on a yes, and reports
what it printed.

**Tier C — report only, never repair.** Everything else, and specifically anything that edits a
workflow file, changes git state, writes a DevStride record, alters machine-wide or cross-repository
configuration, or reaches a deployed stage.

## The classification

| Finding | Tier | What Phase 2 does |
| --- | --- | --- |
| Status line missing or half-configured (§4) | **A** | Write it — mechanics below |
| Status line set only in `~/.claude/settings.json` (§4) | **A** | Offer the same repair, which is what makes it repository-wide |
| `gh` not authenticated (§1) | **B** | `gh auth login` |
| `gh` missing a scope (§1) | **B** | `gh auth refresh -s <all needed scopes in ONE list>` |
| Auth coming from `GH_TOKEN`/`GITHUB_TOKEN` (§1) | **C** | `refresh` cannot touch an environment token; say to unset it or reissue |
| Plugin behind the newest release (§2) | **B** | `claude plugin marketplace update devstride` then `claude plugin update <installed-id>@devstride` — **the id must match the installed one** (`devstride@devstride` or `ds@devstride`), or the command reports the plugin as not installed and silently leaves the old version. Then say a **restart** is required; doctor cannot do that half |
| Config absent, or branch roles that do not resolve (§4) | **B** | `/devstride:setup` |
| Unrecognized or misspelled config key (§4) | **C** | Doctor prints suggested JSON; the owner decides. A "correction" to a key doctor merely failed to recognize is a silent config change |
| `localEnvironment` / `stage` gaps (§4) | **B** | `/devstride:setup` |
| `conventionsDoc` points at a missing file (§4) | **C** | Only the owner knows which document was meant |
| A configured command that does not resolve (§4) | **C** | Installing a toolchain is not doctor's business, and it may be an alias |
| Missing `on.pull_request.types`, ungated jobs, absent `concurrency` (§5) | **C** | Workflow files are code and reach CI for everyone; report the edit |
| Merge gates / branch protection (§6) | **C** | Repository settings affecting every contributor |
| A named docs skill missing, or a legacy `release.docsRepo` (§7) | **B** | `/devstride:setup docs` |
| More than one DevStride MCP server connected (§3) | **C** | Doctor cannot know which organization is the right one, and removing the wrong server disconnects work elsewhere |
| Not a git repository, no `origin`, `git`/`gh` not installed (§1) | **C** | Outside the repository, or the precondition for having one |

When a finding is not in this table, it is **tier C**. Absence is a decision, not a gap to fill by
analogy.

## The status-line repair

Phase E3 of `/devstride:setup` owns these mechanics and is the authority if this ever drifts:

1. Copy `${CLAUDE_PLUGIN_ROOT}/skills/setup/references/statusline.sh` to `.claude/statusline.sh`
   and `chmod +x` it. **Copy it verbatim** — it is repo-agnostic and reads the consuming
   repository's own config at runtime, so there is nothing to substitute, and a `{{PLACEHOLDER}}`
   edited in is a bug rather than a customization.
2. **Never overwrite an existing `.claude/statusline.sh`.** The owner may have edited it or written
   their own — and the commonest half-configured repository is exactly the one that has the script
   and lacks the setting. Say it is already there and leave it.
3. MERGE this into `.claude/settings.json` — never replace the document:

   ```json
   { "statusLine": { "type": "command", "command": "bash .claude/statusline.sh", "padding": 0 } }
   ```

   **Never write it to `.claude/settings.local.json`**, which is conventionally gitignored: that
   recreates the one-machine-only problem the repair exists to remove.
4. Verify, because a status line fails silently — Claude Code renders nothing and reports no error:

   ```bash
   printf '{"workspace":{"current_dir":"%s"}}' "$PWD" | bash .claude/statusline.sh; echo
   ```

   Non-empty output is the pass. Confirm neither file is gitignored (`git check-ignore` exits 1).
5. Leave both files **unstaged and uncommitted**, say so, and say why it matters: until they are
   committed the status line is still one machine's, which is the failure being repaired.

## Making the offer

- **One list, one question.** Number the eligible findings, one line each — the finding, the action,
  the tier — then ask once for all / some by number / none. A prompt per finding turns a report into
  an interrogation, and a queue of yes/no prompts manufactures agreement rather than collecting it.
- **Name the exclusions.** Say which failures are not on the offer list and that they are tier C by
  rule. Otherwise a short offer list reads as a short problem list.
- **Never bundle a tier B command into an "all".** Each tier B repair runs something that reaches
  outside this repository — an account, an install, another skill. Confirm those individually even
  when the batch was accepted wholesale.
- **Report each outcome as you go**, and re-run the corresponding Phase 1 check afterwards. A
  repair that fails stops itself, not the batch.
- **Non-interactive invocation → no repairs.** Print the list as a recommendation. Doctor is called
  by other skills; none of them consented to a write.
