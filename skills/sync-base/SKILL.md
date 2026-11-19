---
name: sync-base
description: "Return the checkout to its working base and prove the tree is clean."
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/step-skills.md` first: the rule every step skill follows.

Arguments: $ARGUMENTS — one JSON object, the `sync@1` payload
(`${CLAUDE_PLUGIN_ROOT}/schemas/step-contracts.json`): `workingBase`, the branch the story landed on.

## Verdict

`SYNC: CLEAN | DIRTY [<paths>]`

## Steps

1. `git checkout <workingBase> && git pull --ff-only`.
2. **assert a clean tree** with `git status --porcelain`: empty → `CLEAN`.
3. Anything listed → `DIRTY` naming the drift (each path, or the count and the first few): never
   auto-reset or `git add .`, never stash, never delete a file to make it pass. A person decides
   what the drift is.
4. A checkout or pull that fails (a diverged base, a missing branch) → `DIRTY`, naming the git
   error: the run stops there.

Handing the checkout back (`return-checkout`) is the loop's, after this step, and only at a
terminal exit.

## Result

After the verdict and its evidence, one fenced `json` block: `branch` (the branch now checked out)
and `clean`.

**Step rules.** This step only; verdict first; safe to re-run; config wins; it never starts a
subagent and never decides what runs next.
