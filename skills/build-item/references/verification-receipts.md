---
load: contract
---
# Verification receipts — reuse proof only when the tree and commands are identical

Repeated checks add no evidence when neither code nor command changed. A skill that completes a
verification gate writes an uncommitted receipt under
`.git/devstride/verification/<tree-sha>.json` and hands its path to the caller:

```json
{
  "head": "<commit sha>",
  "tree": "<git rev-parse HEAD^{tree}>",
  "configHash": "<sha256 of the resolved verify/preCommit/generated config>",
  "commands": ["<exact command in execution order>"],
  "results": [{"command":"...","status":"pass","count":"<files/tests or n/a>"}],
  "createdAt": "<ISO-8601>"
}
```

The tree SHA, not only the commit SHA, lets a tree-identical CI re-trigger commit reuse real
proof. `head` still names where it was observed. The receipt is valid only when all are true:

1. `git status --porcelain` has no tracked or relevant untracked change;
2. current `HEAD^{tree}` equals `tree`;
3. the resolved command list is byte-for-byte identical, in the same order;
4. the hash of the config fields that selected those commands is identical;
5. every required result is `pass` and the requested gate is no wider than the receipt's set.

Otherwise delete/ignore it and run the gate. A rebase, merge, generated artifact, review fix,
config edit or widened command set normally invalidates it. Never reuse a touched-suite receipt
as proof of a full suite, or a local command as proof that cloud CI ran.

The Build workflow's `local-checks` step writes the final story receipt, and its proof hands it on:
the review and the merge read it instead of asking for the same gate again at an unchanged tree. `push` may consume it only when it creates no commit; a
new commit requires checks at the new tree. Review and release update receipts after their own
fixes. Delete obsolete receipt files opportunistically; they live inside `.git` and are never
committed.

## Cited by

- `skills/local-checks/SKILL.md` — the receipt it writes, read in full before the first command.
- `skills/review-story/references/review-routes.md` — the floor: a receipt that no longer holds.
- `skills/push/SKILL.md` — exact-tree reuse before push.
- `skills/setup/references/seam-registry.md` — the contract of each `verify.*` command key.
