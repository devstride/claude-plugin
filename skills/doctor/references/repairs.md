# Phase 2 — what doctor may repair, and what it must only report

Phase 1 only diagnoses; Phase 2 offers fixes. These tiers are fixed—never improvise eligibility.

## The tiers

**Tier A — doctor repairs.** The fix must meet all five rules:

- every write lands inside **this repository's `.claude/`**, except the one personal-key cleanup
  defined below;
- it needs **no network** and no external account;
- it changes **no git state**;
- it is **undone by deleting/reverting a file** (or restoring the cleanup's private key backup);
- and doctor can **verify it worked** by re-running a Phase 1 check.

**Tier B — offer the existing repair command.** Never reimplement a skill/CLI. On yes, run its exact
command, summarize plainly, and show the exact command/result only as evidence.

**Tier C — report only.** This includes workflows, git/DevStride/deployed state, and machine-wide
config beyond the narrow personal `statusLine` exception.

## The classification

| Finding | Tier | What Phase 2 does |
| --- | --- | --- |
| Status line missing or half-configured (§4) | **A** | Write it — mechanics below |
| Status line set only in `~/.claude/settings.json` (§4) | **A** | Offer the same repair, which is what makes it repository-wide |
| Personal `statusLine` in local or user settings (§4) | **A, narrow exception** | After the shared pair is committed and clean, offer key-only cleanup separately |
| A structurally absent status-line segment (§4) | **A** | Ask what it should read from; write `stage.resolve`, or record `statusLine.hiddenSegments` |
| `gh` not authenticated (§1) | **B** | `gh auth login` |
| `gh` missing a scope (§1) | **B** | `gh auth refresh -s <all needed scopes in ONE list>` |
| Auth coming from `GH_TOKEN`/`GITHUB_TOKEN` (§1) | **C** | `refresh` cannot touch an environment token; say to unset it or reissue |
| Plugin behind newest (§2) | **C** | Tell the user to invoke `/devstride:update` separately, then stop. Older copies use the native bootstrap; Doctor never invokes the explicit-only skill |
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

Anything absent from this table is **tier C**.

## The status-line repair

Phase E3 of `/devstride:setup` is authoritative:

1. Copy `${CLAUDE_PLUGIN_ROOT}/skills/setup/references/statusline.sh` verbatim to
   `.claude/statusline.sh`; `chmod +x`. It reads repo config at runtime—substitute nothing.
2. **Never overwrite an existing script.** Say it exists and leave it.
3. MERGE this into `.claude/settings.json` — never replace the document:

   ```json
   { "statusLine": { "type": "command", "command": "bash .claude/statusline.sh", "padding": 0 } }
   ```

   Never use `.claude/settings.local.json`; that recreates one-machine-only config.
4. Verify non-empty output (failure is otherwise silent):

   ```bash
   printf '{"workspace":{"current_dir":"%s"}}' "$PWD" | bash .claude/statusline.sh; echo
   ```

   Confirm neither file is ignored. Leave both **unstaged and uncommitted**; until committed, the
   fix reaches one machine. Do not offer cleanup until the owner commits and reruns doctor.

## Personal status-line cleanup

Once shared is committed in `HEAD`, clean in both index and working tree, and passes, inspect each
scope with `${CLAUDE_PLUGIN_ROOT}/skills/doctor/scripts/statusline-override.py`. Show path/scope,
never command; ask outside the batch. Local: “Remove only `statusLine` from `<file>` so shared takes over?” User:
shared already wins here; ask: “Remove the fallback? Repositories without their own project status
line lose it; repositories with project status lines keep theirs.”

Yes → `remove` with that scope and `--expect-sha256 <digest>`; no → unchanged. The helper proves
shared, resolves accessible `disableAllHooks`, rejects unsafe files/races, preserves siblings, and
backs up the key in a private durable state directory. Report the path. Recovery merges that sole
key into the same file, never replacing that file. Refusal has no manual fallback. Restart, rerun
`doctor config`, inspect `/status`. Known managed/CLI overrides block cleanup as tier C.

## Blank status-line segments

A blank segment is already invisible. This repair records whether the fact is absent or unset.

Use `${CLAUDE_PLUGIN_ROOT}/skills/setup/references/statusline-segments.md`. **Ask only about `stage`**; other blanks are
transient/reported elsewhere. Silence means “do not know”: leave it unchanged, never hide it.

## Making the offer

- **One list, one batch question (personal cleanup excluded).** Number findings with action/tier,
  then ask once for all / some by number / none. A prompt per finding turns a report into
  an interrogation, and a queue of yes/no prompts manufactures agreement rather than collecting it.
- **Name the exclusions.** Say which failures are not on the offer list and that they are tier C by
  rule. Otherwise a short offer list reads as a short problem list.
- **Never bundle a tier B command into an "all".** Each tier B repair runs something that reaches
  outside this repository — an account, an install, another skill. Confirm those individually even
  when the batch was accepted wholesale.
- **Never bundle personal status-line removal into "all".** Each scope gets its own explicit
  question after the shared line passes.
- **Report each outcome as you go**, and re-run the corresponding Phase 1 check afterwards. A
  repair that fails stops itself, not the batch.
- **Non-interactive invocation → no repairs.** Print the list as a recommendation. Doctor is called
  by other skills; none of them consented to a write.
