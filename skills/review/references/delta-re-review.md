# Follow-up review — one effective scope per contextual pass, never a blind rerun

`targetAdversarialCycles` normally allows two useful cycles across Claude, local CLI, cloud,
rebase, pre-ship and code-changing CI repair rechecks. Past that target, only a verified P1 or
serious P2 opens another safety cycle; repeat until the next pass finds none. Those continuations
also override `maxLocalReviewRounds`. No event resets the count.

## One scope decision for every stream

Everything is SHA-pinned and three-dot. If `review.localReReviewScope` is `"full"`, use `full`;
otherwise run `scripts/rereview-scope.sh --base <ref> --reviewed-head <sha>` using the prior
cycle's common launch anchor. Capture one anchor before each wave and freeze the head until all
streams settle; per-engine result SHAs never replace it. Never
use a capped pull-request file list or judgement that a patch “looks small.” The script decides:

| Decision | When |
|---|---|
| `none` | `HEAD == reviewed-head`; no follow-up is needed and no cycle is spent |
| `full: history-rewritten` | `reviewed-head` is not an ancestor of `HEAD` |
| `full: new-file <path>` | the delta touches a file the preceding reviewed patch did not touch; delta renames match both source and destination |
| `full: delta <n> of <m> lines (> 50%)` | added + deleted delta lines exceed half the preceding reviewed patch's lines |
| `delta` | otherwise |

The effective range is `<base>...HEAD` for `full`, `<cycle-anchor>...HEAD` for `delta`, and no launch
for `none`. Pass that same scope and range to Claude, contextual local CLI, cloud context, and the
ledger; never call a full result a delta.

`--threshold` may change the fixed 50% boundary. The script returns one JSON line with scope,
reason, file/line/byte counts, new files, threshold and both SHAs. Report its facts, for example
`cycle N scope: delta — 8 of 56 lines (14.3%), 2 of 14 files, 314 B`.

## Cumulative context is mandatory

Read `${CLAUDE_PLUGIN_ROOT}/skills/review/references/review-ledger.md`. Every follow-up Claude
task and every local-CLI launch receives the compact ledger: earlier finding ids, fixes,
dismissal rationales, reviewed heads, requested range, normal target and safety status. The orchestrator
distills it; raw reviewer output is never pasted. A finding with a terminal disposition is not
re-raised without new evidence.

Before a cloud re-request, update the one `<!-- devstride:review-context -->` pull-request
comment from that same ledger. Record the SHA of the returned review; a request alone proves no
head was reviewed.

## Local-CLI launch forms

The following facts were verified on Codex CLI 0.147.0 and should be re-checked when its syntax
changes:

1. `codex exec review --base <sha>` reviews `<sha>...HEAD`.
2. `review --base` and `review --commit` reject a custom prompt.
3. Prompt-only `codex exec -` follows an explicit instruction to inspect
   `git diff <sha>...HEAD`; it can therefore receive both the scope and the ledger.
4. `--commit` reviews one commit, while a fix delta commonly contains several.

Two configuration shapes remain supported:

- **Context-capable template** — `review.localCommand` contains `<context>`. On every contextual
  launch, remove any `review --base <base>` pair, replace `<context>` with `-`, and feed a prompt
  whose first instruction gives the exact three-dot range, followed by the cumulative ledger.
  This works for `delta` and `full` scope. Substitute `<effort>` with the task route from
  `delivery-profiles.md` before launch.
- **Legacy base-only template** — substitute `<base>` (or append ` --base <value>` when the old
  template has no placeholder) for the initial launch. Do not run a contextless follow-up. Use
  the contextual Claude effective-scope validation in its place, report the local follow-up as degraded,
  and point to `/devstride:setup review`.

A `<context>` template without `<base>` is valid only when it is a prompt-first command that
accepts stdin on every launch; setup probes that form. For one that carries both placeholders,
the initial base-mode launch removes `<context>` rather than substituting `-`, so it cannot wait
on empty stdin. A CLI that rejects its configured contextual form is this-run degradation.

## Cycle accounting

The first wave spends cycle 1; each concurrent contextual wave spends one more. `none` spends
nothing. Rebase, pre-ship and real-CI repairs share the count. At the normal target, lower findings
get their `fixFloor` disposition, affected checks and one main-agent ledger inspection. A verified
P1/serious P2 instead requires another contextual cycle after its fix; repeat with no numeric cap
until a pass finds none. While one remains, no patch change, no progress or unavailable required review is a human
gate. A clean cycle may finish early. This prevents routine ping-pong without capping release safety.

## Cited by

- `skills/review/SKILL.md` — effective follow-up scope, normal target and safety continuation.
- `skills/setup/references/config-defaults.md` — local command placeholders and scope override.
