---
load: contract
---
# Agent session summary — a short, scrubbed record of what the agent did on a story

**Goal:** a person looking at a work item can see which agent session worked it, for whom, on what
branch and pull request, and how it ended, without reading a transcript. It is a record, not a
gate: nothing here ever stops delivery.

## When it applies

Only when the config has a `sessionSummary` block (registry contract for `sessionSummary`). No
block → write nothing, say nothing; build exactly as before. Hotfixes outside a work item have no
item number to attach to and write nothing.

## When to write

One call per moment; a second call for the same item and session updates the record and keeps the
fields it omits.

1. **Story start** — right after the claim is won (or straight after selection when `claims` is
   not set): item, session id, agent, start time, who directed it, model, intent, provider and credential
   name. No `outcome`: absent means still running.
2. **Completion ritual (step 6)** — branch, pull request, files, tools, review engines, `endedAt`
   and `outcome: completed`.
3. **A STOP or an interruption** — whatever the loop knows by then, `endedAt`, and `outcome:
   interrupted` (the user stopped it, a held claim, a gate that needs a person) or `failed` (the
   build or a gate failed), with `errorReason` as one plain line. Write it before the final report.

## What to compose

From what the loop already knows; omit anything unavailable rather than guessing.

- `itemNumber` the item number; `sessionId` the agent's own session id; `agent` `{name, version?}`;
  `startedAt` ISO time the story began; `endedAt` ISO time.
- `directedBy` the person who started or directed this session (not the account the agent signs in
  with; the server records that itself): their DevStride `username` when the session knows it (for
  example they named it), else the checkout's `git config user.email`, sent ONLY as
  `directedBy.email` (the server resolves it to a member and never stores the address; anyone who is
  not a member is dropped). Omit `directedBy` when neither is known.
- `model` `{name?, version?}` the model the session runs on; `intent` at most 1000 characters in
  your own words: what this story is for, not its description pasted in.
- `branch`; `pullRequest` `{number?, url?}`; `filesTouched` from
  `git diff --name-only <base>...HEAD` taken on the story branch BEFORE it merges (after a fast
  merge `HEAD` is the base and the diff is empty; at most 200); `toolsTouched` the names of the tool families
  used (at most 100); `reviewEngines` `[{name, outcome?}]` from the review ledger (at most 10);
  `errorReason` at most 500 characters.
- `provider` the model provider; `credentialName` the NAME or id of the credential in use, never its
  value, and omit it when you only know the value.

**Never send** a transcript, a prompt, file contents, command output, environment values, an
unredacted key or anyone's email address in free text.

## Scrub first, always

Pipe the JSON through `python3 ${CLAUDE_PLUGIN_ROOT}/skills/build-item/scripts/session_summary.py`
and send its output, never your draft. It redacts key blocks, URL credentials, bearer and basic
tokens, common provider tokens, JWTs, `password=` style assignments, email addresses and long
token-like words in prose; caps lengths and list sizes; and drops unknown keys. Exit 1 (a required
field is missing) → skip the write for this moment and say so once. The server scrubs again; that
is a backstop, not the plan.

## Writing

- **`provider: devstride`**: call your own DevStride MCP tool `record_agent_session` with the
  scrubbed fields.
- **`commands.write`**: run it with the scrubbed JSON on stdin. Stdout's first line is the verdict
  (`WROTE`, `ABSENT`, `FORBIDDEN`, `UNREACHABLE`, `ERROR`); exit 0 wrote, 1 anything else.

## When it cannot be written

`ABSENT` (the server has no `record_agent_session`), `FORBIDDEN`, `UNREACHABLE`, any other error,
or no session id to key it on → carry on without it and say so once per session in one line. A
failed summary never stops, delays or fails a story.

## Progress row

`Session summary`: written, not configured, or skipped (reason).

## Cited by

- `skills/build-item/SKILL.md` — step 6's completion ritual.
- `skills/doctor/references/claims-checks.md` — the `sessionSummary` provider check.
