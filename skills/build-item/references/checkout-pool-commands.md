---
load: contract
---
# Checkout pool commands — leasing and returning a checkout through the repository's own tool

A repository with a fixed pool of checkouts (several working copies one machine shares between
sessions) can name the two commands that lease and return one. With them set, `build-item` calls
the `lease-checkout` and `return-checkout` steps instead of following the generic lease protocol
in `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/ground-truth-at-start.md`. This file is the
authority for the two commands.

## Config keys

```json
{ "pool": { "checkout": null, "checkin": null } }
```

| Key | Command contract |
|---|---|
| `pool.checkout` | Leases one member. Placeholders `<member>` (the checkout to lease) and `<purpose>` (the item or reason, shell-quoted) are substituted before it runs; neither is ever passed through to the shell unexpanded. **Exit 0** — the checkout is now held by this session. **Exit 2** — not held: another session holds it, or it is in use without a lease. **Any other exit** — an error. Its first stdout line is quoted as evidence either way. |
| `pool.checkin` | Returns one member. Placeholder `<member>`. **Exit 0** — returned. **Any other exit** — a refusal (not the holder, a dirty tree, a process still running); its first line is quoted and it is never retried blindly. |

The commands never list members: the caller names one. `build-item` passes the name of the
checkout directory it is working in when nothing else names it; a refusal of that guessed name
STOPS and asks, and never retries with another name.

## What the loop does with the result

- **Leased** → work there; the lease, not the branch, makes the checkout this session's, so switch
  branches freely while holding it.
- **Busy** → ask the holder or the owner. Never create another checkout or worktree to get round
  it, and never delete or overwrite another session's lease.
- **Returned** → only after the work has merged or been handed over and every process this
  session started there has stopped.
- **Unset** (`pool.checkout` null or absent): the generic default — the current checkout is the
  only environment and no lease is taken, said once. A pool the conventions document declares
  without these commands still follows the generic lease protocol.

## Cited by

- `skills/lease-checkout/SKILL.md`, `skills/return-checkout/SKILL.md` — the two steps.
- `skills/build-item/SKILL.md` — the checkout-pool floor.
