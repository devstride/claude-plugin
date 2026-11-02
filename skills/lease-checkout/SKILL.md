---
name: lease-checkout
description: "Step: lease one checkout of the repository's pool through its pool.checkout command, and print one verdict; build-item calls it first."
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/step-skills.md` first: the rule every step skill follows.

Arguments: $ARGUMENTS — the member (the checkout to lease) and the purpose (the item or reason).
No member → the name of the checkout directory this session works in. Command contract:
`${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/checkout-pool-commands.md`.

## Verdict

`LEASE: LEASED <member> | BUSY <member> | NOT CONFIGURED | ERROR`

## Steps

1. Read `pool.checkout`. Null or absent → `NOT CONFIGURED`: the repository's own lease protocol applies when its conventions declare a pool; otherwise there is no pool and no lease — say which, once.
2. Substitute `<member>` and `<purpose>` (shell-quoted); never pass a placeholder through.
3. Run it once. Exit 0 → `LEASED <member>`; exit 2 → `BUSY <member>`; any other exit →
   `ERROR`. Quote its first stdout line as evidence in every case.
4. `BUSY` → ask the holder or the owner. **Never create another checkout or worktree to get round
   it, and never delete or overwrite another session's lease.** A refusal of a guessed member name
   stops and asks; never retry with another name.

Call it once per top-level run, before the first fetch; the lease is kept across loop iterations
and branch switches. Hand it back with `/devstride:return-checkout`.
