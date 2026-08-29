# Engineering economy and agent routing — CANONICAL CONTRACT

Use the smallest complete approach that satisfies the accepted scope and safety boundary. Before
building, compare the requested route with a materially simpler or faster one. When the requested
route would add meaningful time, duplication, operational cost, or maintenance burden, name that
cost and recommend the better route. Continue without ceremony when the routes are equivalent;
stop for the user only when the choice changes product scope, risk, cost, or an outward-facing
decision.

## Build less, reuse deliberately

Apply these checks in order:

1. Search the repository, its declared dependencies, and the language/platform standard library
   for the capability and its established local pattern.
2. If the capability is non-trivial and commodity, evaluate mature maintained open-source options
   before designing custom machinery. Check compatibility, security history, license, maintenance,
   adoption, and the ongoing cost of adding a dependency.
3. Write custom code only when existing options do not meet the concrete requirement, or when the
   dependency would cost more to own than the small implementation it replaces. Record that reason
   in the build plan.

DRY and YAGNI constrain each other: reuse an existing abstraction and consolidate confirmed
repetition behind a stable boundary, but do not create a framework, compatibility layer, toggle, or
extension point for a hypothetical second use. Remove obsolete paths when replacing a pattern.

## Spend agents where they change the answer

Keep the main skill's model inherited. Route each bounded child task with Claude's semantic aliases
and an explicit effort, using the cheapest tier that can reliably do it:

| Task/risk | Route |
|---|---|
| Mechanical read-only retrieval, inventory, formatting, or deterministic checking | `haiku`, `low` |
| Routine scoped drafting, analysis, or implementation | `sonnet`, `medium`; raise to `high` when coordination or ambiguity warrants it |
| Cross-file or cross-module contract work | `sonnet`, `high` for the work, plus one independent `opus`, `high` critic when a second view can change the result |
| Authentication/authorization, migration, irreversible state, or deployed-runtime contract | `opus`, `xhigh` verifier focused on that risk |
| Final release-unit or production merge gate | `opus`, `xhigh` |

`max` is never a default. Use it only as an explicit, evaluated override for a named unresolved risk
where another reasoning increment is likely to change the decision; record why. More agents are not
automatically more review: prefer one well-grounded critic to overlapping generic passes.

Parallelize only independent, read-only work with distinct questions and bounded fan-out. Run
dependent stages as a pipeline, and serialize writes or work that shares mutable state. Give every
follow-up the compact evidence and decision ledger from earlier passes so it challenges unresolved
claims instead of rediscovering or reversing settled ones.

## Optional local second opinion

When `review.localAssistCommand` is configured, use it exactly once for an ambiguous cross-module
design, authentication/migration/deployed-contract risk, or a stubborn diagnosis after one concrete
hypothesis failed. Routine work skips it. If independent Claude readers are also needed, launch the
read-only support call concurrently with them; do not serialize identical investigations.

Replace `<effort>` with the task-sized effort from the table and `<context>` with `-`, then feed a
distilled prompt on stdin: the accepted scope, relevant paths/diff, evidence already found, the one
question to answer, and required structured output. The command is advisory and read-only: it never
writes files, invokes DevStride MCP, decides scope, or substitutes for the merge gate. Verify useful
claims against the repository before acting on them and carry the disposition in the shared ledger.
