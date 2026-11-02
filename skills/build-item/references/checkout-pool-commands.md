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

**Set both or neither.** `pool.checkout` without `pool.checkin` would take a lease nothing can
return, so one alone is an ERROR: the config validator (and `doctor` with it) rejects it, and
`lease-checkout` and `return-checkout` both check the pair FIRST and stop with `ERROR`, nothing
leased or returned. The same session leasing a member it already holds exits 0 (a
renewal), so a loop may call `pool.checkout` on every run.

The commands never list members: the caller names one. `build-item` passes the name of the
checkout directory it is working in when nothing else names it; a refusal of that guessed name
STOPS and asks, and never retries with another name.

## What the loop does with the result

- **Leased** → work there; the lease, not the branch, makes the checkout this session's, so switch
  branches freely while holding it.
- **Busy** → ask the holder or the owner. Never create another checkout or worktree to get round
  it, and never delete or overwrite another session's lease.
- **Returned** → only after the work has merged or been handed over, or the run ended at step 0
  before building anything, and every process this session started there has stopped.
- **Unset** (`pool.checkout` null or absent): the repository's own lease protocol applies when its conventions declare a pool; otherwise there is no pool and no lease (the generic protocol in
  `ground-truth-at-start.md`), said once.

## When `build-item` calls the steps

- **`lease-checkout` once per top-level run, before the first fetch** (step 0's ground truth),
  and the lease is KEPT across loop iterations: a story that ends in "then step 0" never hands
  the checkout back.
- **`return-checkout` only after the last checkout operation** — for a run that built something,
  after step 7's checkout, pull and clean-tree check, never before them — and only at a terminal exit (a one-off's TERMINATE, step
  8's release-ready stop) or a hand-over to another session or the owner. A STOP in steps 1–7 that
  leaves the work for this session to resume keeps the lease.
- **Every exit from step 0 returns it too**, before the run ends — DRY-CHAIN or plan complete, an
  ambiguous plan root, a given item already merged or Done, any other stop before step 1: nothing
  is built in the checkout yet, so nothing is lost, and the next run leases again.
- Every process the run started in the checkout stops before the return.

## Cited by

- `skills/lease-checkout/SKILL.md`, `skills/return-checkout/SKILL.md` — the two steps.
- `skills/build-item/SKILL.md` — the checkout-pool floor, step 0 and step 7.
- `skills/build-item/references/ground-truth-at-start.md` — the lease protocol's hand-off.
