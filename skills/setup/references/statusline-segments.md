---
load: contract
---
# Status-line segments: what each one needs, and what to do when it is blank

The status line renders two lines, each segment led by its symbol:

```
◆ Opus 5 · ↯ high · ▣ acme · ⑂ i123-widget · ⎇ phil/26-11-04/widget
⊞ 3.26.0 · ▲ phil-mac · ⇄ #412 draft · ⚑ release/26-11-04 · alice · ci
```

Line 2 prints only when it has a value; `"refreshInterval": 30` redraws every 30 seconds.
**A segment with no value is not rendered**: a bare symbol reads as a failed load.

**The repository holds a launcher, not the bar.** `.claude/statusline.sh` is
`statusline-launcher.sh` (marker `# ds-statusline-launcher: managed v<n>`): each redraw runs the
`statusline.sh` of the plugin the session has loaded, found through the session's record
(rewritten at every prompt, so a reload shows at the next one), then `$CLAUDE_PLUGIN_ROOT`, then
the registry's install for this repository; no release changes the repository. Finding no plugin
it prints only `▣ <directory> · ⎇ <branch>`, so a bar alone never proves the plugin's status line
ran.

## The proof

`setup` E3, `doctor` §4 and the repair all use this, from the repository root:

```bash
p() { printf '{"session_id":"%s","workspace":{"current_dir":"%s"}}' "$CLAUDE_CODE_SESSION_ID" "$PWD" | bash .claude/statusline.sh "$@"; echo; }
p --which; p
```

**Pass: both lines are non-empty.** `--which` prints the plugin copy the launcher would run, and
nothing when it found none; the second line is the bar. An empty first line is a FAIL (say the
launcher found no devstride plugin for this session), whatever the bar shows. Never judge by a
particular segment: `statusLine.hiddenSegments` may hide any of them. `--which` belongs to the
launcher only: for a script with the full-copy marker or with none, the pass is a non-empty bar.

## Markers, and moving a full copy

| Line 2 of `.claude/statusline.sh` | It is | `doctor` |
| --- | --- | --- |
| `# ds-statusline-launcher: managed v<n>` | the launcher | nothing to say |
| `# ds-statusline: managed v<x.y.z>` | a full copy from before the launcher | WARN; repair: move it |
| neither | the owner's own (deleting the line is the supported takeover) | INFO `owner-managed`; never a WARN, never repaired or replaced |

**Moving a full copy** (`setup` E3, `doctor`'s repair; the session-start hook does the same by
itself): only for a file still carrying the full-copy marker, and only on a work branch. Leave
it alone on a detached checkout and on a base, production or protected branch, and when the
branch's upstream or `origin/<baseBranch>` already has the launcher (say "pull"). Copy the old
file to `devstride/statusline.bak` in the git directory (`git rev-parse --git-common-dir`), never
into the work tree; copy the launcher over it; run The proof; leave it for the owner to commit.

That leaves one real question, and it is the one `setup` and `doctor` ask: **is this segment blank
because the repository genuinely has no such fact, or because something that should be configured
is not?**

## The segments

| Key | Symbol | Where the value comes from | Blank means |
| --- | --- | --- | --- |
| `model` | ◆ | `model.display_name` in the status-line payload | The payload did not carry it — **transient** |
| `effort` | ↯ | the last `"effort"` in the session transcript's tail | No assistant record yet — **transient**, fills in on the first reply |
| `plugin` | ⊞ | `hooks/session-runtime.py check`: the running version, dim; red `3.15.0 → 3.16.0 · /reload-plugins` (newer copy installed), yellow `3.16.0 (3.16.1 out · /devstride:update)` (newer published) | No record yet — **never a finding** |
| `session` | ☻ | this session's name: the payload's `session_name` (a custom name or title), else the first line of `session.nameCommand`, run from the repository root with `CLAUDE_CODE_SESSION_ID` exported, cached ~10s under `$TMPDIR` | The session has no custom name and no command is configured — **never a finding** |
| `repo` | ▣ | basename of `git rev-parse --show-toplevel` | Not a git repository — already an §1 finding |
| `checkout` | ⑂ | linked worktree name, else the word `main` | Not a git repository — already an §1 finding |
| `branch` | ⎇ | `git branch --show-current`, else `<sha> (detached)` | A repository with no commit yet — **transient** |
| `stage` | ▲ | stdout of `stage.resolve`, cached ~10s | **Structural** — no `stage` block, or a `resolve` that prints nothing |
| `pr` | ⇄ | `gh pr view` for the current branch, cached ~45s | This branch has no pull request (**transient**), or `gh` is missing/unauthenticated (an §1 finding) |
| `release` | ⚑ | the clearance provider's `status --short` (`release.clearance`), cached ~45s: `release/26-10-17 · alice · ci`, `· STALE` past the stale threshold, `· STUCK` past the phase budget (both red); with nothing held, `close-out owed · <release> · <items>` while this machine owes close-out work | No release holds clearance (**transient**), `release.clearance` is null (by design, never asked), or no provider could be found (`doctor` config reports a `provider: github` with no installed plugin) |

## Which blanks are worth asking about

**Only the structural ones.** A transient blank is not a finding and must never become a question:
asking on every run about a Model segment that fills itself in a second later turns a diagnostic
into an interrogation, and trains people to skip the answers that matter. Concretely:

- **Never ask** about `model`, `effort`, `branch`, `repo` or `checkout`. They are either transient
  or already reported by another check, with a better message than the status line could give.
- **Never ask about `pr` merely because the current branch has no pull request.** That is the
  normal state of a branch and it is right for the segment to be absent. It is worth raising only
  when §1 found `gh` missing or unauthenticated — and then the fix is `gh`, not the status line.
- **Never ask about `plugin`**: it fills itself in at the first prompt, and its colour is the finding.
- **Never ask about `session`**: a session without a custom name is normal, and a repository that
  wants every session named sets `session.nameCommand` on purpose, not in answer to a blank.
- **Never ask about `release`.** Clear is the normal state of a repository, and a null
  `release.clearance` is a decision already recorded in the config; the segment exists to show a
  release in flight, nothing more.
- **Ask about `stage`.** It is the one segment whose absence is genuinely ambiguous: a repository
  that deploys nothing per-environment and a repository whose `stage.resolve` was never configured
  look identical from here.

## The interview

For each segment worth asking about, one question, and it has three possible ends:

1. **"It should be populated, and here is where from."** The answer is a configuration change, not
   a status-line change. For `stage` that is `stage.resolve` — a command whose stdout is the stage
   THIS checkout deploys to — and `stage.productionStages` beside it. Write the config, then
   re-render to confirm the segment now appears.
2. **"It should be populated, but I do not know from where."** Leave everything alone and say so in
   the report. Do NOT hide the segment: hiding it would erase the open question, and the segment
   costs nothing while it stays blank. This is a legitimate end — an unanswered question recorded
   is better than a wrong answer written down.
3. **"There is no such thing in this repository."** Record it: add the key to
   `statusLine.hiddenSegments` in `.claude/ds-config.json`. Nothing changes on screen — a segment
   with no value was already invisible — and that is the point. The entry is what stops the
   question being asked again on every run, and it says the absence was decided rather than
   overlooked.

**Ask once, and take silence as answer 2**, never as answer 3. A skipped question is not
permission to write a config key.

## The `statusLine` config block

Both keys are optional, and a repository with neither behaves exactly as before.

```json
{
  "statusLine": {
    "hiddenSegments": ["stage"],
    "autoUpdate": true
  }
}
```

- **`hiddenSegments`** (default `[]`) — segment keys, from the table above, that this repository has
  confirmed do not apply. It suppresses a segment that WOULD render, and it records the decision so
  neither skill asks again. An unrecognized key is inert.
**Bumping the marker.** The launcher's marker carries the **launcher's own** version, a whole
number. Raise it by one in the same commit that changes `statusline-launcher.sh`, and never
otherwise: the hook compares marker to marker, so a stale one strands every launcher in the
field. `statusline.sh` has no marker; a change to it reaches a session with the plugin.

- **`autoUpdate`** (default `true`) — whether the session-start hook may replace
  `.claude/statusline.sh`: a full copy with the launcher, once, and a launcher with a newer
  launcher. It replaces the file **only** while it still carries one of the two markers, keeps
  the previous file as `devstride/statusline.bak` in the repository's git directory, and never
  creates a status line that is not already there. A committed file is left alone when the
  branch's upstream (or `origin/<baseBranch>`) already carries the launcher, and on a detached
  checkout or a base, production or protected branch, so the move is committed once from a work
  branch. **Deleting the marker line is how an owner takes the file over permanently** — that is the
  supported way to hand-edit it, and it is what the marker's own text says.
