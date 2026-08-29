# The local review engine — any capable model, not one vendor

The local CLI reviewer is the second adversarial opinion beside Claude's own pass. **It is not tied
to any vendor or model.** `review.localCommand` is a command line; anything that satisfies the
contract below can hold the role, including open-weight models run locally.

## The contract

An engine qualifies when all four hold. Nothing else is assumed:

1. **Its first token resolves on `PATH`** — `command -v <first token>`. The roster check runs this
   before every launch; a command that does not resolve is this-run degradation, reported, never
   silently skipped.
2. **It accepts the review prompt**, by one of two shapes:
   - **Context mode (preferred)** — the template carries `<context>`, replaced with `-`, and the
     prompt arrives **on stdin**. Every cycle then receives the exact scope plus the cumulative
     ledger, which is what lets cycle N+1 check whether a fix held instead of starting cold.
   - **Base mode (legacy)** — the template carries `<base>`, replaced with the ref to diff against.
     A contextual follow-up cannot be fed a ledger this way, so it is skipped rather than run
     blind; the engine gets one cycle.
3. **It writes its findings to stdout** as text the loop can read back. No schema is imposed.
4. **It can run read-only.** The reviewer must not edit the tree. Where the CLI has a sandbox or
   read-only flag, the template sets it.

`<effort>` is optional: where present it is substituted with the reasoning tier routed for the
task. Prefer it over pinning one tier literally, so cheap work is not billed at the top tier.

Two further rules apply whatever the engine:

- **Disable any agent tooling the CLI would load by default**, the DevStride MCP above all. A
  reviewer that can reach live project data can wedge mid-review and return a clean, empty
  result that reads exactly like "no findings".
- **Leave model selection to the operator** where the CLI supports it. A template that hardcodes a
  model overrides organizational policy and dates quickly.

## Choosing one

**When nothing is configured, Codex is what `setup` offers** — it is a leading coding model, its
CLI meets the contract in context mode, and the template below is verified. It is a default, not a
requirement.

**Other frontier and open-weight models are entirely capable of this role**, and the loop treats
them identically: Grok, Gemini, DeepSeek, and open-weight models served locally through a runner
such as Ollama are all reasonable choices. Anything reaching the role through an OpenAI-compatible
endpoint works too. The plugin ships no template for these only because a command line it has not
verified is worse than none — an invocation that silently fails reads as "no findings". Name your
CLI at `setup` A7 and it is probed, validated, and catalogued for your repository like any other.

An engine genuinely unsuited to the role is one that cannot run non-interactively, cannot be made
read-only, or cannot accept a prompt on stdin or a diff base. Say so rather than wiring it up: an
empty roster is legal, and Claude's own pass remains the local gate.

## Catalogued engines

### Codex — verified

```json
{
  "review": {
    "localReviewerName": "Codex",
    "localCommand": "codex exec --ephemeral --sandbox read-only -c model_reasoning_effort=\"<effort>\" -c mcp_servers.devstride.enabled=false <context>",
    "localAssistCommand": "codex exec --ephemeral --sandbox read-only -c model_reasoning_effort=\"<effort>\" -c mcp_servers.devstride.enabled=false <context>"
  }
}
```

Context mode; read-only sandbox; DevStride MCP disabled; `--model` deliberately omitted. Engine
extras worth checking when this command is configured: `exec` and `--sandbox` exist in `--help`,
and a literal effort tier in place of `<effort>` is an optimization warning, not a failure.

The pre-3.0 base-mode form remains supported and is migrated, never silently rewritten:

```json
"localCommand": "codex exec review --base <base> -c model_reasoning_effort=\"xhigh\" -c mcp_servers.devstride.enabled=false"
```

### Any other CLI — the shape to adapt

```json
{
  "review": {
    "localReviewerName": "<the name findings should be attributed to>",
    "localCommand": "<cli> <non-interactive subcommand> <read-only flag> <disable-tools flag> <context>"
  }
}
```

Read it as a checklist rather than a command: a non-interactive invocation, read-only, ambient
tooling off, and `<context>` last so the prompt arrives on stdin. Substitute `<effort>` only where
the CLI exposes a reasoning tier. `setup` probes the first token and the placeholder shape; a
single real review is what proves the rest.

## Cited by

- `setup` SKILL.md A7 (detection, template offer) and validation check 3 (declared engines respond)
- `doctor` SKILL.md §6 (review roster)
- `review` SKILL.md and `references/delta-re-review.md` (launch shapes)
