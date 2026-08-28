# Status-line segments: what each one needs, and what to do when it is blank

The status line renders `Model · Effort · Repo · Checkout · Branch · Stage · PR`. **A segment with
no value is not rendered at all** — `seg` in `statusline.sh` drops it, separator and label
together. A label printed with nothing after it ("`Checkout:    `") reads as a value that failed to
load and sends people hunting for a break that is not there, so it never happens.

That leaves one real question, and it is the one `setup` and `doctor` ask: **is this segment blank
because the repository genuinely has no such fact, or because something that should be configured
is not?**

## The segments

| Key | Label | Where the value comes from | Blank means |
| --- | --- | --- | --- |
| `model` | Model | `model.display_name` in the status-line payload | The payload did not carry it — **transient** |
| `effort` | Effort | the last `"effort"` in the session transcript's tail | No assistant record yet — **transient**, fills in on the first reply |
| `repo` | Repo | basename of `git rev-parse --show-toplevel` | Not a git repository — already an §1 finding |
| `checkout` | Checkout | linked worktree name, else the word `main` | Not a git repository — already an §1 finding |
| `branch` | Branch | `git branch --show-current`, else `<sha> (detached)` | A repository with no commit yet — **transient** |
| `stage` | Stage | stdout of `stage.resolve`, cached ~10s | **Structural** — no `stage` block, or a `resolve` that prints nothing |
| `pr` | PR | `gh pr view` for the current branch, cached ~45s | This branch has no pull request (**transient**), or `gh` is missing/unauthenticated (an §1 finding) |

## Which blanks are worth asking about

**Only the structural ones.** A transient blank is not a finding and must never become a question:
asking on every run about a Model segment that fills itself in a second later turns a diagnostic
into an interrogation, and trains people to skip the answers that matter. Concretely:

- **Never ask** about `model`, `effort`, `branch`, `repo` or `checkout`. They are either transient
  or already reported by another check, with a better message than the status line could give.
- **Never ask about `pr` merely because the current branch has no pull request.** That is the
  normal state of a branch and it is right for the segment to be absent. It is worth raising only
  when §1 found `gh` missing or unauthenticated — and then the fix is `gh`, not the status line.
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
**Bumping the marker.** The version in the marker is the **status line's own**, not the plugin's.
Raise it in the same commit that changes `statusline.sh`, and leave it alone in every release that
does not — the hook compares marker to marker, so a version bumped for unrelated reasons would
rewrite a file that is already identical, and a version left stale after a real change would strand
every copy in the field.

- **`autoUpdate`** (default `true`) — whether the session-start hook may refresh
  `.claude/statusline.sh` when the plugin ships a newer one. It replaces the file **only** while it
  still carries the shipped `# ds-statusline: managed v<x.y.z>` marker on line 2, keeps the
  previous copy as `.claude/statusline.sh.bak`, and never creates a status line that is not already
  there. **Deleting the marker line is how an owner takes the file over permanently** — that is the
  supported way to hand-edit it, and it is what the marker's own text says.
