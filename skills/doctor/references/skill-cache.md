---
load: contract
---
# The user cache — saved library skills and learned reviewer latency

Both live in `${XDG_CACHE_HOME:-~/.cache}/devstride-plugin/`, outside the repository. Read-only.

## Saved library skills

Run `python3 ${CLAUDE_PLUGIN_ROOT}/skills/run-workflow/scripts/library_skill.py list` with `{}` on
stdin. Report the number of entries and `totalBytes`. No entries, or no cache folder → INFO ("no
saved library skills"). Each entry with `valid: false` → WARN, naming its organization, skill and
version: "this saved copy fails its fingerprint; the next run fetches it again". The repair is Tier B
in `repairs.md`: on yes, run the same helper's `remove` with
`{"organizationId": "<org>", "name": "<skill>", "version": <n>}` on stdin. Deleting a copy is always
safe; the next run that needs it fetches it again. Copies are never evicted or expired, so a large
total is reported, never a fault.

## Learned reviewer latency

From `reviewer-latency.json`, report each reviewer's samples, p50, p95 and derived bound under
`pollTimeoutMinutes`; below the sample minimum report `cold — the wait uses pollTimeoutMinutes`.
INFO only; schema and format: `${CLAUDE_PLUGIN_ROOT}/skills/review/references/reviewer-latency.md`.
