---
name: return-checkout
description: "Step: return a leased checkout through the repository's pool.checkin command once the work has merged, and print one verdict."
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/step-skills.md` first: the rule every step skill follows.

Arguments: $ARGUMENTS — the member to return (default: the checkout directory this session works
in). Command contract: `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/checkout-pool-commands.md`.

## Verdict

`RETURN: RETURNED <member> | REFUSED <member> | NOT CONFIGURED | ERROR`

## Steps

1. Check the pair first: exactly one of `pool.checkout` and `pool.checkin` set (non-null) →
   `ERROR`, naming the missing one, and STOP — nothing is returned. `pool.checkin` null or absent
   → `NOT CONFIGURED`: nothing to hand back.
2. Return only at a terminal exit or a hand-over, after the caller's last checkout operation (in
   `build-item`, after step 7's sync — never between loop iterations), and only after stopping
   every process this session started in that checkout (test runs, servers, watchers).
3. Substitute `<member>` and run the command once. Exit 0 → `RETURNED <member>`; any other exit →
   `REFUSED <member>` with its first line (not the holder, a dirty tree, a process still running).
   A command that cannot run at all → `ERROR`.
4. A refusal is reported, never retried blindly and never worked round by deleting the lease.
