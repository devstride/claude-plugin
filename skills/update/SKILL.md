---
name: update
description: Update the exact DevStride plugin installation that loaded this command to the latest published version, verify the installed copy, and explain when to reload. Use only when the user directly invokes /devstride:update or explicitly asks to update the DevStride plugin now.
user-invocable: true
disable-model-invocation: true
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

This is a standalone user-authorized update, never a build-loop step. It may change the active
user/project/local install. It may not change config, override a pin, guess between installs,
remove/re-add a marketplace, or change an administrator-managed install.

Run exactly:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/skills/update/scripts/update-plugin.py" apply
```

The helper bypasses background-check caches and switches, finds the exact loaded copy, verifies the
official tag and installed files, and checks disk again. Never substitute guessed commands or treat
an exit code as proof.

Translate its one JSON result; never paste it raw:

- `updated`/`current` plus `safeToReload: true`: four short lines — **Running**, **Installed**,
  **Install**, **Result**. Explain user scope as shared on this machine; project/local as this repo
  only. Keep the exact id and scope in parentheses.
- `blocked`: explain the safety stop. Never bypass a pin, administrator boundary, duplicate, or
  missing repository binding.
- `failed`: say which stage failed and that success is unproved. If `manualInspectionRequired`,
  give no mutation command: Claude cannot prove which copy is safe to change. If
  `repairRequired`, **do not reload or invoke another DevStride skill**; separately ask permission
  to preserve data and reinstall, run `repairCommands` only on yes, then rerun the helper.
  Otherwise give only `retryCommand` when present.

Only for `updated`/`current` with both `safeToReload` and `reloadRequired` true, finish:
**Run `/reload-plugins` before another DevStride command and confirm it reports no DevStride load
error. If reload is unavailable or fails, restart Claude Code.** Stop after this handoff.

The skill first exists in 3.1.0. Older copies need the README's two-command bootstrap once.
