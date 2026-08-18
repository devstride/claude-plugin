# Validation checklist — the checks, and what each failure means

The checks Phase G runs, and a failure-mode table: what the user sees, what usually causes it, and
the exact fix. A `FAIL` reported without its row is a `FAIL` the user has to go and diagnose alone,
which is the situation this whole phase exists to prevent.

## Outcomes

Four, and the distinction between the last three is the point:

| Outcome | Means |
|---|---|
| `PASS` | The check ran and the thing works |
| `FAIL` | The check ran and the thing is broken — a row below applies |
| `SKIPPED` | The user declined to run it. Their choice, recorded, not a failure |
| `UNVERIFIABLE` | The check could not run — offline, or a prerequisite absent. **Not a failure** |

**Run every check even after one fails**, and report all of them. Someone with three problems should
learn all three in one run.

**`loop-ready` requires zero `FAIL`.** Skips and unverifiables do not block it, provided the verdict
names them — a verdict that hides a skipped test suite is claiming more than it checked.

## The checks

1. **Verify commands** — every `verify.typecheck` entry, and `verify.lint`. Exit 0 is the pass.
   `generated.toleratedTypeErrors` matches are not failures where `generated.paths` matches the file.
   `verify.test` is offered, never forced.
2. **Branch refs** — `baseBranch`, `release.releaseSource`, `release.productionBranch` and
   `hotfixBaseBranch` all resolve, and `protectedBranches` still contains base, production and
   release source.
2b. **GitHub toolchain** — an `origin` remote by name, on GitHub, with `gh` installed and
   authenticated for that host. Checked unconditionally: the delivery half cannot push, open a pull
   request or merge without them.
3. **Declared review engines** — the local CLI is invocable; the cloud reviewer's host is
   authenticated and the repository readable. Only what the config declares is checked.
4. **Work-type roles** — every name in `hierarchyRoles` still resolves in the organization.
5. **Lessons store** — the `lessonsDoc` parent directory exists and is writable. **A missing file is
   the normal state**; the review skill creates it on the first lesson.
6. **CI ordering** — a warning when the draft hold simply does not engage; a **`FAIL`** when a
   draft-gated workflow's trigger cannot rerun it, because then CI can never settle.

## Failure modes

### Verify commands

| Symptom | Likely cause | Fix |
|---|---|---|
| A typecheck or lint command exits non-zero, and the tree is clean | The script name drifted from `package.json` after a rename or a workspace move | Re-run `/devstride:setup` to re-detect, or edit the entry directly |
| The command is not found at all | The package manager is wrong for this repository, or the command needs `run` and does not have it | Check the composed command against `package.json`; every manager accepts `<pm> run <script>` |
| It fails only in a monorepo workspace | The `cd <workspace>` prefix points at a workspace that moved or was renamed | Re-detect; the workspace list comes from the workspace globs |
| It fails and the tree is **dirty** | Almost certainly the uncommitted change, not the config | Commit or stash, re-run validation, and only then suspect the config |
| Generated-file type errors fail the check | `generated.toleratedTypeErrors` or `generated.paths` does not match the real error text or path | Widen the pattern to the error as actually printed, or regenerate via `generated.regenCommand` |

### Branch refs

| Symptom | Likely cause | Fix |
|---|---|---|
| A branch ref does not resolve | The remote has not been fetched in this clone | `git fetch origin`, then re-run validation |
| It still does not resolve after a fetch | The branch was renamed or deleted upstream | Correct the key to the branch that exists — `baseBranch`, `release.productionBranch`, `hotfixBaseBranch` or `release.releaseSource` |
| It resolves but the loop later fails on checkout | The value carries a remote prefix (`origin/develop`) | Strip it; git and every forge call want the branch name |
| `protectedBranches` no longer contains base, production or release source | Hand-edited, or a branch role changed without it | Add them back. This list is what stops the loop force-pushing or deleting those branches — and the release source is the one that gets left out, because it is usually the base branch and looks already covered |
| No `origin` remote, or it is not GitHub | A fork checkout naming its remotes `upstream`/`fork`, or a non-GitHub forge | The delivery skills address `origin` literally and assume GitHub; rename the remote, or accept that only the planning half runs here |
| `gh` missing or unauthenticated | Never installed, or signed out | Install GitHub CLI and `gh auth login`. Without it there are no pull requests, no review threads and no merges |
| `gh` authenticated but read-only | A default or narrowly-scoped token, or an account with read access only | `gh auth refresh -s repo,read:org`. Authentication is not authorization — a read-only token passes every probe and then cannot push a branch or merge anything |
| A branch resolves locally but the loop fails on its first fetch | A stale remote-tracking ref for a branch deleted upstream, or a local-only branch | `git fetch --prune origin`, then correct the key to a branch that exists on the remote |

### Review engines

| Symptom | Likely cause | Fix |
|---|---|---|
| A declared local CLI does not respond | Not installed, or installed as a shell alias a non-interactive shell never loads | Install it so it is on `PATH`, or set `review.localCommand` to `null` — the roster degrades to the built-in adversarial pass, which is a legal configuration |
| `gh auth status` fails | Signed out, or authenticated against a different host than the repository's | `gh auth login` for the right host. If auth comes from `GH_TOKEN`/`GITHUB_TOKEN`, `gh auth refresh` cannot help — reissue the token |
| Repository read fails while auth succeeds | The token's scopes are short, or it has no access to this repository | `gh auth refresh -s repo,read:org` (add `workflow` if the loop will edit workflow files) |
| A cloud review never arrives on a real pull request, though this check passed | **This check cannot catch that** — see below | Confirm the reviewer is enabled for the repository and the account is entitled to it |

**What the cloud-reviewer check does not prove.** Authentication and read access are preconditions,
not proof that a review request will register. The request mutation reports success even when it
creates nothing, so the only real evidence is a `review_requested` event on an actual pull request
timeline. A `PASS` here means *nothing is obviously in the way*.

### Work-type roles

| Symptom | Likely cause | Fix |
|---|---|---|
| A name in `hierarchyRoles` no longer resolves | The work type was renamed or archived in the organization | Re-run the role-mapping phase and confirm against the current hierarchy |
| It resolves but the loop treats everything as a one-off | `releaseUnit` names a type that exists but is not the container above the leaves | Re-map. The release unit is the level whose completion cuts a release |
| The check is `UNVERIFIABLE` | The DevStride server is not connected — the signed-out symptom is *absent tools*, not an error | Run `/mcp` and connect the bundled server, then re-run validation |

### Lessons store

| Symptom | Likely cause | Fix |
|---|---|---|
| The parent directory is missing or not writable | `lessonsDoc` points somewhere that does not exist | Point it at a directory that does, or create it. The review skill needs to write there eventually |
| The file itself is missing | **Not a failure.** The store is created on the first lesson worth keeping | Nothing to do |

### CI ordering (warning only)

| Symptom | Likely cause | Fix |
|---|---|---|
| Drafts are configured but no workflow is draft-gated | The repository never adopted the review-then-CI ordering | Gate the jobs on the draft condition, or set the three `review` CI-ordering keys `false`. `/devstride:doctor` diagnoses this in detail |
| Workflows are gated but marking ready starts no run | `ready_for_review` is missing from `on.pull_request.types` — the defaults do not include it | Add it. Note that declaring `types` **replaces** the defaults, so the list also needs `opened`, `synchronize` and `reopened` |
| CI never re-runs after a review-fix push | An explicit `types` list has `ready_for_review` but dropped `synchronize` | Add the missing events. All four are needed: the flip starts the run, `synchronize` covers the fix push, `reopened` is the fallback, and `opened` covers a standalone review on a non-draft pull request — which skips the flip and settles against CI that, without it, was never created |

**Never edit a workflow to fix any of these.** This skill writes one file,
`.claude/ds-config.json`, and that boundary does not bend for a helpful one-line change to
somebody's CI.
